$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition
$appDirectory = Split-Path -Parent (Split-Path -Parent $scriptDirectory)
$operationsDirectory = Join-Path $appDirectory 'operations'
$notificationFiles = @()

function Stop-WithError {
    param([Parameter(Mandatory)] [string] $Message)
    throw "ERROR: $Message"
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Context
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or [string]::IsNullOrWhiteSpace([string] $property.Value) -or [string] $property.Value -eq 'null') {
        Stop-WithError "required $Context '$Name' is missing or empty"
    }

    return [string] $property.Value
}

function ConvertTo-ParameterShorthand {
    param(
        [Parameter(Mandatory)] [object] $Config,
        [Parameter(Mandatory)] [object] $Outputs,
        [Parameter(Mandatory)] [string] $ConfigPath
    )

    $parameterProperty = $Config.PSObject.Properties['parameters']
    if ($null -eq $parameterProperty -or $parameterProperty.Value -isnot [System.Array]) {
        Stop-WithError "trigger config '$ConfigPath' must contain a parameters array"
    }
    if ($parameterProperty.Value.Count -eq 0) {
        Stop-WithError "trigger config '$ConfigPath' must contain at least one parameter"
    }

    $parameterValues = @()
    foreach ($parameter in @($parameterProperty.Value)) {
        if ($null -eq $parameter) {
            Stop-WithError "trigger config '$ConfigPath' contains an empty parameter"
        }

        $parameterName = Get-RequiredProperty -Object $parameter -Name 'name' -Context "parameter in '$ConfigPath'"
        $hasValue = $parameter.PSObject.Properties.Name -contains 'value'
        $hasValueFrom = $parameter.PSObject.Properties.Name -contains 'valueFrom'
        if (($hasValue -and $hasValueFrom) -or (-not $hasValue -and -not $hasValueFrom)) {
            Stop-WithError "parameter '$parameterName' in '$ConfigPath' must contain exactly one of value or valueFrom"
        }

        if ($hasValue) {
            $parameterValue = Get-RequiredProperty -Object $parameter -Name 'value' -Context "parameter '$parameterName' in '$ConfigPath'"
        } else {
            $valueFromName = Get-RequiredProperty -Object $parameter -Name 'valueFrom' -Context "parameter '$parameterName' in '$ConfigPath'"
            $parameterValue = Get-RequiredProperty -Object $Outputs -Name $valueFromName -Context "azd output referenced by parameter '$parameterName' in '$ConfigPath'"
        }

        $escapedValue = $parameterValue.Replace('\', '\\').Replace("'", "''")
        $parameterValues += "{name:$parameterName,value:'$escapedValue'}"
    }

    return '[' + ($parameterValues -join ',') + ']'
}

Write-Host 'Post-deployment configuration...' -ForegroundColor Yellow

try {
    if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
        Write-Host "Install: irm https://aka.ms/connector-namespace-cli-install-ps | iex" -ForegroundColor Red
        Stop-WithError "the 'connector-namespace' Azure CLI extension is required"
    }

    $configFiles = @(
        Get-ChildItem -LiteralPath $operationsDirectory -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $configPath = Join-Path $_.FullName 'trigger-config.json'
                if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                    Get-Item -LiteralPath $configPath
                }
            } |
            Sort-Object -Property FullName
    )

    if ($configFiles.Count -eq 0) {
        Stop-WithError "no retained trigger configs found under operations/*/trigger-config.json"
    }

    $triggerConfigs = @()
    $connectorName = $null
    foreach ($configFile in $configFiles) {
        try {
            $config = Get-Content -LiteralPath $configFile.FullName -Raw | ConvertFrom-Json
        } catch {
            Stop-WithError "malformed JSON in trigger config '$($configFile.FullName)': $($_.Exception.Message)"
        }

        if ($null -eq $config) {
            Stop-WithError "trigger config '$($configFile.FullName)' is empty"
        }

        $configConnectorName = Get-RequiredProperty -Object $config -Name 'connectorName' -Context "trigger config '$($configFile.FullName)'"
        $operationId = Get-RequiredProperty -Object $config -Name 'operationId' -Context "trigger config '$($configFile.FullName)'"
        $functionName = Get-RequiredProperty -Object $config -Name 'functionName' -Context "trigger config '$($configFile.FullName)'"
        $description = Get-RequiredProperty -Object $config -Name 'description' -Context "trigger config '$($configFile.FullName)'"
        $parameterProperty = $config.PSObject.Properties['parameters']
        if ($null -eq $parameterProperty -or $parameterProperty.Value -isnot [System.Array]) {
            Stop-WithError "trigger config '$($configFile.FullName)' must contain a parameters array"
        }
        if ($parameterProperty.Value.Count -eq 0) {
            Stop-WithError "trigger config '$($configFile.FullName)' must contain at least one parameter"
        }

        foreach ($parameter in @($parameterProperty.Value)) {
            if ($null -eq $parameter) {
                Stop-WithError "trigger config '$($configFile.FullName)' contains an empty parameter"
            }
            $parameterName = Get-RequiredProperty -Object $parameter -Name 'name' -Context "parameter in '$($configFile.FullName)'"
            $hasValue = $parameter.PSObject.Properties.Name -contains 'value'
            $hasValueFrom = $parameter.PSObject.Properties.Name -contains 'valueFrom'
            if (($hasValue -and $hasValueFrom) -or (-not $hasValue -and -not $hasValueFrom)) {
                Stop-WithError "parameter '$parameterName' in '$($configFile.FullName)' must contain exactly one of value or valueFrom"
            }
            if ($hasValue) {
                Get-RequiredProperty -Object $parameter -Name 'value' -Context "parameter '$parameterName' in '$($configFile.FullName)'" | Out-Null
            } else {
                Get-RequiredProperty -Object $parameter -Name 'valueFrom' -Context "parameter '$parameterName' in '$($configFile.FullName)'" | Out-Null
            }
        }

        if ($null -eq $connectorName) {
            $connectorName = $configConnectorName
        } elseif ($connectorName -cne $configConnectorName) {
            Stop-WithError 'retained trigger configs use mixed connectorName values'
        }

        $triggerConfigs += [pscustomobject]@{
            Config = $config
            ConfigPath = $configFile.FullName
            OperationId = $operationId
            FunctionName = $functionName
            Description = $description
            ConnectorName = $configConnectorName
        }
    }

    $outputsText = azd env get-values --output json
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'azd env get-values --output json failed'
    }
    try {
        $outputs = $outputsText | ConvertFrom-Json
    } catch {
        Stop-WithError "azd env get-values --output json returned invalid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $outputs) {
        Stop-WithError 'azd env get-values --output json returned no outputs'
    }

    $resourceGroupName = Get-RequiredProperty -Object $outputs -Name 'resourceGroupName' -Context 'azd output'
    $connectorNamespaceName = Get-RequiredProperty -Object $outputs -Name 'connectorNamespaceName' -Context 'azd output'
    $connectorNamespaceConnectionName = Get-RequiredProperty -Object $outputs -Name 'connectorNamespaceConnectionName' -Context 'azd output'
    $functionAppName = Get-RequiredProperty -Object $outputs -Name 'functionAppName' -Context 'azd output'
    $subscriptionId = Get-RequiredProperty -Object $outputs -Name 'AZURE_SUBSCRIPTION_ID' -Context 'azd output'

    foreach ($triggerConfig in $triggerConfigs) {
        $triggerConfig | Add-Member -NotePropertyName Parameters -NotePropertyValue (ConvertTo-ParameterShorthand -Config $triggerConfig.Config -Outputs $outputs -ConfigPath $triggerConfig.ConfigPath)
    }

    Write-Host "Fetching connector extension key for $functionAppName..." -ForegroundColor Cyan
    $connectorExtensionKey = az functionapp keys list -g $resourceGroupName -n $functionAppName --query 'systemKeys.connector_extension' -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $connectorExtensionKey) -or [string] $connectorExtensionKey -eq 'null') {
        Stop-WithError "could not fetch a non-empty connector_extension system key from $functionAppName"
    }

    Write-Host 'Creating Connector Namespace trigger configs...' -ForegroundColor Yellow
    foreach ($triggerConfig in $triggerConfigs) {
        $triggerName = "$connectorNamespaceConnectionName-$($triggerConfig.FunctionName.ToLowerInvariant())"
        $callbackUrl = "https://$functionAppName.azurewebsites.net/runtime/webhooks/connector?functionName=$($triggerConfig.FunctionName)"
        $notificationFile = Join-Path $scriptDirectory ".notification-details-$([System.Guid]::NewGuid().ToString('N')).json"
        $notificationFiles += $notificationFile
        @{
            callbackUrl = $callbackUrl
            authentication = @{
                type = 'QueryString'
                name = 'code'
                value = $connectorExtensionKey
            }
        } | ConvertTo-Json -Depth 3 -Compress | Set-Content -LiteralPath $notificationFile -NoNewline

        Write-Host "  Creating trigger: $($triggerConfig.FunctionName) -> $($triggerConfig.OperationId)" -ForegroundColor Cyan
        try {
            az connector-namespace trigger delete `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                -n $triggerName --yes 2>$null | Out-Null

            az connector-namespace trigger create `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                -n $triggerName `
                --connection-details "{connectionName:$connectorNamespaceConnectionName,connectorName:$connectorName}" `
                --operation-name $triggerConfig.OperationId `
                --parameters $triggerConfig.Parameters `
                --notification-details "@$notificationFile" `
                --description $triggerConfig.Description `
                --metadata "{destinationType:functionApp,functionAppName:$functionAppName,functionAppResourceGroup:$resourceGroupName,functionAppSubscriptionId:$subscriptionId,functionName:$($triggerConfig.FunctionName),recurrenceFrequency:Minute,recurrenceInterval:'5'}" `
                -o none | Out-Null

            if ($LASTEXITCODE -ne 0) {
                Stop-WithError "failed to create trigger for function '$($triggerConfig.FunctionName)'"
            }
        } finally {
            Remove-Item -LiteralPath $notificationFile -ErrorAction SilentlyContinue
            $notificationFiles = @($notificationFiles | Where-Object { $_ -ne $notificationFile })
        }
    }

    Write-Host "Created $($triggerConfigs.Count) retained trigger config(s)." -ForegroundColor Green
    Write-Host ''
    Write-Host "Authorizing $connectorName connection..." -ForegroundColor Yellow

    $currentStatus = az connector-namespace connection show `
        -g $resourceGroupName --namespace $connectorNamespaceName `
        -n $connectorNamespaceConnectionName `
        --query 'properties.overallStatus' -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $currentStatus)) {
        $currentStatus = 'Unknown'
    }

    if ($currentStatus -eq 'Connected') {
        Write-Host 'Connection is already authorized.' -ForegroundColor Green
    } else {
        Write-Host '-> A browser tab will open. Sign in with the account authorized for this connector.' -ForegroundColor Cyan

        $consentLink = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $consentLink = az connector-namespace connection list-consent-links `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                --connection-name $connectorNamespaceConnectionName `
                --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" `
                --query 'value[0].link' -o tsv 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $consentLink) -or $consentLink -eq 'null') {
                $consentLink = az connector-namespace connection list-consent-links `
                    -g $resourceGroupName --namespace $connectorNamespaceName `
                    --connection-name $connectorNamespaceConnectionName `
                    --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" `
                    --query 'link' -o tsv 2>$null
            }

            if (-not [string]::IsNullOrWhiteSpace([string] $consentLink) -and $consentLink -ne 'null') {
                break
            }

            if ($attempt -lt 5) {
                Write-Host "list-consent-links attempt $attempt failed. Retrying in 5 seconds..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            }
        }

        if ([string]::IsNullOrWhiteSpace([string] $consentLink) -or $consentLink -eq 'null') {
            Stop-WithError 'failed to create consent link'
        }

        Write-Host "Consent URL: $consentLink" -ForegroundColor Cyan
        try {
            Start-Process $consentLink | Out-Null
        } catch {
            Write-Host 'Unable to open a browser automatically. Paste the consent URL into your browser.' -ForegroundColor Yellow
        }

        $deadline = (Get-Date).AddMinutes(5)
        $lastPrintedStatus = $currentStatus
        Write-Host "Connection status: $currentStatus" -ForegroundColor Cyan

        do {
            Start-Sleep -Seconds 3
            $currentStatus = az connector-namespace connection show `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                -n $connectorNamespaceConnectionName `
                --query 'properties.overallStatus' -o tsv 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string] $currentStatus)) {
                $currentStatus = 'Unknown'
            }

            if ($currentStatus -ne $lastPrintedStatus) {
                Write-Host "Connection status: $currentStatus" -ForegroundColor Cyan
                $lastPrintedStatus = $currentStatus
            }

            if ($currentStatus -eq 'Connected') {
                break
            }
        } while ((Get-Date) -lt $deadline)

        if ($currentStatus -ne 'Connected') {
            Stop-WithError 'timed out waiting for the connection to reach Connected status'
        }
    }

    Write-Host ''
    Write-Host 'Done. All retained connector triggers are configured.' -ForegroundColor Green
    Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
    Write-Host ''
} finally {
    foreach ($notificationFile in $notificationFiles) {
        Remove-Item -LiteralPath $notificationFile -ErrorAction SilentlyContinue
    }
}
