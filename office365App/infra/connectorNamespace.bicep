param name string
param location string
param tags object = {}
param connectionName string
@description('Object (principal) ID of the function app user-assigned MI. Granted access to the connection for Poll receive and acknowledge calls.')
param functionAppPrincipalId string
@description('Optional. AAD object ID of a developer to grant access for local Poll debugging with Azure credentials.')
param userPrincipalId string = ''
param tenantId string = tenant().tenantId

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
}

resource office365Connection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' = {
  parent: connectorNamespace
  name: connectionName
  properties: {
    connectorName: 'office365'
  }
}

// Function App MI -> Office 365 connection (needed for Poll receive and acknowledge calls).
resource office365ConnectionFunctionAppAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: office365Connection
  name: 'functionapp-msi'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: functionAppPrincipalId
        tenantId: tenantId
      }
    }
  }
}

// Connector Namespace system MI -> Office 365 connection (needed to run the connector trigger).
resource office365ConnectionNamespaceAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: office365Connection
  name: 'connector-namespace-msi'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: connectorNamespace.identity.principalId
        tenantId: tenantId
      }
    }
  }
}

// Developer -> Office 365 connection (needed for local Poll debugging).
resource office365ConnectionUserAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = if (!empty(userPrincipalId)) {
  parent: office365Connection
  name: 'dev-user'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: userPrincipalId
        tenantId: tenantId
      }
    }
  }
}

@description('The resource ID of the Connector Namespace.')
output resourceId string = connectorNamespace.id

@description('The name of the Connector Namespace.')
output name string = connectorNamespace.name

@description('The name of the Office 365 connection on the namespace.')
output connectionName string = office365Connection.name

@description('Runtime URL for the Office 365 connection.')
output office365ConnectionRuntimeUrl string = office365Connection.properties.connectionRuntimeUrl
