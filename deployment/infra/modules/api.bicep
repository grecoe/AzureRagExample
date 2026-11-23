// The question-answering API. Three states, reached in order:
//   * authClientId empty                    -> locked: no ingress and no Easy Auth.
//   * authClientId set, ingressEnabled false -> Easy Auth configured, still no ingress. Run
//                                              scripts/enable-api-ingress.ps1 to verify it.
//   * authClientId set, ingressEnabled true  -> HTTPS ingress behind the verified Easy Auth. Only
//                                              the operator's object ID, calling through an
//                                              allowed client application, is admitted.
// Ingress is never enabled in the same deployment that first creates the auth configuration.
param location string
param tags object
param name string
param environmentId string
param identityId string
param identityClientId string
param registryServer string
param image string
param sharedEnv array
param operatorPrincipalId string
param authClientId string
param allowedClientApplications array
param allowedIpRanges array
@description('Set only after enable-api-ingress.ps1 has verified the deployed Easy Auth configuration.')
param ingressEnabled bool

var authConfigured = !empty(authClientId)
var exposed = authConfigured && ingressEnabled

var ipRules = [for (range, i) in allowedIpRanges: {
  name: 'allow-${i}'
  ipAddressRange: range
  action: 'Allow'
}]

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: union(tags, { 'azd-service-name': 'api' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: exposed
        ? {
            external: true
            targetPort: 8080
            transport: 'auto'
            allowInsecure: false
            ipSecurityRestrictions: empty(ipRules) ? null : ipRules
          }
        : null
      registries: [{ server: registryServer, identity: identityId }]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: image
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: concat(sharedEnv, [
            { name: 'RAG_ROLE', value: 'api' } // Also names this container rag-api (cloud_RoleName) in Application Insights.
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
            { name: 'AUTH_MODE', value: 'easyauth' }
            { name: 'ALLOWED_PRINCIPAL_IDS', value: operatorPrincipalId }
          ])
        }
      ]
      scale: { minReplicas: 0, maxReplicas: 2 }
    }
  }
}

// Easy Auth runs in front of the container and rejects anything without a valid token.
// No client secret: the API only validates bearer tokens; it never signs users in.
resource auth 'Microsoft.App/containerApps/authConfigs@2024-03-01' = if (authConfigured) {
  parent: app
  name: 'current'
  properties: {
    platform: { enabled: true }
    globalValidation: { unauthenticatedClientAction: 'Return401' }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: authClientId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [authClientId, 'api://${authClientId}']
          jwtClaimChecks: { allowedClientApplications: allowedClientApplications }
          defaultAuthorizationPolicy: {
            allowedPrincipals: { identities: [operatorPrincipalId] }
          }
        }
      }
    }
  }
}

output name string = app.name
output url string = exposed ? 'https://${app.properties.configuration.ingress.fqdn}' : ''
