$ErrorActionPreference = 'Stop'

$appRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$operationRoot = Join-Path $appRoot 'operations'
$descriptorFiles = @(
    Get-ChildItem -Path $operationRoot -Filter 'trigger-config.json' -File -Recurse -ErrorAction SilentlyContinue
)

if ($descriptorFiles.Count -ne 1) {
    throw "Expected exactly one retained operation descriptor under operations/, but found $($descriptorFiles.Count)."
}

$descriptor = Get-Content -Path $descriptorFiles[0].FullName -Raw | ConvertFrom-Json

function Get-RequiredDescriptorString {
    param(
        [Parameter(Mandatory)] [object] $Descriptor,
        [Parameter(Mandatory)] [string] $Name
    )

    $property = $Descriptor.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string] $property.Value)) {
        throw "The retained operation descriptor is missing '$Name'."
    }

    return [string] $property.Value
}

$functionName = Get-RequiredDescriptorString -Descriptor $descriptor -Name 'functionName'
$connectorName = Get-RequiredDescriptorString -Descriptor $descriptor -Name 'connectorName'
$operationName = Get-RequiredDescriptorString -Descriptor $descriptor -Name 'operationName'
$description = Get-RequiredDescriptorString -Descriptor $descriptor -Name 'description'

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    Write-Host "ERROR: The 'connector-namespace' Azure CLI extension is required." -ForegroundColor Red
    Write-Host "Install: irm https://aka.ms/connector-namespace-cli-install-ps | iex" -ForegroundColor Red
    exit 1
}

$outputsJson = azd env get-values --output json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read azd environment outputs. Run 'azd provision' first."
}
$outputs = ($outputsJson -join [Environment]::NewLine) | ConvertFrom-Json

function Get-RequiredAzdOutput {
    param([Parameter(Mandatory)] [string] $Name)

    $property = $outputs.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string] $property.Value)) {
        throw "Required azd output '$Name' is missing. Run 'azd provision' first."
    }

    return [string] $property.Value
}

$resourceGroupName = Get-RequiredAzdOutput -Name 'resourceGroupName'
$connectorNamespaceName = Get-RequiredAzdOutput -Name 'connectorNamespaceName'
$connectorNamespaceConnectionName = Get-RequiredAzdOutput -Name 'connectorNamespaceConnectionName'
$functionAppName = Get-RequiredAzdOutput -Name 'functionAppName'
$subscriptionId = Get-RequiredAzdOutput -Name 'AZURE_SUBSCRIPTION_ID'

$descriptorParameters = if ($null -ne $descriptor.PSObject.Properties['parameters']) {
    @($descriptor.parameters)
} else {
    @()
}
$parameters = @()
foreach ($parameter in $descriptorParameters) {
    $parameterName = Get-RequiredDescriptorString -Descriptor $parameter -Name 'name'
    $hasLiteralValue = $null -ne $parameter.PSObject.Properties['value']
    $hasAzdOutput = $null -ne $parameter.PSObject.Properties['azdOutput']

    if ($hasLiteralValue -eq $hasAzdOutput) {
        throw "Parameter '$parameterName' must define exactly one of 'value' or 'azdOutput'."
    }

    $resolvedValue = if ($hasLiteralValue) {
        [string] $parameter.value
    } else {
        $outputName = Get-RequiredDescriptorString -Descriptor $parameter -Name 'azdOutput'
        Get-RequiredAzdOutput -Name $outputName
    }

    if ([string]::IsNullOrWhiteSpace($resolvedValue)) {
        throw "Parameter '$parameterName' resolved to an empty value."
    }

    $parameters += [ordered] @{
        name = $parameterName
        value = $resolvedValue
    }
}

Write-Host "Authorizing the connector connection..." -ForegroundColor Yellow
$currentStatus = az connector-namespace connection show `
    -g $resourceGroupName --namespace $connectorNamespaceName `
    -n $connectorNamespaceConnectionName `
    --query 'properties.overallStatus' -o tsv 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentStatus)) {
    $currentStatus = 'Unknown'
}

if ($currentStatus -eq 'Connected') {
    Write-Host 'Connection is already authorized.' -ForegroundColor Green
} else {
    Write-Host 'A browser tab will open for connector OAuth consent.' -ForegroundColor Cyan

    $consentLink = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $consentLink = az connector-namespace connection list-consent-links `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            --connection-name $connectorNamespaceConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" `
            --query 'value[0].link' -o tsv 2>$null

        if (-not $consentLink -or $consentLink -eq 'null') {
            $consentLink = az connector-namespace connection list-consent-links `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                --connection-name $connectorNamespaceConnectionName `
                --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" `
                --query 'link' -o tsv 2>$null
        }

        if ($consentLink -and $consentLink -ne 'null') {
            break
        }

        if ($attempt -lt 5) {
            Write-Host "Consent-link attempt $attempt failed. Retrying in 5 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    if (-not $consentLink -or $consentLink -eq 'null') {
        throw 'Failed to create a connector consent link.'
    }

    try {
        Start-Process $consentLink | Out-Null
    } catch {
        throw 'Unable to open a browser for connector consent.'
    }

    $deadline = (Get-Date).AddMinutes(5)
    do {
        Start-Sleep -Seconds 3
        $currentStatus = az connector-namespace connection show `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $connectorNamespaceConnectionName `
            --query 'properties.overallStatus' -o tsv 2>$null
    } while ($currentStatus -ne 'Connected' -and (Get-Date) -lt $deadline)

    if ($currentStatus -ne 'Connected') {
        throw 'Timed out waiting for the connector connection to reach Connected status.'
    }
}

$triggerConfigName = "$connectorNamespaceConnectionName-$($functionName.ToLowerInvariant())"
$namespaceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connectorGateways/$connectorNamespaceName"
$triggerConfigResourceId = "$namespaceResourceId/triggerConfigs/$triggerConfigName"
$apiVersion = '2026-05-01-preview'
$requestBody = [ordered] @{
    properties = [ordered] @{
        connectionDetails = [ordered] @{
            connectionName = $connectorNamespaceConnectionName
            connectorName = $connectorName
        }
        deliveryMode = 'Poll'
        description = $description
        operationName = $operationName
        parameters = $parameters
        state = 'Enabled'
        type = 'NotSpecified'
    }
} | ConvertTo-Json -Depth 8 -Compress

$bodyFile = Join-Path $PSScriptRoot ".poll-trigger-$([Guid]::NewGuid().ToString('N')).json"
try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($bodyFile, $requestBody, $utf8NoBom)

    Write-Host 'Creating or updating the retained Poll Trigger Config...' -ForegroundColor Yellow
    $responseJson = az rest `
        --method put `
        --uri "$triggerConfigResourceId`?api-version=$apiVersion" `
        --body "@$bodyFile" `
        -o json
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create or update the Connector Namespace Poll Trigger Config.'
    }
} finally {
    Remove-Item $bodyFile -ErrorAction SilentlyContinue
}

$triggerConfig = ($responseJson -join [Environment]::NewLine) | ConvertFrom-Json
if ($triggerConfig.properties.state -ne 'Enabled') {
    throw 'The Connector Namespace Poll Trigger Config was not enabled.'
}

if ($null -eq $triggerConfig.properties.pollingEndpoints) {
    $responseJson = az rest `
        --method get `
        --uri "$triggerConfigResourceId`?api-version=$apiVersion" `
        -o json
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to retrieve Poll Trigger Config endpoints.'
    }
    $triggerConfig = ($responseJson -join [Environment]::NewLine) | ConvertFrom-Json
}

$receiveUriText = [string] $triggerConfig.properties.pollingEndpoints.receiveUri
if ([string]::IsNullOrWhiteSpace($receiveUriText)) {
    throw 'Connector Namespace did not return properties.pollingEndpoints.receiveUri.'
}

$receiveUri = [Uri] $receiveUriText
if ($receiveUri.Scheme -ne 'https' -or
    -not [string]::IsNullOrEmpty($receiveUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($receiveUri.Fragment)) {
    throw 'The service-generated receiveUri is not a supported HTTPS Connector Namespace endpoint.'
}

$pathMatch = [regex]::Match(
    $receiveUri.AbsolutePath,
    '^(?<base>/api(?:/connectorGateways/[^/]+)?)/triggerConfigs/[^/]+/receive$',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
)
if (-not $pathMatch.Success) {
    throw 'The service-generated receiveUri does not match the supported Connector Namespace Poll path.'
}

$endpointBuilder = [UriBuilder] $receiveUri
$endpointBuilder.Path = if ($pathMatch.Groups['base'].Value -eq '/api') {
    ''
} else {
    $pathMatch.Groups['base'].Value
}
$endpointBuilder.Query = ''
$endpointBuilder.Fragment = ''
$pollingEndpoint = $endpointBuilder.Uri.AbsoluteUri.TrimEnd('/')

az functionapp config appsettings set `
    -g $resourceGroupName `
    -n $functionAppName `
    --settings `
        "ConnectorNamespace__pollingEndpoint=$pollingEndpoint" `
        "ConnectorTriggerConfigName=$triggerConfigName" `
    -o none | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to configure the Function App Poll settings.'
}

Write-Host 'The retained Connector Poll trigger is configured and enabled.' -ForegroundColor Green
