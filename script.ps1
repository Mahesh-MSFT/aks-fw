$SUB_ID=$(az keyvault secret show --name "subscriptionid" --vault-name "maksh-key-vault" --query value)
$APP_ID=$(az keyvault secret show --name "clientid" --vault-name "maksh-key-vault" --query value)
$APPSECRET=$(az keyvault secret show --name "clientsecret" --vault-name "maksh-key-vault" --query value)
$TENANT_ID=$(az keyvault secret show --name "tenantid" --vault-name "maksh-key-vault" --query value)
$PASSWORD=$(az keyvault secret show --name "clientsecret" --vault-name "maksh-key-vault" --query value)

az login --service-principal --username $APP_ID --password $PASSWORD --tenant $TENANT_ID