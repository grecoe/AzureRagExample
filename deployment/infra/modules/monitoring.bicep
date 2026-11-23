// Log Analytics for platform logs and Application Insights (Entra-only ingestion) for app telemetry.
param location string
param tags object
param token string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${token}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    // No shared-key ingestion or queries; everything uses Entra ID.
    features: { disableLocalAuth: true }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${token}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    // Instrumentation keys cannot ingest; telemetry needs an Entra token with Monitoring Metrics Publisher.
    DisableLocalAuth: true
  }
}

output workspaceId string = workspace.id
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
