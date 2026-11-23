// Private image registry. No admin user; access is RBAC only.
// Anonymous pull is a Standard/Premium feature, so it cannot be turned on for Basic.
param location string
param tags object
param name string

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

output name string = registry.name
output loginServer string = registry.properties.loginServer
