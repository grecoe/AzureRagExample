// The ingestion job. It has no ingress. It starts manually until enableSchedule is true,
// then daily on the cron expression. Parallelism 1 means one writer to the index at a time.
param location string
param tags object
param name string
param environmentId string
param identityId string
param identityClientId string
param registryServer string
param image string
param sharedEnv array
param enableSchedule bool
param cron string
param sourceKind string
param gitUrl string
param gitRef string
param gitInclude string
param gitAllowedHosts string

var runConfig = { parallelism: 1, replicaCompletionCount: 1 }

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: name
  location: location
  tags: union(tags, { 'azd-service-name': 'ingest' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: enableSchedule ? 'Schedule' : 'Manual'
      replicaTimeout: 3600
      replicaRetryLimit: 0
      manualTriggerConfig: enableSchedule ? null : runConfig
      scheduleTriggerConfig: enableSchedule ? union(runConfig, { cronExpression: cron }) : null
      registries: [{ server: registryServer, identity: identityId }]
    }
    template: {
      containers: [
        {
          name: 'ingest'
          image: image
          resources: { cpu: json('1.0'), memory: '2Gi' }
          env: concat(sharedEnv, [
            { name: 'RAG_ROLE', value: 'ingest' } // Also names this container rag-ingest (cloud_RoleName) in Application Insights.
            { name: 'RAG_INGEST_MODE', value: 'update' }
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
            { name: 'RAG_SOURCE_KIND', value: sourceKind }
            { name: 'RAG_SOURCE_PATH', value: '/app/sample-data' }
            { name: 'RAG_GIT_URL', value: gitUrl }
            { name: 'RAG_GIT_REF', value: gitRef }
            { name: 'RAG_GIT_INCLUDE', value: gitInclude }
            { name: 'RAG_GIT_ALLOWED_HOSTS', value: gitAllowedHosts }
          ])
        }
      ]
    }
  }
}

output name string = job.name
