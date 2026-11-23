// One user-assigned identity per workload so each gets only the roles it needs.
param location string
param tags object
param token string

resource api 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-api-${token}'
  location: location
  tags: tags
}

resource ingest 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-ingest-${token}'
  location: location
  tags: tags
}

output apiId string = api.id
output apiClientId string = api.properties.clientId
output apiPrincipalId string = api.properties.principalId
output ingestId string = ingest.id
output ingestClientId string = ingest.properties.clientId
output ingestPrincipalId string = ingest.properties.principalId
