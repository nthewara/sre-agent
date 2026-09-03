@description('Location for resources')
param location string

@description('SRE Agent name')
param agentName string

@description('User-Assigned Managed Identity resource ID')
param identityId string

@description('Application Insights App ID')
param appInsightsAppId string

@description('Application Insights Connection String')
@secure()
param appInsightsConnectionString string

@description('Application Insights resource ID')
param appInsightsId string

@description('Log Analytics workspace resource ID — used for the log-analytics agent connector')
param logAnalyticsId string

@description('Resource Group ID to add as managed resource')
param managedResourceGroupId string

@description('AKS cluster name — used to grant system identity K8s-level RBAC')
param aksClusterName string

@description('Resource ID of the VNet-injection subnet (delegated to Microsoft.App/environments). The agent sandbox runs here with egress forced through the Azure Firewall.')
param agentSubnetId string

@description('AI model provider for the agent (Anthropic enables web search; not in EU Data Boundary)')
@allowed([
  'Anthropic'
  'MicrosoftFoundry'
])
param modelProvider string = 'Anthropic'

@description('Upgrade channel — Preview enables early-access features (e.g., Code Interpreter, marketplace plugins)')
@allowed([
  'Preview'
  'Stable'
])
param upgradeChannel string = 'Preview'

@description('Enables workspace tools / early-access experimental features (paired with upgradeChannel: Preview)')
param enableEarlyAccessFeatures bool = true

var sreAgentAdminRoleId = 'e79298df-d852-4c6d-84f9-5d13249d1e55'

#disable-next-line BCP081
resource sreAgent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: {
    'hidden-link: /app-insights-resource-id': appInsightsId
    sample: 'zava-aks-postgres'
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    // VNet injection: the agent's sandbox (where its CLI tools run) is placed in
    // the delegated agent subnet, with ALL egress forced (UDR) through the Azure
    // Firewall. The firewall allow-list is deliberately minimal — the control plane
    // (ARM, Entra, Microsoft Graph) and Microsoft Learn over public service tags,
    // plus the AKS API server over the hub/spoke for the built-in RunKubectl*
    // system tools. Azure Monitor is private-only by default (lockAgentToPrivateMonitor):
    // public AzureMonitor is dropped and the agent reaches Log Analytics / App
    // Insights over the AMPLS private endpoint; the agent remains fully functional
    // over it. It does NOT permit a raw socket to PostgreSQL:5432, so SQL runs
    // through an in-cluster pod, not the sandbox.
    vnetConfiguration: {
      subnetResourceId: agentSubnetId
    }
    sandboxConfiguration: {
      egress: {
        mode: 'AzureVNet'
        vnetConfiguration: {
          usePrivateDnsResolution: true
        }
        // Remote (Streamable-HTTP) MCP servers — the microsoft-learn connector
        // below. We deliberately leave this OFF (the default). When TRUE, the
        // platform routes the MCP runtime endpoint (learn.microsoft.com/api/mcp)
        // as Rewrite{RoutingMode=Platform} — a platform broker that egresses
        // OUTSIDE the customer VNet, bypassing the hub Azure Firewall. That's an
        // egress escape hatch and contradicts this lab's "every connection gated
        // by our firewall" thesis (below). With it false, the MCP host instead
        // falls under AzureVNet's default-Allow and egresses through the VNet →
        // forced-tunnel → hub Azure Firewall, where the allow-microsoft-learn
        // collection (vnet.bicep) permits learn.microsoft.com AND
        // raw.githubusercontent.com (the in-sandbox mcp-broker fetches its server
        // bits there during the tools/list handshake). So BOTH the bits and the
        // runtime stream are governed by our firewall — no platform bypass. (The
        // only true pod-side bypass is the platform ExperimentalSettings flag
        // HttpMcpInSandbox, which defaults to the locked-down in-sandbox broker
        // and isn't exposed here.)
        allowHttpMcpServerNetworkAccess: false
        allowedCodeRepositories: []
        // Maximum lockdown: no bypass categories are allow-listed (allowedHosts/
        // Registries/CodeRepositories empty). Egress mode is AzureVNet, so the agent
        // gets REAL VNet egress (not an HTTP-proxy) — but every connection is gated by
        // the Azure Firewall above. Its rules permit ARM/Entra/Graph + Microsoft Learn
        // (public service tags) and the AKS API server over the hub/spoke (TCP 443;
        // the agent VNet has the AKS private-DNS zone linked + a firewall rule +
        // SNAT). Azure Monitor is private-only by default
        // (public AzureMonitor dropped; agent linked to the AMPLS private DNS) — the
        // agent remains fully functional over it. Everything else is denied by
        // design — the agent still cannot open a raw socket to PostgreSQL:5432.
        allowedRegistries: []
        allowedHosts: []
      }
      packages: []
    }
    knowledgeGraphConfiguration: {
      managedResources: [
        managedResourceGroupId
      ]
      identity: identityId
    }
    actionConfiguration: {
      mode: 'autonomous'
      identity: identityId
      accessLevel: 'High'
    }
    defaultModel: {
      name: 'Automatic'
      provider: modelProvider
    }
    upgradeChannel: upgradeChannel
    experimentalSettings: {
      EnableWorkspaceTools: enableEarlyAccessFeatures
    }
    incidentManagementConfiguration: {
      type: 'AzMonitor'
      connectionName: 'azmonitor'
    }
    mcpServers: []
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: appInsightsAppId
        connectionString: appInsightsConnectionString
      }
    }
  }
}

resource sreAgentAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sreAgent.id, deployer().objectId, sreAgentAdminRoleId)
  scope: sreAgent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sreAgentAdminRoleId)
    principalId: deployer().objectId
    principalType: 'User'
  }
}

// AKS RBAC Cluster Admin for agent's system-assigned identity
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-09-01' existing = {
  name: aksClusterName
}

resource aksRbacClusterAdminSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksCluster.id, sreAgent.id, 'aksrbacadmin-system')
  scope: aksCluster
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// RG-level roles for agent's system-assigned identity (matches UMI roles for redundancy)
resource readerSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, 'reader-system')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource monitoringReaderSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, 'monreader-system')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource contributorSystem 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreAgent.id, 'contributor-system')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: sreAgent.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Connectors use ARM child resources. Skills and incident filters are applied
// later through the public data-plane API because their ARM child types are
// unavailable to external tenants.

var aiResourceName = last(split(appInsightsId, '/'))
var lawResourceName = last(split(logAnalyticsId, '/'))

// --- Connectors ------------------------------------------------------------

#disable-next-line BCP081
resource appInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'app-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: appInsightsId
    extendedProperties: {
      armResourceId: appInsightsId
      resource: {
        name: aiResourceName
      }
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'log-analytics'
  properties: {
    dataConnectorType: 'LogAnalytics'
    dataSource: logAnalyticsId
    extendedProperties: {
      armResourceId: logAnalyticsId
      resource: {
        name: lawResourceName
      }
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource microsoftLearnConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'learn-docs'
  properties: {
    dataConnectorType: 'Mcp'
    dataSource: 'placeholder'
    extendedProperties: {
      type: 'http'
      endpoint: 'https://learn.microsoft.com/api/mcp'
      selectedTools: [
        'learn-docs_microsoft_docs_search'
        'learn-docs_microsoft_code_sample_search'
        'learn-docs_microsoft_docs_fetch'
      ]
      toolsVisibleToMetaAgent: [
        'learn-docs_microsoft_docs_search'
        'learn-docs_microsoft_code_sample_search'
        'learn-docs_microsoft_docs_fetch'
      ]
    }
    identity: ''
  }
}

// Azure Monitor connector — provisioned in Bicep so the portal doesn't have to
// jit-create it on first use. Schema is bare: no extendedProperties, no ARM
// resource id. Reachable resources are gated by the agent MSI's existing
// Reader + Monitoring Reader RG-scoped role assignments.
#disable-next-line BCP081
resource azureMonitorConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'azure-monitor'
  properties: {
    dataConnectorType: 'MonitorClient'
    dataSource: 'n/a'
    identity: 'system'
  }
}

// Skills and incident filters are synchronized by scripts/setup-sre-agent.ps1
// through the public SRE Agent data-plane API. ARM child resources for those
// extension types are restricted to internal tenants. Connectors remain ARM.

output agentName string = sreAgent.name
output agentId string = sreAgent.id
output agentEndpoint string = sreAgent.properties.agentEndpoint
output agentSystemPrincipalId string = sreAgent.identity.principalId
// Deep-link straight to this agent's blade so the operator lands on the
// Threads tab without having to pick the agent from a list.
output agentPortalUrl string = 'https://sre.azure.com/agents${sreAgent.id}'
