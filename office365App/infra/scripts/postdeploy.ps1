$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'true'

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition
$appDirectory = Split-Path -Parent (Split-Path -Parent $scriptDirectory)
$operationsDirectory = Join-Path $appDirectory 'operations'
$notificationFiles = @()
$retryAttempts = 3
$retryDelaySeconds = 5
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Stop-WithError {
    param([Parameter(Mandatory)] [string] $Message)
    throw "ERROR: $Message"
}

function Get-RequiredStringProperty {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Context
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value) -or $property.Value -eq 'null') {
        Stop-WithError "required $Context '$Name' must be a non-empty string"
    }
    return $property.Value
}

function Get-OptionalStringProperty {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value) -or $property.Value -eq 'null') {
        return $null
    }
    return $property.Value
}

function Resolve-Parameters {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Outputs,
        [Parameter(Mandatory)] [string] $ConfigPath
    )
    $parameterProperty = $Config.PSObject.Properties['parameters']
    if ($null -eq $parameterProperty -or $parameterProperty.Value -isnot [System.Array]) {
        Stop-WithError "trigger config '$ConfigPath' must contain a parameters array"
    }

    $resolved = New-Object 'System.Collections.Generic.List[object]'
    $parameterNames = @{}
    foreach ($parameter in @($parameterProperty.Value)) {
        if ($null -eq $parameter) {
            Stop-WithError "trigger config '$ConfigPath' contains an empty parameter"
        }
        $parameterName = Get-RequiredStringProperty -Object $parameter -Name 'name' -Context "parameter in '$ConfigPath'"
        $parameterKey = $parameterName.ToLowerInvariant()
        if ($parameterNames.ContainsKey($parameterKey)) {
            Stop-WithError "trigger config '$ConfigPath' contains duplicate parameter '$parameterName'"
        }
        $parameterNames[$parameterKey] = $true

        $hasValue = $parameter.PSObject.Properties.Name -contains 'value'
        $hasValueFrom = $parameter.PSObject.Properties.Name -contains 'valueFrom'
        if (($hasValue -and $hasValueFrom) -or (-not $hasValue -and -not $hasValueFrom)) {
            Stop-WithError "parameter '$parameterName' in '$ConfigPath' must contain exactly one of value or valueFrom"
        }
        if ($hasValue) {
            $parameterValue = Get-RequiredStringProperty -Object $parameter -Name 'value' -Context "parameter '$parameterName' in '$ConfigPath'"
        } else {
            $valueFromName = Get-RequiredStringProperty -Object $parameter -Name 'valueFrom' -Context "parameter '$parameterName' in '$ConfigPath'"
            $parameterValue = Get-RequiredStringProperty -Object $Outputs -Name $valueFromName -Context "azd output referenced by parameter '$parameterName' in '$ConfigPath'"
        }
        $resolved.Add([pscustomobject] [ordered] @{ name = $parameterName; value = $parameterValue })
    }
    return ,$resolved
}

function Invoke-AzWithRetry {
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    $lastOutput = ''
    for ($attempt = 1; $attempt -le $retryAttempts; $attempt++) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $commandOutput = & az @Arguments 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $standardOutput = @(
            $commandOutput |
                Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
                ForEach-Object { [string] $_ }
        )
        $standardError = @(
            $commandOutput |
                Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                ForEach-Object { [string] $_ }
        )
        if ($exitCode -eq 0) {
            $lastOutput = ($standardOutput -join [Environment]::NewLine).Trim()
            return [pscustomobject] @{ Succeeded = $true; Output = $lastOutput; Attempts = $attempt }
        }
        $lastOutput = (@($standardOutput + $standardError) -join [Environment]::NewLine).Trim()
        if ($attempt -lt $retryAttempts) {
            Write-Host "  $Description failed on attempt $attempt. Retrying in $retryDelaySeconds seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }
    return [pscustomobject] @{ Succeeded = $false; Output = $lastOutput; Attempts = $retryAttempts }
}

function Get-ConnectionStatus {
    return Invoke-AzWithRetry -Description 'Reading connector connection status' -Arguments @(
        'connector-namespace', 'connection', 'show',
        '--subscription', $subscriptionId,
        '-g', $resourceGroupName,
        '--namespace', $connectorNamespaceName,
        '-n', $connectorNamespaceConnectionName,
        '--query', 'properties.overallStatus',
        '-o', 'tsv'
    )
}

function Ensure-ConnectionAuthorized {
    Write-Host ''
    Write-Host "Authorizing $connectorName connection..." -ForegroundColor Yellow
    $statusResult = Get-ConnectionStatus
    if (-not $statusResult.Succeeded -or [string]::IsNullOrWhiteSpace($statusResult.Output)) {
        Stop-WithError "could not read connector connection status: $($statusResult.Output)"
    }
    $currentStatus = $statusResult.Output
    if ($currentStatus -eq 'Connected') {
        Write-Host 'Connection is already authorized.' -ForegroundColor Green
        return
    }

    Write-Host '-> A browser tab will open. Sign in with the account authorized for this connector.' -ForegroundColor Cyan
    $consentLink = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $consentOutput = & az connector-namespace connection list-consent-links `
            --subscription $subscriptionId `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            --connection-name $connectorNamespaceConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" `
            --query 'value[0].link' -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $consentOutput) -or $consentOutput -eq 'null') {
            $consentOutput = & az connector-namespace connection list-consent-links `
                --subscription $subscriptionId `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                --connection-name $connectorNamespaceConnectionName `
                --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" `
                --query 'link' -o tsv 2>$null
        }
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string] $consentOutput) -and $consentOutput -ne 'null') {
            $consentLink = [string] $consentOutput
            break
        }
        if ($attempt -lt 5) {
            Write-Host "list-consent-links attempt $attempt failed. Retrying in 5 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
    if ([string]::IsNullOrWhiteSpace($consentLink)) {
        Stop-WithError 'failed to create consent link'
    }

    Write-Host "Consent URL: $consentLink" -ForegroundColor Cyan
    try { Start-Process $consentLink | Out-Null } catch {
        Write-Host 'Unable to open a browser automatically. Paste the consent URL into your browser.' -ForegroundColor Yellow
    }

    $deadline = (Get-Date).AddMinutes(5)
    $lastPrintedStatus = $currentStatus
    Write-Host "Connection status: $currentStatus" -ForegroundColor Cyan
    do {
        Start-Sleep -Seconds 3
        $statusOutput = & az connector-namespace connection show `
            --subscription $subscriptionId `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $connectorNamespaceConnectionName `
            --query 'properties.overallStatus' -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $statusOutput)) {
            $currentStatus = 'Unknown'
        } else {
            $currentStatus = [string] $statusOutput
        }
        if ($currentStatus -ne $lastPrintedStatus) {
            Write-Host "Connection status: $currentStatus" -ForegroundColor Cyan
            $lastPrintedStatus = $currentStatus
        }
    } while ($currentStatus -ne 'Connected' -and (Get-Date) -lt $deadline)

    if ($currentStatus -ne 'Connected') {
        Stop-WithError 'timed out waiting for the connection to reach Connected status'
    }
}

function Get-ExistingTriggerNames {
    $listResult = Invoke-AzWithRetry -Description 'Listing existing Connector Namespace triggers' -Arguments @(
        'connector-namespace', 'trigger', 'list',
        '--subscription', $subscriptionId,
        '-g', $resourceGroupName,
        '--namespace', $connectorNamespaceName,
        '--query', '[].name',
        '-o', 'tsv'
    )
    if (-not $listResult.Succeeded) {
        Stop-WithError "could not list existing Connector Namespace triggers: $($listResult.Output)"
    }
    $names = @{}
    foreach ($name in @($listResult.Output -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $names[$name.Trim().ToLowerInvariant()] = $true
        }
    }
    return $names
}

function Invoke-TriggerConfiguration {
    param(
        [Parameter(Mandatory)] [object] $TriggerConfig,
        [Parameter(Mandatory)] [hashtable] $ExistingTriggers
    )

    $triggerName = "$connectorNamespaceConnectionName-$($TriggerConfig.FunctionName.ToLowerInvariant())"
    $triggerKey = $triggerName.ToLowerInvariant()
    $callbackUrl = "https://$functionAppHostname/runtime/webhooks/connector?functionName=$($TriggerConfig.FunctionName)"
    $notificationFile = Join-Path $scriptDirectory ".notification-details-$([System.Guid]::NewGuid().ToString('N')).json"
    $script:notificationFiles += $notificationFile

    try {
        $notificationJson = [ordered] @{
            callbackUrl = $callbackUrl
            authentication = [ordered] @{ type = 'QueryString'; name = 'code'; value = $connectorExtensionKey }
        } | ConvertTo-Json -Depth 4 -Compress
        [System.IO.File]::WriteAllText($notificationFile, $notificationJson, $utf8NoBom)

        if ($ExistingTriggers.ContainsKey($triggerKey)) {
            $deleteResult = Invoke-AzWithRetry -Description "Deleting existing trigger '$triggerName'" -Arguments @(
                'connector-namespace', 'trigger', 'delete',
                '--subscription', $subscriptionId,
                '-g', $resourceGroupName,
                '--namespace', $connectorNamespaceName,
                '-n', $triggerName,
                '--yes'
            )
            if (-not $deleteResult.Succeeded) {
                $remainingTriggers = Get-ExistingTriggerNames
                if ($remainingTriggers.ContainsKey($triggerKey)) {
                    return [pscustomobject] @{
                        Succeeded = $false
                        Summary = "$($TriggerConfig.FunctionName) ($($TriggerConfig.OperationId)): delete failed after $($deleteResult.Attempts) attempts: $($deleteResult.Output)"
                    }
                }
            }
            $ExistingTriggers.Remove($triggerKey) | Out-Null
        }

        $connectionDetails = [ordered] @{
            connectionName = $connectorNamespaceConnectionName
            connectorName = $TriggerConfig.ConnectorName
        } | ConvertTo-Json -Compress
        $parametersJson = ConvertTo-Json -InputObject $TriggerConfig.Parameters -Depth 4 -Compress
        $metadataJson = [ordered] @{
            destinationType = 'functionApp'
            functionAppName = $functionAppName
            functionAppResourceGroup = $resourceGroupName
            functionAppSubscriptionId = $subscriptionId
            functionName = $TriggerConfig.FunctionName
            recurrenceFrequency = 'Minute'
            recurrenceInterval = '5'
        } | ConvertTo-Json -Compress

        Write-Host "  Configuring trigger: $($TriggerConfig.FunctionName) -> $($TriggerConfig.OperationId)" -ForegroundColor Cyan
        $createResult = Invoke-AzWithRetry -Description "Creating trigger '$triggerName'" -Arguments @(
            'connector-namespace', 'trigger', 'create',
            '--subscription', $subscriptionId,
            '-g', $resourceGroupName,
            '--namespace', $connectorNamespaceName,
            '-n', $triggerName,
            '--connection-details', $connectionDetails,
            '--operation-name', $TriggerConfig.OperationId,
            '--parameters', $parametersJson,
            '--notification-details', "@$notificationFile",
            '--description', $TriggerConfig.Description,
            '--metadata', $metadataJson,
            '--query', 'properties.provisioningState',
            '-o', 'tsv'
        )

        if (-not $createResult.Succeeded -or $createResult.Output -ne 'Succeeded') {
            $verifyResult = Invoke-AzWithRetry -Description "Verifying trigger '$triggerName' after create failure" -Arguments @(
                'connector-namespace', 'trigger', 'show',
                '--subscription', $subscriptionId,
                '-g', $resourceGroupName,
                '--namespace', $connectorNamespaceName,
                '-n', $triggerName,
                '--query', 'properties.provisioningState',
                '-o', 'tsv'
            )
            if (-not $verifyResult.Succeeded -or $verifyResult.Output -ne 'Succeeded') {
                $createState = if ([string]::IsNullOrWhiteSpace($createResult.Output)) { 'no provisioning state returned' } else { $createResult.Output }
                return [pscustomobject] @{
                    Succeeded = $false
                    Summary = "$($TriggerConfig.FunctionName) ($($TriggerConfig.OperationId)): create failed after $($createResult.Attempts) attempts: $createState"
                }
            }
        }

        $ExistingTriggers[$triggerKey] = $true
        return [pscustomobject] @{ Succeeded = $true; Summary = "$($TriggerConfig.FunctionName) ($($TriggerConfig.OperationId))" }
    } finally {
        Remove-Item -LiteralPath $notificationFile -ErrorAction SilentlyContinue
        $script:notificationFiles = @($script:notificationFiles | Where-Object { $_ -ne $notificationFile })
    }
}

Write-Host 'Post-deployment configuration...' -ForegroundColor Yellow

try {
    foreach ($commandName in @('az', 'azd')) {
        if ($null -eq (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            Stop-WithError "required command '$commandName' was not found on PATH"
        }
    }
    if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
        Write-Host 'Install: irm https://aka.ms/connector-namespace-cli-install-ps | iex' -ForegroundColor Red
        Stop-WithError "the 'connector-namespace' Azure CLI extension is required"
    }

    $configFiles = @(
        Get-ChildItem -LiteralPath $operationsDirectory -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $configPath = Join-Path $_.FullName 'trigger-config.json'
                if (Test-Path -LiteralPath $configPath -PathType Leaf) { Get-Item -LiteralPath $configPath }
            } |
            Sort-Object -Property FullName
    )
    if ($configFiles.Count -eq 0) {
        Stop-WithError 'no retained trigger configs found under operations/*/trigger-config.json'
    }

    $triggerConfigs = @()
    $connectorName = $null
    $operationIds = @{}
    $functionNames = @{}
    foreach ($configFile in $configFiles) {
        try { $config = Get-Content -LiteralPath $configFile.FullName -Raw | ConvertFrom-Json } catch {
            Stop-WithError "malformed JSON in trigger config '$($configFile.FullName)': $($_.Exception.Message)"
        }
        if ($null -eq $config) { Stop-WithError "trigger config '$($configFile.FullName)' is empty" }

        $configConnectorName = Get-RequiredStringProperty -Object $config -Name 'connectorName' -Context "trigger config '$($configFile.FullName)'"
        $operationId = Get-RequiredStringProperty -Object $config -Name 'operationId' -Context "trigger config '$($configFile.FullName)'"
        $functionName = Get-RequiredStringProperty -Object $config -Name 'functionName' -Context "trigger config '$($configFile.FullName)'"
        $description = Get-RequiredStringProperty -Object $config -Name 'description' -Context "trigger config '$($configFile.FullName)'"

        if ($configConnectorName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            Stop-WithError "connectorName '$configConnectorName' in '$($configFile.FullName)' contains unsupported characters"
        }
        if ($functionName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            Stop-WithError "functionName '$functionName' in '$($configFile.FullName)' is not a valid Functions registration name"
        }
        if ($configFile.Directory.Name -cne $operationId) {
            Stop-WithError "operationId '$operationId' must exactly match directory '$($configFile.Directory.Name)'"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $configFile.Directory.FullName 'function.py') -PathType Leaf)) {
            Stop-WithError "operation '$operationId' is missing function.py"
        }

        $operationKey = $operationId.ToLowerInvariant()
        $functionKey = $functionName.ToLowerInvariant()
        if ($operationIds.ContainsKey($operationKey)) { Stop-WithError "duplicate operationId '$operationId' in retained trigger configs" }
        if ($functionNames.ContainsKey($functionKey)) { Stop-WithError "duplicate functionName '$functionName' in retained trigger configs" }
        $operationIds[$operationKey] = $true
        $functionNames[$functionKey] = $true

        if ($null -eq $connectorName) { $connectorName = $configConnectorName }
        elseif ($connectorName -cne $configConnectorName) { Stop-WithError 'retained trigger configs use mixed connectorName values' }

        $triggerConfigs += [pscustomobject] @{
            Config = $config
            ConfigPath = $configFile.FullName
            OperationId = $operationId
            FunctionName = $functionName
            Description = $description
            ConnectorName = $configConnectorName
        }
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $outputLines = & azd env get-values --output json 2>&1
        $azdExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $azdStandardOutput = @(
        $outputLines |
            Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { [string] $_ }
    )
    $azdStandardError = @(
        $outputLines |
            Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { [string] $_ }
    )
    if ($azdExitCode -ne 0) {
        Stop-WithError "azd env get-values --output json failed: $(@($azdStandardOutput + $azdStandardError) -join [Environment]::NewLine)"
    }
    try { $outputs = ($azdStandardOutput -join [Environment]::NewLine) | ConvertFrom-Json } catch {
        Stop-WithError "azd env get-values --output json returned invalid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $outputs) { Stop-WithError 'azd env get-values --output json returned no outputs' }

    $resourceGroupName = Get-RequiredStringProperty -Object $outputs -Name 'resourceGroupName' -Context 'azd output'
    $connectorNamespaceName = Get-RequiredStringProperty -Object $outputs -Name 'connectorNamespaceName' -Context 'azd output'
    $connectorNamespaceConnectionName = Get-RequiredStringProperty -Object $outputs -Name 'connectorNamespaceConnectionName' -Context 'azd output'
    $functionAppName = Get-RequiredStringProperty -Object $outputs -Name 'functionAppName' -Context 'azd output'
    $subscriptionId = Get-RequiredStringProperty -Object $outputs -Name 'AZURE_SUBSCRIPTION_ID' -Context 'azd output'
    $functionAppHostname = Get-OptionalStringProperty -Object $outputs -Name 'functionAppDefaultHostname'
    if ($null -eq $functionAppHostname) {
        $functionAppHostname = "$functionAppName.azurewebsites.net"
        Write-Host "azd output 'functionAppDefaultHostname' is unavailable; using compatibility hostname '$functionAppHostname'." -ForegroundColor Yellow
    }

    foreach ($triggerConfig in $triggerConfigs) {
        $triggerConfig | Add-Member -NotePropertyName Parameters -NotePropertyValue (Resolve-Parameters -Config $triggerConfig.Config -Outputs $outputs -ConfigPath $triggerConfig.ConfigPath)
    }

    Ensure-ConnectionAuthorized

    Write-Host "Fetching connector extension key for $functionAppName..." -ForegroundColor Cyan
    $keyResult = Invoke-AzWithRetry -Description 'Fetching connector extension key' -Arguments @(
        'functionapp', 'keys', 'list',
        '--subscription', $subscriptionId,
        '-g', $resourceGroupName,
        '-n', $functionAppName,
        '--query', 'systemKeys.connector_extension',
        '-o', 'tsv'
    )
    if (-not $keyResult.Succeeded -or [string]::IsNullOrWhiteSpace($keyResult.Output) -or $keyResult.Output -eq 'null') {
        Stop-WithError "could not fetch a non-empty connector_extension system key from ${functionAppName}: $($keyResult.Output)"
    }
    $connectorExtensionKey = $keyResult.Output
    $existingTriggers = Get-ExistingTriggerNames

    Write-Host 'Configuring Connector Namespace trigger configs...' -ForegroundColor Yellow
    $configuredCount = 0
    $failures = @()
    foreach ($triggerConfig in $triggerConfigs) {
        $result = Invoke-TriggerConfiguration -TriggerConfig $triggerConfig -ExistingTriggers $existingTriggers
        if ($result.Succeeded) { $configuredCount++ }
        else {
            $failures += $result.Summary
            Write-Host "  FAILED: $($result.Summary)" -ForegroundColor Red
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "Configured $configuredCount of $($triggerConfigs.Count) retained trigger config(s)." -ForegroundColor Red
        foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
        Stop-WithError "$($failures.Count) retained trigger config(s) failed; successful operations remain configured and re-running this script is safe"
    }

    Write-Host "Configured all $configuredCount retained trigger config(s)." -ForegroundColor Green
    Write-Host ''
    Write-Host 'Done. All retained connector triggers are configured.' -ForegroundColor Green
    Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
    Write-Host ''
} finally {
    foreach ($notificationFile in $notificationFiles) {
        Remove-Item -LiteralPath $notificationFile -ErrorAction SilentlyContinue
    }
}
