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
$FWROUTE_TABLE_NAME="${PREFIX}-fwrt"
$FWROUTE_NAME="${PREFIX}-fwrn"
$FWROUTE_NAME_INTERNET="${PREFIX}-fwinternet"
$ACR_NAME="makshacr"
$ACR_FULL_NAME="makshacr.azurecr.io"
$AGWPUBLICIP_NAME="${PREFIX}-agwpublicip" 
$AFD_NAME="AFDforAKS"
$AFD_HOST_NAME="${AFD_NAME}.azurefd.net" 
$SUB_ID=$(az keyvault secret show --name "subscriptionid" --vault-name "maksh-key-vault" --query value)
$APP_ID=$(az keyvault secret show --name "clientid" --vault-name "maksh-key-vault" --query value)
$APP_SECRET=$(az keyvault secret show --name "clientsecret" --vault-name "maksh-key-vault" --query value)
$TENANT_ID=$(az keyvault secret show --name "tenantid" --vault-name "maksh-key-vault" --query value)

# Login
az login --service-principal --username $APP_ID --password $APP_SECRET --tenant $TENANT_ID

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

# Create Public IP for Firewall
az network public-ip create -g $RG -n $FWPUBLICIP_NAME -l $LOC --sku "Standard"

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
    --action Dnat  --priority 100 `
    --destination-addresses $FWPUBLIC_IP --destination-ports 80 `
    --translated-address '10.42.1.100' --translated-port 80

# Add FW Network Rules
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'apiudp' --protocols 'UDP' --source-addresses '*' `
    --destination-addresses "AzureCloud.$LOC" --destination-ports 1194 --action allow `
    --priority 100
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'apitcp' --protocols 'TCP' --source-addresses '*' `
    --destination-addresses "AzureCloud.$LOC" --destination-ports 9000
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'acrtcp' --protocols 'TCP' --source-addresses '*' `
    --destination-addresses "AzureContainerRegistry" --destination-ports 443
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'mcrtcp' --protocols 'TCP' --source-addresses '*' `
    --destination-addresses "MicrosoftContainerRegistry" --destination-ports 443
az network firewall network-rule create -g $RG -f $FWNAME `
    --collection-name 'aksfwnr' -n 'time' --protocols 'UDP' --source-addresses '*' `
    --destination-fqdns 'ntp.ubuntu.com' --destination-ports 123

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

# Create AKS (Ignore the warning - Are you owner?. If it is an error - delete ~/.azure/aksServicePrincipal.json)
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

# Attach ACR
az aks update -g $RG -n $AKSNAME --attach-acr makshacr
az aks update -g $RG -n $AKSNAME --attach-acr $(az acr show -n $ACR_NAME --query "id" -o tsv)

# Workaround for Bug (https://github.com/Azure/AKS/issues/1517#issuecomment-675521448)
az aks get-credentials -g $RG -n $AKSNAME --admin
$ACR_UNAME=$(az acr credential show -n $ACR_FULL_NAME --query="username" -o tsv)
$ACR_PASSWD=$(az acr credential show -n $ACR_FULL_NAME --query="passwords[0].value" -o tsv)

# Create k8s secret
kubectl create secret docker-registry acr-secret `
  --docker-server=$ACR_FULL_NAME `
  --docker-username=$ACR_UNAME `
  --docker-password=$ACR_PASSWD

# Assign k8s secret to default service account
kubectl patch serviceaccount default -p '{\"imagePullSecrets\": [{\"name\": \"acr-secret\"}]}'

# Create all the services
kubectl apply -f .\manifests\jsi.yml
kubectl delete -f .\manifests\jsi.yml

# Browse
az aks browse -g $RG -n $AKSNAME 

# Create subnet for App Gateway
az network vnet subnet create `
    --resource-group $RG `
    --vnet-name $VNET_NAME `
    --name "AzureAppGatewaySubnet" `
    --address-prefix 10.42.3.0/24

# Create Public IP for App Gateway
az network public-ip create -g $RG -n $AGWPUBLICIP_NAME -l $LOC --sku "Basic"

# Create App Gateway
az network application-gateway create `
  --name $AGW_NAME `
  --location  $LOC `
  --resource-group $RG `
  --capacity 2 `
  --sku WAF_Medium `
  --http-settings-cookie-based-affinity Disabled `
  --frontend-port 80 `
  --http-settings-port 80 `
  --http-settings-protocol Http `
  --public-ip-address $AGWPUBLICIP_NAME `
  --vnet-name $VNET_NAME `
  --subnet "AzureAppGatewaySubnet" `
  --servers "10.42.1.100"

# Configure App Gateway
az network application-gateway waf-config set `
  --enabled true `
  --gateway-name $AGW_NAME `
  --resource-group $RG `
  --firewall-mode Prevention `
  --rule-set-version 3.0

  # Create http probe
az network application-gateway probe create `
    -g $RG `
    --gateway-name $AGW_NAME `
    -n defaultprobe-Http `
    --protocol http `
    --host 10.42.1.100 `
    --timeout 30 `
    --path /jsi

# Link http probe to application gateway
az network application-gateway http-settings update `
    -g $RG `
    --gateway-name $AGW_NAME `
    -n appGatewayBackendHttpSettings `
    --probe defaultprobe-Http

# Add Front Door CLI extension
az extension add --name front-door

# Create Front Door
az network front-door create `
    --resource-group $RG `
    --name $AFD_NAME `
    --backend-address $FWPUBLIC_IP `
    --path /jsi

# Delete default front-end endpoint
az network front-door frontend-endpoint delete `
    --resource-group $RG `
    --front-door-name $AFD_NAME `
    --name $AFD_NAME

# Create AFD WAF Policy
az network front-door waf-policy create `
    --resource-group $RG `
    --name "AFDWAFpolicy" `
    --mode "Prevention" `
    --disabled False

# Get AFD WAF Policy ID
$wafpolicyid = az network front-door waf-policy list `
    --resource-group $RG `
    --query "[?contains(name, 'AFDWAFpolicy')].id" | convertfrom-json

# Update Front Door front-end endpoint with WAF Policy
az network front-door frontend-endpoint create `
    --resource-group $RG `
    --front-door-name $AFD_NAME `
    --name $AFD_NAME `
    --host-name $AFD_HOST_NAME `
    --waf-policy $wafpolicyid



