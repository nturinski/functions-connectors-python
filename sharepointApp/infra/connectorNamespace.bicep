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

resource sharepointConnection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' = {
  parent: connectorNamespace
  name: connectionName
  properties: {
    connectorName: 'sharepointonline'
  }
}

// Function App MI -> SharePoint connection (needed for Poll receive and acknowledge calls).
resource sharepointConnectionFunctionAppAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: sharepointConnection
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

// Connector Namespace system MI -> SharePoint connection (needed to run the connector trigger).
resource sharepointConnectionNamespaceAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: sharepointConnection
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

// Developer -> SharePoint connection (needed for local Poll debugging).
resource sharepointConnectionUserAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = if (!empty(userPrincipalId)) {
  parent: sharepointConnection
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

@description('The name of the SharePoint connection on the namespace.')
output connectionName string = sharepointConnection.name

@description('Runtime URL for the SharePoint connection.')
output sharepointConnectionRuntimeUrl string = sharepointConnection.properties.connectionRuntimeUrl
