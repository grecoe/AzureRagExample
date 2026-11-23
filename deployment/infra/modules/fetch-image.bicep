// Keeps the image azd last deployed when infrastructure is re-provisioned.
// Before the first `azd deploy`, a public placeholder image is used.
param exists bool
@allowed(['app', 'job'])
param kind string
param name string

resource existingApp 'Microsoft.App/containerApps@2024-03-01' existing = if (exists && kind == 'app') {
  name: name
}

resource existingJob 'Microsoft.App/jobs@2024-03-01' existing = if (exists && kind == 'job') {
  name: name
}

var placeholder = kind == 'app' ? 'mcr.microsoft.com/dotnet/samples:aspnetapp' : 'mcr.microsoft.com/k8se/quickstart-jobs:latest'

output image string = !exists
  ? placeholder
  : (kind == 'app' ? existingApp!.properties.template.containers[0].image : existingJob!.properties.template.containers[0].image)
