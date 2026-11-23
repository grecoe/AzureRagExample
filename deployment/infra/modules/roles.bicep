// Every role assignment in the system, scoped to the single resource that needs it.
// Workload identities get data-plane roles only. The operator is the only human principal.
param searchName string
param aiName string
param acrName string
param appInsightsName string
param apiPrincipalId string
param ingestPrincipalId string
param userPrincipalId string
param userPrincipalType string

var roleIds = {
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  searchIndexDataReader: '1407120a-92aa-4202-b7e9-c0e197c71c8f'
  openAiUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  acrPush: '8311e382-0749-4cb8-b61a-304f252e45ec'
  acrTasksContributor: 'fb382eab-e894-4461-af04-94435c366c3f'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
}

resource search 'Microsoft.Search/searchServices@2025-05-01' existing = { name: searchName }
resource ai 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = { name: aiName }
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = { name: acrName }
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = { name: appInsightsName }

var searchAssignments = [
  { principalId: apiPrincipalId, type: 'ServicePrincipal', role: roleIds.searchIndexDataReader }
  { principalId: ingestPrincipalId, type: 'ServicePrincipal', role: roleIds.searchIndexDataContributor }
  { principalId: userPrincipalId, type: userPrincipalType, role: roleIds.searchServiceContributor }
  { principalId: userPrincipalId, type: userPrincipalType, role: roleIds.searchIndexDataContributor }
]
var aiAssignments = [
  { principalId: apiPrincipalId, type: 'ServicePrincipal', role: roleIds.openAiUser }
  { principalId: ingestPrincipalId, type: 'ServicePrincipal', role: roleIds.openAiUser }
  { principalId: userPrincipalId, type: userPrincipalType, role: roleIds.openAiUser }
]
var acrAssignments = [
  { principalId: apiPrincipalId, type: 'ServicePrincipal', role: roleIds.acrPull }
  { principalId: ingestPrincipalId, type: 'ServicePrincipal', role: roleIds.acrPull }
  { principalId: userPrincipalId, type: userPrincipalType, role: roleIds.acrPush }
  // azd remote build: upload the build context, schedule the ACR Tasks run and stream its logs.
  { principalId: userPrincipalId, type: userPrincipalType, role: roleIds.acrTasksContributor }
]
var telemetryAssignments = [
  { principalId: apiPrincipalId, type: 'ServicePrincipal', role: roleIds.monitoringMetricsPublisher }
  { principalId: ingestPrincipalId, type: 'ServicePrincipal', role: roleIds.monitoringMetricsPublisher }
]

resource searchRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for a in searchAssignments: {
  name: guid(search.id, a.principalId, a.role)
  scope: search
  properties: {
    principalId: a.principalId
    principalType: a.type
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.role)
  }
}]

resource aiRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for a in aiAssignments: {
  name: guid(ai.id, a.principalId, a.role)
  scope: ai
  properties: {
    principalId: a.principalId
    principalType: a.type
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.role)
  }
}]

resource acrRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for a in acrAssignments: {
  name: guid(acr.id, a.principalId, a.role)
  scope: acr
  properties: {
    principalId: a.principalId
    principalType: a.type
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.role)
  }
}]

resource telemetryRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for a in telemetryAssignments: {
  name: guid(appInsights.id, a.principalId, a.role)
  scope: appInsights
  properties: {
    principalId: a.principalId
    principalType: a.type
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', a.role)
  }
}]
