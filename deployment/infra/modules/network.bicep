// Virtual network for the Container Apps environment. Some tenants use Azure Policy
// to deny environments without VNet injection. Workload-profile
// environments need a subnet delegated to Microsoft.App/environments (/27 minimum).
// The NSG keeps the platform default rules: no extra inbound ports are opened.
param location string
param tags object
param token string
param addressPrefix string = '10.40.0.0/16'
param infrastructureSubnetPrefix string = '10.40.0.0/23'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-cae-${token}'
  location: location
  tags: tags
  properties: { securityRules: [] }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${token}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [addressPrefix] }
    subnets: [
      {
        name: 'snet-cae'
        properties: {
          addressPrefix: infrastructureSubnetPrefix
          networkSecurityGroup: { id: nsg.id }
          delegations: [{ name: 'aca', properties: { serviceName: 'Microsoft.App/environments' } }]
        }
      }
    ]
  }
}

output infrastructureSubnetId string = vnet.properties.subnets[0].id