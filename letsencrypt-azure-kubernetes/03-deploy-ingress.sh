#!/bin/bash

subscription_id=""
resource_group=""
external_ip=""
domain_name=""
name_servers=""

INGRESS_VERSION="v1.10.1"
SERVICE_NAME=${1:-"static-site-service"}

DEFAULT_SUBSCRIPTION_ID="your-default-subscription-id"
default_resource_group="we1-akstutorial-rg"
default_domain_name="letsencrypt-aks-tutorial.yourdomain.dev"

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
    fi

    if [[ -f "$settings_file" ]]; then
        default_resource_group=$(jq -r '.resource_group' "$settings_file")
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

deploy_nginx_ingress() {
    echo -e "${INFO} Deploying NGINX Ingress Controller version ${INGRESS_VERSION}...${NC}"
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${INGRESS_VERSION}/deploy/static/provider/cloud/deploy.yaml
    echo "Waiting for Ingress Controller to be ready..."
    sleep 10
}

deploy_static_site() {
    echo -e "${INFO} Deploying static site service and deployment...${NC}"
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: static-site
spec:
  replicas: 2
  selector:
    matchLabels:
      app: static-site
  template:
    metadata:
      labels:
        app: static-site
    spec:
      containers:
      - name: static-site
        image: dockersamples/static-site
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: static-site-service
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: static-site
EOF
}

# Function to configure Ingress to route to the static site service
configure_ingress() {
    echo -e "${INFO} Configuring Ingress for HTTPS redirection and TLS...${NC}"
    kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: static-site-ingress
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    cert-manager.io/cluster-issuer: "letsencrypt-azure-dns"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true" 
spec:
  tls:
  - hosts:
    - "${domain_name}"
    secretName: "${SERVICE_NAME}-tls"
  rules:
  - host: "${domain_name}"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: "${SERVICE_NAME}"
            port:
              number: 80
EOF
}


get_external_ip() {
    while [ -z $external_ip ]; do
        echo "Waiting for external IP..."
        external_ip=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
        sleep 5
    done
    echo -e "${CHECK_MARK} External IP for Ingress Controller is ${external_ip}${NC}"
}


update_dns_zone() {
    echo -e "${INFO} Creating DNS zone '$domain_name' in resource group '$resource_group'...${NC}"

    local output=$(az network dns zone create --name $domain_name --resource-group $resource_group --output json)
    echo -e "${CHECK_MARK} DNS zone created:\n$output${NC}"
    name_servers=$(echo $output | jq -r '.nameServers | join(", ")')
    
    echo -e "${INFO} Adding A record with IP $external_ip to zone $domain_name...${NC}"
    az network dns record-set a add-record --zone-name $domain_name --resource-group $resource_group --record-set-name "@" --ipv4-address $external_ip
}

main() {
    read_settings
    ensure_tools_installed
    get_subscription_id
    
    echo -en "\n${GREEN}Enter Azure resource group name [${NC}${default_resource_group}${GREEN}]: ${NC}"
    read resource_group
    resource_group=${resource_group:-$default_resource_group}

    echo -en "${GREEN}Enter your domain name [${NC}${default_domain_name}${GREEN}]: ${NC}"
    read domain_name
    domain_name=${domain_name:-$default_domain_name}
    
    deploy_nginx_ingress
    deploy_static_site
    configure_ingress
    get_external_ip
    update_dns_zone

    echo -e "${CHECK_MARK} Done. Ingress Controller has been deployed and DNS zone has been updated."
    echo -e "${INFO} Add a new NS record for '$domain_name' with these values in your registrar:"
    echo $name_servers | tr ',' '\n' | sed -e 's/\.$//' -e 's/ //g'
}

main