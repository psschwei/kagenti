#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

set -x # echo so that users can understand what is happening
set -e # exit on error

# Function to check if an env variable is set
check_env_var() {
    local var_name="$1"
    if [ -z "${!var_name}" ]; then
        echo -e "\033[0;31mError:\033[0m The environment variable \033[1;33m${var_name}\033[0m is not set."
        return 1
    else
        echo -e "\033[0;32mSuccess:\033[0m The environment variable \033[1;33m${var_name}\033[0m is set."
        return 0
    fi
}

# function to preload a list of images in kind
preload_images_in_kind() {
  local KIND_CLUSTER_NAME="agent-platform"  
  local images=("$@")             
  for image in "${images[@]}"; do
    echo "Pulling image: $image"
    docker pull "$image"
    echo "Loading image into kind cluster: $image"
    kind load docker-image "$image" --name "$KIND_CLUSTER_NAME"
  done
  echo "All specified images have been preloaded into kind."
}

# Function to check if the deployment exists
deployment_exists() {
  local NAMESPACE=$1
  local DEPLOYMENT_NAME=$2  
  kubectl get deployment -n "$NAMESPACE" "$DEPLOYMENT_NAME" &> /dev/null
}

:
: -------------------------------------------------------------------------
: "Load env variables"
: 
if [ -f ${SCRIPT_DIR}/.env ]; then
    source ${SCRIPT_DIR}/.env
else
    echo -e "\033[0;31mError:\033[0m .env file not found."
    exit 1
fi

:
: -------------------------------------------------------------------------
: "Checking env variables are all set"
: 
env_vars=("TOKEN" "REPO_USER" "OPENAI_API_KEY")
unset_flag=0

# Loop through each env variable and check
for var in "${env_vars[@]}"; do
    check_env_var "$var" || unset_flag=1
done

# Exit the script if at least one variable is not set
if [ $unset_flag -eq 1 ]; then
    echo -e "\033[0;31mExiting:\033[0m One or more required environment variables are not set."
    exit 1
fi

echo -e "\033[0;32mAll env vars checks passed.\033[0m"

:
: -------------------------------------------------------------------------
: "Create a new kind cluster with kagenti operator"
: 
curl -sSL https://raw.githubusercontent.com/kagenti/kagenti-operator/main/beeai/scripts/install.sh | bash


:
: -------------------------------------------------------------------------
: "Preload images to avoid dockerhub pull rate limiting"
: 
preload_images_in_kind \
    "prom/prometheus:v3.1.0" \
    "python:3.11-slim-bookworm" \
    "alpine:latest"

:
: -------------------------------------------------------------------------
: "Install Istio Ambient using helm"
: 
:
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update
helm install istio-base istio/base -n istio-system --create-namespace --wait
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0-rc.1/standard-install.yaml
helm install istiod istio/istiod --namespace istio-system --set profile=ambient --wait
helm install istio-cni istio/cni -n istio-system --set profile=ambient --wait
helm install ztunnel istio/ztunnel -n istio-system --wait

:
: -------------------------------------------------------------------------
: "Check all istio pods running"
: 
:
kubectl rollout status -n istio-system daemonset/ztunnel 
kubectl rollout status -n istio-system daemonset/istio-cni-node 
kubectl rollout status -n istio-system deployment/istiod 

:
: -------------------------------------------------------------------------
: "Install Prometheus and Kiali"
: 
:
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.25/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.25/samples/addons/kiali.yaml

: -------------------------------------------------------------------------
: "Check all kiali and prometheus pods running"
: 
:
kubectl rollout status -n istio-system deployment/kiali
kubectl rollout status -n istio-system deployment/prometheus

:
: -------------------------------------------------------------------------
: "Create gateway and add nodeport service for external access"
: 
:
kubectl apply -f ${SCRIPT_DIR}/resources/http-gateway.yaml
kubectl apply -f ${SCRIPT_DIR}/resources/gateway-nodeport.yaml
kubectl annotate gateway http networking.istio.io/service-type=ClusterIP --namespace=kagenti-system

:
: -------------------------------------------------------------------------
: "Add waypoint gateway for egress to default namespace"
: 
:
kubectl apply -f ${SCRIPT_DIR}/resources/gateway-waypoint.yaml
kubectl rollout status -n default deployment/waypoint

:
: -------------------------------------------------------------------------
: "Add http routing for kiali"
: 
:
kubectl apply -f ${SCRIPT_DIR}/resources/kiali-route.yaml
kubectl label ns istio-system shared-gateway-access="true"

:
: -------------------------------------------------------------------------
: "Create github credentials secret"
: 
:
if ! kubectl get secret github-token-secret >/dev/null 2>&1; then
    kubectl create secret generic github-token-secret --from-literal=token="${TOKEN}"
else
    echo "secret github-token-secret already exists"  
fi

:
: -------------------------------------------------------------------------
: "Create openai credentials secret"
: 
:
if ! kubectl get secret openai-secret >/dev/null 2>&1; then
    kubectl create secret generic openai-secret --from-literal=apikey="${OPENAI_API_KEY}"
else
    echo "secret openai-secret already exists"  
fi

:
: -------------------------------------------------------------------------
: "Build and deploy the a2a langgraph currency agent"
: 
:
sed  "s|\${REPO_USER}|${REPO_USER}|g" ${SCRIPT_DIR}/../../examples/templates/a2a/a2a-currency-agent.yaml | kubectl apply -f -
until deployment_exists default a2a-currency-agent; do
  sleep 2
done
kubectl rollout status -n default deployment/a2a-currency-agent

:
: -------------------------------------------------------------------------
: "Build and deploy the a2a contact extractor agent"
: 
:
sed  "s|\${REPO_USER}|${REPO_USER}|g" ${SCRIPT_DIR}/../../examples/templates/a2a/a2a-contact-extractor-agent.yaml | kubectl apply -f -
until deployment_exists default a2a-contact-extractor-agent; do
  sleep 2
done
kubectl rollout status -n default deployment/a2a-contact-extractor-agent

:
: -------------------------------------------------------------------------
: "Build and deploy the acp ollama researcher agent"
: 
:
sed  "s|\${REPO_USER}|${REPO_USER}|g" ${SCRIPT_DIR}/../../examples/templates/acp/acp-ollama-researcher.yaml | kubectl apply -f -
until deployment_exists default acp-ollama-researcher; do
  sleep 2
done
kubectl rollout status -n default deployment/acp-ollama-researcher

:
: -------------------------------------------------------------------------
: "Build and deploy the mcp web fetch tool"
: 
:
sed  "s|\${REPO_USER}|${REPO_USER}|g" ${SCRIPT_DIR}/../../examples/templates/mcp/mcp-web-fetch.yaml | kubectl apply -f -
until deployment_exists default mcp-web-fetch; do
  sleep 2
done
kubectl rollout status -n default deployment/mcp-web-fetch

:
: -------------------------------------------------------------------------
: "Build and deploy the mcp get weather tool"
: 
:
sed  "s|\${REPO_USER}|${REPO_USER}|g" ${SCRIPT_DIR}/../../examples/templates/mcp/mcp-get-weather.yaml | kubectl apply -f -
until deployment_exists default mcp-get-weather; do
  sleep 2
done
kubectl rollout status -n default deployment/mcp-get-weather

:
: -------------------------------------------------------------------------
: "Build and deploy the acp ollama weather service agent"
: 
:
sed  "s|\${REPO_USER}|${REPO_USER}|g" ${SCRIPT_DIR}/../../examples/templates/acp/acp-ollama-weather-service.yaml | kubectl apply -f -
until deployment_exists default acp-weather-service; do
  sleep 2
done
kubectl rollout status -n default deployment/acp-weather-service

:
: -------------------------------------------------------------------------
: "Add http routing for all agents and tools"
: 
:
kubectl apply -f ${SCRIPT_DIR}/resources/routes

:
: -------------------------------------------------------------------------
: "Add service routes for egress"
: 
:
kubectl apply -f ${SCRIPT_DIR}/resources/service-entries


:
: -------------------------------------------------------------------------
: "Label default namespace for shared gateway access and waypoint egress"
: 
:
kubectl label ns default shared-gateway-access="true"
kubectl label ns default istio.io/use-waypoint=waypoint

:
: -------------------------------------------------------------------------
: "Add agents to the ambient mesh"
: 
:
kubectl label namespace default istio.io/dataplane-mode=ambient


