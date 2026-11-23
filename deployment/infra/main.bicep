// Entry point for `azd provision`. Creates the resource group and every resource in it.
// Nothing here uses keys: all service-to-service access is managed identity + Azure RBAC.
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('azd environment name. Used to make resource names unique.')
param environmentName string

@description('Region for all resources. Must offer the chosen model deployments.')
param location string = 'eastus2'

@description('Region for Azure AI Search. Empty uses location; set it when that region has no Search capacity.')
param searchLocation string = ''

@description('Resource group to create or reuse.')
param resourceGroupName string = 'rg-rag-poc'

@description('Object ID of the single human operator. The only human granted access.')
param principalId string

@description('Principal type of the operator. Keep User so a service principal cannot be substituted silently.')
@allowed(['User'])
param principalType string = 'User'

@description('Client ID of the Entra app registration that protects the API. Empty keeps the API unreachable (no ingress).')
param apiAuthClientId string = ''

@description('Turn on API ingress. Set true only through scripts/enable-api-ingress.ps1, after the deployed Easy Auth configuration is verified.')
param apiIngressEnabled bool = false

@description('Client applications allowed to call the API. Default: Azure CLI only.')
param apiAllowedClientApplications array = ['04b07795-8ddb-461a-bbee-02f9e1bf7b46']

@description('Optional source IP ranges (CIDR) allowed to reach the API. Empty allows any source; Easy Auth still applies.')
param apiAllowedIpRanges array = []

@description('Run the ingestion job on a schedule. Keep false until the first seed is verified.')
param enableIngestSchedule bool = false

@description('UTC cron expression for scheduled updates.')
param ingestCron string = '0 6 * * *'

@description('Search index name. Change it to perform a blue/green rebuild.')
param searchIndexName string = 'rag-docs'

param embeddingModelName string = 'text-embedding-3-large'
param embeddingModelVersion string = '1'
param embeddingDeploymentName string = 'text-embedding-3-large'
@description('Thousands of tokens per minute.')
param embeddingCapacity int = 120
@allowed([256, 512, 1024, 1536, 3072])
param embeddingDimensions int = 3072

param chatModelName string = 'gpt-5.6-sol'
param chatModelVersion string = '2026-07-09'
param chatDeploymentName string = 'gpt-5.6-sol'
@description('Thousands of tokens per minute.')
param chatCapacity int = 50

@allowed(['local', 'git'])
param sourceKind string = 'local'
param gitUrl string = ''
param gitRef string = 'main'
param gitInclude string = '**/*.md'
param gitAllowedHosts string = 'github.com'

@description('Set by azd: true after the API app exists, so its image is preserved on re-provision.')
param apiExists bool = false
@description('Set by azd: true after the ingestion job exists.')
param ingestExists bool = false

var tags = { 'azd-env-name': environmentName, workload: 'rag-example' }
var effectiveSearchLocation = empty(searchLocation) ? location : searchLocation
var token = toLower(uniqueString(subscription().id, resourceGroupName, environmentName))

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module identities 'modules/identity.bicep' = {
  scope: rg
  name: 'identities'
  params: { location: location, tags: tags, token: token }
}

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  name: 'monitoring'
  params: { location: location, tags: tags, token: token }
}

module search 'modules/search.bicep' = {
  scope: rg
  name: 'search'
  params: { location: effectiveSearchLocation, tags: tags, name: 'srch-${token}', workspaceId: monitoring.outputs.workspaceId }
}

module ai 'modules/ai.bicep' = {
  scope: rg
  name: 'ai'
  params: {
    location: location
    tags: tags
    name: 'ai-${token}'
    workspaceId: monitoring.outputs.workspaceId
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    embeddingDeploymentName: embeddingDeploymentName
    embeddingCapacity: embeddingCapacity
    chatModelName: chatModelName
    chatModelVersion: chatModelVersion
    chatDeploymentName: chatDeploymentName
    chatCapacity: chatCapacity
  }
}

module acr 'modules/acr.bicep' = {
  scope: rg
  name: 'acr'
  params: { location: location, tags: tags, name: 'cr${token}' }
}

module roles 'modules/roles.bicep' = {
  scope: rg
  name: 'roles'
  params: {
    searchName: search.outputs.name
    aiName: ai.outputs.name
    acrName: acr.outputs.name
    appInsightsName: monitoring.outputs.appInsightsName
    apiPrincipalId: identities.outputs.apiPrincipalId
    ingestPrincipalId: identities.outputs.ingestPrincipalId
    userPrincipalId: principalId
    userPrincipalType: principalType
  }
}

module network 'modules/network.bicep' = {
  scope: rg
  name: 'network'
  params: { location: location, tags: tags, token: token }
}

module environment 'modules/containerapps-env.bicep' = {
  scope: rg
  name: 'containerapps-env'
  params: {
    location: location
    tags: tags
    name: 'cae-${token}'
    workspaceId: monitoring.outputs.workspaceId
    infrastructureSubnetId: network.outputs.infrastructureSubnetId
  }
}

var sharedEnv = [
  { name: 'AZURE_SEARCH_ENDPOINT', value: search.outputs.endpoint }
  { name: 'AZURE_SEARCH_INDEX', value: searchIndexName }
  { name: 'AZURE_OPENAI_ENDPOINT', value: ai.outputs.openAiEndpoint }
  { name: 'AZURE_OPENAI_EMBEDDING_DEPLOYMENT', value: embeddingDeploymentName }
  { name: 'AZURE_OPENAI_EMBEDDING_DIMENSIONS', value: string(embeddingDimensions) }
  { name: 'AZURE_OPENAI_CHAT_DEPLOYMENT', value: chatDeploymentName }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: monitoring.outputs.appInsightsConnectionString }
]

module apiImage 'modules/fetch-image.bicep' = {
  scope: rg
  name: 'api-image'
  params: { exists: apiExists, kind: 'app', name: 'ca-api-${token}' }
}

module ingestImage 'modules/fetch-image.bicep' = {
  scope: rg
  name: 'ingest-image'
  params: { exists: ingestExists, kind: 'job', name: 'caj-ingest-${token}' }
}

module api 'modules/api.bicep' = {
  scope: rg
  name: 'api'
  params: {
    location: location
    tags: tags
    name: 'ca-api-${token}'
    environmentId: environment.outputs.id
    identityId: identities.outputs.apiId
    identityClientId: identities.outputs.apiClientId
    registryServer: acr.outputs.loginServer
    image: apiImage.outputs.image
    sharedEnv: sharedEnv
    operatorPrincipalId: principalId
    authClientId: apiAuthClientId
    allowedClientApplications: apiAllowedClientApplications
    allowedIpRanges: apiAllowedIpRanges
    ingressEnabled: apiIngressEnabled
  }
  dependsOn: [roles]
}

module ingest 'modules/ingest-job.bicep' = {
  scope: rg
  name: 'ingest-job'
  params: {
    location: location
    tags: tags
    name: 'caj-ingest-${token}'
    environmentId: environment.outputs.id
    identityId: identities.outputs.ingestId
    identityClientId: identities.outputs.ingestClientId
    registryServer: acr.outputs.loginServer
    image: ingestImage.outputs.image
    sharedEnv: sharedEnv
    enableSchedule: enableIngestSchedule
    cron: ingestCron
    sourceKind: sourceKind
    gitUrl: gitUrl
    gitRef: gitRef
    gitInclude: gitInclude
    gitAllowedHosts: gitAllowedHosts
  }
  dependsOn: [roles]
}

output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.loginServer
output AZURE_SEARCH_ENDPOINT string = search.outputs.endpoint
output AZURE_SEARCH_INDEX string = searchIndexName
output AZURE_OPENAI_ENDPOINT string = ai.outputs.openAiEndpoint
output AZURE_OPENAI_EMBEDDING_DEPLOYMENT string = embeddingDeploymentName
output AZURE_OPENAI_EMBEDDING_DIMENSIONS int = embeddingDimensions
output AZURE_OPENAI_CHAT_DEPLOYMENT string = chatDeploymentName
output API_NAME string = api.outputs.name
output API_URL string = api.outputs.url
output INGEST_JOB_NAME string = ingest.outputs.name
output AZURE_APPLICATION_INSIGHTS_NAME string = monitoring.outputs.appInsightsName
