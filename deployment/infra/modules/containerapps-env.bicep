// Container Apps environment. Logs go to Log Analytics through diagnostic settings,
// so no workspace shared key is stored in the environment.
param location string
param tags object
param name string
param workspaceId string
@description('Delegated subnet for VNet injection. Required by tenant policy.')
param infrastructureSubnetId string

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: { destination: 'azure-monitor' }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    // internal: false keeps the option of public ingress (still gated by Easy Auth). Ingress stays off by default.
    vnetConfiguration: { infrastructureSubnetId: infrastructureSubnetId, internal: false }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: environment
  properties: {
    workspaceId: workspaceId
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

output id string = environment.id
