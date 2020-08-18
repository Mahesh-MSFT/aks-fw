$PREFIX="aks-fw"
$RG="${PREFIX}-rg"
$LOC="uksouth"
$PLUGIN="azure"
$AKSNAME="${PREFIX}"
$VNET_NAME="${PREFIX}-vnet"
$AKSSUBNET_NAME="aks-subnet"
$FWNAME="${PREFIX}"
$FWPUBLICIP_NAME="${PREFIX}-fwpublicip"
$FWIPCONFIG_NAME="${PREFIX}-fwconfig"
$SUB_ID=$(az keyvault secret show --name "subscriptionid" --vault-name "maksh-key-vault" --query value)
$APP_ID=$(az keyvault secret show --name "clientid" --vault-name "maksh-key-vault" --query value)
$APP_SECRET=$(az keyvault secret show --name "clientsecret" --vault-name "maksh-key-vault" --query value)
$TENANT_ID=$(az keyvault secret show --name "tenantid" --vault-name "maksh-key-vault" --query value)

# Login
az login --service-principal --username $APP_ID --password $PASSWORD --tenant $TENANT_ID

# Create Resource Group
az group create --name $RG --location $LOC

# Dedicated virtual network with AKS subnet
az network vnet create `
    --resource-group $RG `
    --name $VNET_NAME `
    --address-prefixes 10.42.0.0/16 `
    --subnet-name $AKSSUBNET_NAME `
    --subnet-prefix 10.42.1.0/24

# Dedicated subnet for Azure Firewall (Firewall name cannot be changed)
az network vnet subnet create `
--resource-group $RG `
--vnet-name $VNET_NAME `
--name "AzureFirewallSubnet" `
--address-prefix 10.42.2.0/24

# Deploy Azure Firewall
az network firewall create -g $RG -n $FWNAME -l $LOC --enable-dns-proxy true

# Configure Firewall IP Config
az network firewall ip-config create -g $RG -f $FWNAME -n $FWIPCONFIG_NAME --public-ip-address $FWPUBLICIP_NAME --vnet-name $VNET_NAME

# Capture Firewall IP Address for Later Use
$FWPUBLIC_IP=$(az network public-ip show -g $RG -n $FWPUBLICIP_NAME --query "ipAddress" -o tsv)
$FWPRIVATE_IP=$(az network firewall show -g $RG -n $FWNAME --query "ipConfigurations[0].privateIpAddress" -o tsv)

# Create UDR and add a route for Azure Firewall
az network route-table create -g $RG --name $FWROUTE_TABLE_NAME
az network route-table route create -g $RG --name $FWROUTE_NAME `
    --route-table-name $FWROUTE_TABLE_NAME --address-prefix 0.0.0.0/0 `
    --next-hop-type VirtualAppliance --next-hop-ip-address $FWPRIVATE_IP --subscription $SUB_ID
az network route-table route create -g $RG --name $FWROUTE_NAME_INTERNET `
    --route-table-name $FWROUTE_TABLE_NAME --address-prefix $FWPUBLIC_IP/32 `
    --next-hop-type Internet

# Add NAT Rules
az network firewall nat-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnatr' -n 'inboundtcp' --protocols 'TCP' --source-addresses '*' `
    --destination-addresses $FWPUBLIC_IP --destination-ports 80 `
    --priority 100 `
    --translated-address '10.42.1.100' --translated-port 80


# Add FW Network Rules
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'apiudp' --protocols 'UDP' --source-addresses '*' `
    --destination-addresses "AzureCloud.$LOC" --destination-ports 1194 --action allow `
    --priority 100
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'apitcp' --protocols 'TCP' --source-addresses '*' `
    --destination-addresses "AzureCloud.$LOC" --destination-ports 9000 --action allow `
    --priority 110
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'acrtcp' --protocols 'TCP' --source-addresses '*' `
    --destination-addresses "AzureContainerRegistry" --destination-ports 443 --action allow `
    --priority 120
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'mcrtcp' --protocols 'TCP' --source-addresses '*' `
    --destination-addresses "MicrosoftContainerRegistry" --destination-ports 443 `
    --action allow --priority 130
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'time' --protocols 'UDP' --source-addresses '*' `
    --destination-fqdns 'ntp.ubuntu.com' --destination-ports 123 --action allow --priority 140

# Add FW Application Rules
az network firewall application-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwar' -n 'fqdn' --source-addresses '*' --protocols 'http=80' 'https=443' `
    --fqdn-tags "AzureKubernetesService" --action allow --priority 100

# Associate route table with next hop to Firewall to the AKS subnet
az network vnet subnet update -g $RG --vnet-name $VNET_NAME `
    --name $AKSSUBNET_NAME --route-table $FWROUTE_TABLE_NAME

# Create subnet for AKS 
$SUBNET_ID=$(az network vnet subnet show -g $RG --vnet-name `
    $VNET_NAME --name $AKSSUBNET_NAME --query id -o tsv)

# Create AKS
az aks create -g $RG -n $AKSNAME -l $LOC `
  --node-count 1 --generate-ssh-keys `
  --network-plugin $PLUGIN `
  --outbound-type userDefinedRouting `
  --service-cidr 10.41.0.0/16 `
  --dns-service-ip 10.41.0.10 `
  --docker-bridge-address 172.17.0.1/16 `
  --vnet-subnet-id $SUBNET_ID `
  --service-principal $APP_ID `
  --client-secret $APP_SECRET