param location string = resourceGroup().location
param prefix string = 'sffw'

param adminUsername string
@secure()
param adminPassword string
param sshKey string = ''
param azureServiceFabricResourceProviderObjectId string


var uniqueNameFormat = '${prefix}-{0}-${uniqueString(resourceGroup().id, prefix)}'
var uniqueShortName = toLower('${prefix}${uniqueString(resourceGroup().id, prefix)}')

var hubAddressSpace = '10.1.0.0/16'
var hubFwSubnet = '10.1.0.0/26'
var hubFwManSubnet = '10.1.0.64/26'

var spokeAddressSpace = '10.2.0.0/16'
var spokeSfSubnet = '10.2.1.0/24'
var spokeTestVmSubnet = '10.2.2.0/24'
var spokeTestVmStaticIp = '10.2.2.4'

resource hubVnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: format(uniqueNameFormat, 'hub-vnet')
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        hubAddressSpace
      ]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: hubFwSubnet
        }
      }
      {
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: hubFwManSubnet
        }
      }
    ]
  }

  resource fwSubnet 'subnets' existing = {
    name: 'AzureFirewallSubnet'
  }

  resource fwManagementSubnet 'subnets' existing = {
    name: 'AzureFirewallManagementSubnet'
  }

  resource spokePeering 'virtualNetworkPeerings' = {
    name: 'to-spoke'
    properties: {
      allowVirtualNetworkAccess: true
      allowForwardedTraffic: true
      allowGatewayTransit: false
      useRemoteGateways: false
      remoteVirtualNetwork: {
        id: spokeVnet.id
      }
    }
  }
}

resource fwPip 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: format(uniqueNameFormat, 'fw-pip')
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource fw 'Microsoft.Network/azureFirewalls@2024-07-01' = {
  name: format(uniqueNameFormat, 'fw')
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: hubVnet::fwSubnet.id
          }
          publicIPAddress: {
            id: fwPip.id
          }
        }
      }
    ]
    networkRuleCollections: [
      {
        name: 'allow-sfspoke-outbound'
        properties: {
          action: {
            type: 'Allow'
          }
          priority: 150
          rules: [
            {
              name: 'allow-sfspoke-outbound'
              protocols: [
                'TCP'
              ]
              sourceAddresses: [
                spokeAddressSpace
              ]
              destinationAddresses: [
                '*'
              ]
              destinationPorts: [
                '*'
              ]
            }
          ]
        }
      }
    ]
    natRuleCollections: [
      {
        name: 'inbound-testvm'
        properties: {
          action: {
            type: 'Dnat'
          }
          priority: 200
          rules: [
            {
              name: 'testvm-ssh'
              protocols: [
                'TCP'
              ]
              translatedAddress: spokeTestVmStaticIp
              translatedPort: '22'
              sourceAddresses: [
                '*'
              ]
              destinationAddresses: [
                fwPip.properties.ipAddress
              ]
              destinationPorts: [
                '22'
              ]
            }
          ]
        }
      }
    ]
  }
}

resource spokeRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
  name: format(uniqueNameFormat, 'spoke-rt')
  location: location
  properties: {
    routes: [
      {
        name: 'default-route-to-fw'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: fw.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

resource spokeVnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: format(uniqueNameFormat, 'spoke-vnet')
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        spokeAddressSpace
      ]
    }
    subnets: [
      {
        name: 'sf'
        properties: {
          addressPrefix: spokeSfSubnet
          routeTable: {
            id: spokeRouteTable.id
          }
        }
      }
      {
        name: 'test-vm'
        properties: {
          addressPrefix: spokeTestVmSubnet
          routeTable: {
            id: spokeRouteTable.id
          }
        }
      }
    ]
  }

  resource sfSubnet 'subnets' existing = {
    name: 'sf'
  }
  resource testVmSubnet 'subnets' existing = {
    name: 'test-vm'
  }

  resource hubPeering 'virtualNetworkPeerings' = {
    name: 'to-hub'
    properties: {
      allowVirtualNetworkAccess: true
      allowForwardedTraffic: true
      allowGatewayTransit: false
      useRemoteGateways: false
      remoteVirtualNetwork: {
        id: hubVnet.id
      }
    }
  }
}

resource networkContributorRole 'Microsoft.Authorization/roleDefinitions@2022-05-01-preview' existing = {
  scope: subscription()
  name: '4d97b98b-1d4f-4787-a291-c67834d212e7' // Network Contributor
}

resource sfNetworkContribRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: spokeVnet
  name: guid(azureServiceFabricResourceProviderObjectId, spokeVnet.id, networkContributorRole.id)
  properties: {
    roleDefinitionId: networkContributorRole.id
    principalId: azureServiceFabricResourceProviderObjectId
    principalType: 'ServicePrincipal'
  }
}

resource sf 'Microsoft.ServiceFabric/managedClusters@2025-03-01-preview' = {
  name: format(uniqueNameFormat, 'sf')
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    dnsName: uniqueShortName

    adminUserName: adminUsername
    adminPassword: adminPassword

    clientConnectionPort: 19000
    httpGatewayConnectionPort: 19080

    subnetId: spokeVnet::sfSubnet.id
    useCustomVnet: true

    allowRdpAccess: true
  }

  resource systemNodes 'nodeTypes' = {
    name: 'System'
    properties: {
      isPrimary: true
      
      vmSize: 'Standard_DS2_v2'
      vmInstanceCount: 6
      dataDiskSizeGB: 256
      dataDiskType: 'StandardSSD_LRS'
      vmImagePublisher: 'MicrosoftWindowsServer'
      vmImageOffer: 'WindowsServer'
      vmImageSku: '2022-Datacenter-Azure-Edition'
      vmImageVersion: 'latest'
    }
  }
}

module testvm 'testvm.bicep' = if (!empty(sshKey)) {
  name: 'deployTestVM'
  params: {
    name: format(uniqueNameFormat, 'testvm')
    subnetId: spokeVnet::testVmSubnet.id
    staticIp: spokeTestVmStaticIp
    username: adminUsername
    sshKey: sshKey
    location: location
  }
}
