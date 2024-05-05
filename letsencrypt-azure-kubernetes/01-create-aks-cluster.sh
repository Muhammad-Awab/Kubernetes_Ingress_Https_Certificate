#!/bin/bash

subscription_id=""
resource_group=""
region=""
ssh_key_path=""
cluster_name=""
node_count=""
node_vm_size=""

# Default Configuration Values
DEFAULT_SUBSCRIPTION_ID="your-default-subscription-id"
DEFAULT_RESOURCE_GROUP="we1-akstutorial-rg"
DEFAULT_SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"
DEFAULT_CLUSTER_NAME="we1-akstutorial-cluster"
DEFAULT_NODE_COUNT=1
DEFAULT_REGION="West Europe"
DEFAULT_NODE_VM_SIZE="Standard_D2s_v3"

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

check_resource_group_exists() {
    echo -e "${INFO} Checking if resource group '$resource_group' exists..."
    if [[ $(az group exists --name "$resource_group") == "true" ]]; then
        echo -e "${CHECK_MARK} Resource group '$resource_group' already exists. Using existing group."
    else
        create_resource_group
    fi
}

create_resource_group() {
    echo -e "${INFO} Creating resource group '$resource_group' in '$region'..."
    az group create --name $resource_group --location "$region" --output none
    echo -e "${CHECK_MARK} Resource group created."
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

set_ssh_key() {
    if [[ -f $ssh_key_path ]]; then
        echo -en "${GREEN}Use existing SSH key found at $ssh_key_path? [Y/n]: ${NC}"
        read use_key
        if [[ $use_key =~ ^[Yy]$ || $use_key == "" ]]; then
            echo -e "${CHECK_MARK} Using existing SSH key."
        else
            echo -e "${INFO} Azure will generate a new SSH key during AKS creation."
            ssh_key_path=""  # Clear the variable to let Azure handle SSH key generation
        fi
    else
        echo -e "${WARNING} No existing SSH key found at $ssh_key_path. Azure will generate a new one during AKS creation."
        ssh_key_path=""  # Clear the variable to let Azure handle SSH key generation
    fi
}

create_aks_cluster() {
    echo -e "${INFO} Creating AKS cluster 'myAKSCluster' in resource group '$resource_group'..."
    if [[ -z $ssh_key_path ]]; then
        az aks create --resource-group $resource_group --name myAKSCluster \
            --node-count 2 --generate-ssh-keys --output none
    else
        az aks create --resource-group $resource_group --name myAKSCluster \
            --node-count 2 --ssh-key-value $ssh_key_path --output none
    fi
    echo -e "${CHECK_MARK} AKS cluster created."
}

create_aks_cluster() {
    echo -en "${GREEN}Enter AKS cluster name [${NC}${DEFAULT_CLUSTER_NAME}${GREEN}]: ${NC}"
    read cluster_name
    cluster_name=${cluster_name:-$DEFAULT_CLUSTER_NAME}

    echo -en "${GREEN}Enter node count [${NC}${DEFAULT_NODE_COUNT}${GREEN}]: ${NC}"
    read node_count
    node_count=${node_count:-$DEFAULT_NODE_COUNT}

    echo -en "${GREEN}Enter node VM size [${NC}${DEFAULT_NODE_VM_SIZE}${GREEN}]: ${NC}"
    read node_vm_size
    node_vm_size=${node_vm_size:-$DEFAULT_NODE_VM_SIZE}

    echo -e "${INFO} Creating AKS cluster '$cluster_name' in resource group '$resource_group'..."
    if [[ -z $ssh_key_path ]]; then
        az aks create --resource-group $resource_group --name $cluster_name \
            --enable-managed-identity --node-count $node_count --generate-ssh-keys --node-vm-size $node_vm_size --output none
    else
        az aks create --resource-group $resource_group --name $cluster_name \
            --enable-managed-identity --node-count $node_count --ssh-key-value $ssh_key_path --node-vm-size $node_vm_size --output none
    fi

    az aks get-credentials --resource-group $resource_group --name we1-akstutorial-cluster --overwrite-existing
    echo -e "${CHECK_MARK} AKS cluster created."
}

main() {
    ensure_tools_installed
    get_subscription_id

    echo -en "\n${GREEN}Enter Azure resource group name [${NC}${DEFAULT_RESOURCE_GROUP}${GREEN}]: ${NC}"
    read resource_group
    resource_group=${resource_group:-$DEFAULT_RESOURCE_GROUP}

    echo -en "\n${GREEN}Enter Azure region [${NC}${DEFAULT_REGION}${GREEN}]: ${NC}"
    read region
    region=${region:-$DEFAULT_REGION}

    check_resource_group_exists   
    ssh_key_path=${ssh_key_path:-$DEFAULT_SSH_KEY_PATH}
    set_ssh_key
    create_aks_cluster
}

main
