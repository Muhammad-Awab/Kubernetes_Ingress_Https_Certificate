#!/bin/bash

sp_name=""
app_id=""
password=""
tenant=""
subscription_id=""
email_address=""
resource_group=""
domain_name=""

CERT_MANAGER_VERSION="v1.14.5"
DEFAULT_SUBSCRIPTION_ID="your-default-subscription-id"

default_resource_group="we1-akstutorial-rg"
default_domain_name="letsencrypt-aks-tutorial.yourdomain.dev"
default_sp_name="cert-manager-dnssp"

# Color Definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Emojis
CHECK_MARK="${GREEN}✔️ ${NC}"
WARNING="${YELLOW}⚠️${NC}"
ERROR="${RED}❌${NC}"
INFO="${BLUE}ℹ️ ${NC}"

read_settings() {
    local settings_file="settings.json"
    
    # Check if settings.json exists and read the domain name and resource_group
    if [[ -f "$settings_file" ]]; then
        default_domain_name=$(jq -r '.domain_name' "$settings_file")
        default_resource_group=$(jq -r '.resource_group' "$settings_file")
        default_sp_name=$(jq -r '.sp_name' "$settings_file")
    fi

}


# Ensure CLI tools are installed
ensure_tools_installed() {
    if ! command -v az &> /dev/null
    then
        echo -e "${ERROR} Azure CLI could not be found. Please install it."
        exit 1
    fi

    if ! command -v kubectl &> /dev/null
    then
        echo -e "${ERROR} Kubectl could not be found. Please install it."
        exit 1
    fi

    if ! command -v jq &> /dev/null
    then
        echo -e "${ERROR} jq could not be found. Please install it."
        exit 1
    fi
}


get_subscription_id() {
    # Default subscription if none currently set
    local current_subscription=$(az account show --query "id" -o tsv 2>/dev/null)
    local default_subscription=${current_subscription:-$DEFAULT_SUBSCRIPTION_ID}

    # Prompt for subscription ID with proper handling of defaults
    echo -en "${GREEN}Enter Azure Subscription ID [${NC}${default_subscription}${GREEN}]: ${NC}"
    read subscription_id
    subscription_id=${subscription_id:-$default_subscription}

    echo -e "${CHECK_MARK} Using Azure Subscription ID: $subscription_id"
}

# Function to manage the service principal
manage_service_principal() {
    echo -e "${INFO} Checking for existing service principal named '$sp_name'..."

    # Get list of SPs with exact match
    sps=$(az ad sp list --display-name "$sp_name" --query "[?displayName=='$sp_name'].appId" -o tsv)
    if [ -z "$sps" ]; then
        sp_count=0
    else
        sp_count=$(echo "$sps" | wc -l | tr -d ' ')
    fi
    
    if [[ "$sp_count" -gt 1 ]]; then
        echo -e "${ERROR} Multiple service principals found with the name '$sp_name'. Please specify."
        exit 1
    elif [[ "$sp_count" -eq 0 ]]; then
        echo -e "${INFO} Creating new service principal with name '$sp_name'..."
        create_service_principal
    else
        app_id=$(echo "$sps")
        echo -e "${INFO} Service Principal already exists with ID: $app_id"

        tenant=$(az ad sp show --id $app_id --query "appOwnerOrganizationId" -o tsv)
        if [[ -z "$tenant" ]]; then
            echo -e "${ERROR} Failed to retrieve Tenant ID for the existing Service Principal."
            exit 1
        fi

        echo -e "${INFO} Tenant ID retrieved: $tenant"

        reset_service_principal_credentials
    fi
}

# Function to create a new service principal
create_service_principal() {
    local sp_credentials
    sp_credentials=$(az ad sp create-for-rbac --name "$sp_name" --role "DNS Zone Contributor" --scopes "/subscriptions/$subscription_id/resourceGroups/$resource_group" --query "{appId: appId, password: password, tenant: tenant}" --output json)

    app_id=$(echo $sp_credentials | jq -r '.appId')
    password=$(echo $sp_credentials | jq -r '.password')
    tenant=$(echo $sp_credentials | jq -r '.tenant')
   

    if [[ -z "$app_id" || -z "$password" || -z "$tenant" ]]; then
        echo -e "${ERROR} Failed to create Azure Service Principal or retrieve details."
        exit 1
    fi
    echo -e "${CHECK_MARK} Service Principal created successfully with ID: $app_id"
}

reset_service_principal_credentials() {
    echo -e "${INFO} Creating a new client secret for Service Principal ID: $app_id..."
    password=$(az ad sp credential reset --id $app_id --query "password" -o tsv)

    if [[ -z "$password" ]]; then
        echo -e "${ERROR} Failed to create a new client secret for the existing Service Principal."
        exit 1
    else
        echo -e "${INFO} New client secret created successfully."
    fi
}

validate_email_address() {
    if ! echo "$email_address" | grep -qE "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"; then
        echo -e "${ERROR} Invalid email address provided: $email_address"
        exit 1
    fi
}

validate_sp_name() {
    if [[ -z "$sp_name" ]]; then
        echo -e "${ERROR} Service Principal name cannot be empty. Please provide a valid name."
        exit 1
    fi
}

validate_domain_name() {
    if [[ -z "$domain_name" ]]; then
        echo -e "${ERROR} Domain name cannot be empty. Please provide a valid domain name."
        exit 1
    fi
}

install_or_update_cert_manager() {
    local version=$1
    if [[ -z "$version" ]]; then
        echo -e "${ERROR} No version number provided for cert-manager. Please specify a version."
        return 1
    fi

    local cert_manager_url="https://github.com/jetstack/cert-manager/releases/download/${version}/cert-manager.yaml"
    echo -e "${INFO} Installing or updating cert-manager to version ${version}..."
    kubectl apply --validate=false -f "$cert_manager_url"
    sleep 10 # Wait for cert-manager to be ready
}

create_or_ensure_namespace() {
    if ! kubectl get namespace cert-manager &> /dev/null; then
        echo -e "${INFO} Creating 'cert-manager' namespace..."
        kubectl create namespace cert-manager
    else
        echo -e "${INFO} Namespace 'cert-manager' already exists."
    fi
}

create_kubernetes_secret() {
    # Check if the secret already exists
    if kubectl get secret azuredns-config -n cert-manager &> /dev/null; then
        kubectl create secret generic azuredns-config --from-literal=client-secret="$password" -n cert-manager --dry-run=client -o yaml | kubectl apply -f -
    else
        kubectl create secret generic azuredns-config --from-literal=client-secret="$password" -n cert-manager
    fi
}

prepare_and_apply_cluster_issuer() {
    local template

    template=$(<cluster-issuer-template.yaml)
    template=${template//\$\{EMAIL_ADDRESS\}/$email_address}
    template=${template//\$\{CLIENT_ID\}/$app_id}
    template=${template//\$\{SUBSCRIPTION_ID\}/$subscription_id}
    template=${template//\$\{TENANT_ID\}/$tenant}
    template=${template//\$\{RESOURCE_GROUP_NAME\}/$resource_group}
    template=${template//\$\{DOMAIN_NAME\}/$domain_name}

    echo "$template" | kubectl apply -f -
    
    echo -e "${CHECK_MARK} ClusterIssuer configuration has been applied."
}

write_settings_to_file() {
    local domain_name=$1
    local resource_group=$2
    local sp_name=$3

    # Check if the domain name is provided
    if [[ -z "$domain_name" ]]; then
        echo "Domain name is required."
        return 1
    fi

    if [[ -z "$resource_group" ]]; then
        echo "Resource group is required."
        return 1
    fi

    # Create or overwrite the settings.json file with the new domain name
    cat > settings.json << EOF
{
    "domain_name": "$domain_name",
    "resource_group": "$resource_group",
    "sp_name": "$sp_name"	
}
EOF
}

main() {
    read_settings
    ensure_tools_installed
    get_subscription_id
    
    echo -en "\n${GREEN}Enter Azure resource group name [${NC}${default_resource_group}${GREEN}]: ${NC}"
    read resource_group
    resource_group=${resource_group:-$default_resource_group}

    echo -en "${GREEN}Enter the email address to use with Let's Encrypt: ${NC}"
    read email_address
    email_address=${email_address}
    validate_email_address

    
    echo -en "${GREEN}Enter your domain name [${NC}${default_domain_name}${GREEN}]: ${NC}"
    read domain_name
    domain_name=${domain_name:-$default_domain_name}
    validate_domain_name
    
    echo -en "${GREEN}Enter the name of the Azure Service Principal [${NC}${default_sp_name}${GREEN}]: ${NC}"
    read sp_name
    sp_name=${sp_name:-$default_sp_name}
    validate_sp_name
    
    write_settings_to_file $domain_name $resource_group $sp_name
    manage_service_principal
    
    echo -e "\n${INFO} Creating Kubernetes secret..."
    create_or_ensure_namespace
    install_or_update_cert_manager $CERT_MANAGER_VERSION
    create_kubernetes_secret

    prepare_and_apply_cluster_issuer
}

main
