#!/bin/bash

###############################################################################
# Scenario 8: Argo Rollout Canary + Wrong Weighting -> Full Outage
#
# This scenario demonstrates:
# 1. Misconfigured canary weight (100% instead of 10%)
# 2. Full traffic shift to incompatible canary version
# 3. Schema mismatch causing validation failures
# 4. Slow rollback due to metrics collection delays
# 5. Complete service outage during canary deployment
#
# Primary Trigger: Canary weight misconfigured in Argo Rollout
# Propagation: 100% traffic to canary -> Schema incompatibility -> API failures
# Impact: Complete outage, 100% error rate, extended recovery time
###############################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="scenario-8-cluster"
NAMESPACE="canary-demo"
GIT_REPO="https://github.com/siddhantprateek/SRE-bench"
GIT_BRANCH="main"
MANIFEST_PATH="manifests/scenario-8"

# Parse command line arguments
USE_EXISTING_CLUSTER=false
KUBECONFIG_PATH=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster)
      USE_EXISTING_CLUSTER=true
      shift
      ;;
    --kubeconfig)
      KUBECONFIG_PATH="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--cluster] [--kubeconfig PATH]"
      exit 1
      ;;
  esac
done

# Set kubeconfig if provided
if [ -n "$KUBECONFIG_PATH" ]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
fi

print_header() {
  echo -e "\n${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
  echo -e "${GREEN} $1${NC}"
}

print_error() {
  echo -e "${RED} $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}  $1${NC}"
}

print_info() {
  echo -e "${BLUE}9 $1${NC}"
}

check_prerequisites() {
  print_header "Checking Prerequisites"

  local missing_tools=()

  if ! command -v kubectl &> /dev/null; then
    missing_tools+=("kubectl")
  fi

  if ! $USE_EXISTING_CLUSTER && ! command -v kind &> /dev/null; then
    missing_tools+=("kind")
  fi

  if [ ${#missing_tools[@]} -ne 0 ]; then
    print_error "Missing required tools: ${missing_tools[*]}"
    exit 1
  fi

  print_success "All prerequisites satisfied"
}

create_cluster() {
  if $USE_EXISTING_CLUSTER; then
    print_header "Using Existing Cluster"
    kubectl cluster-info
    return
  fi

  print_header "Creating Kind Cluster"

  if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    print_warning "Cluster ${CLUSTER_NAME} already exists, deleting..."
    kind delete cluster --name ${CLUSTER_NAME}
  fi

  cat <<EOF | kind create cluster --name ${CLUSTER_NAME} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

  print_success "Cluster created successfully"
}

install_argo_rollouts() {
  print_header "Installing Argo Rollouts"

  # Create namespace
  kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

  # Install Argo Rollouts controller
  kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

  print_info "Waiting for Argo Rollouts controller to be ready..."
  kubectl wait --for=condition=available --timeout=300s deployment/argo-rollouts -n argo-rollouts

  print_success "Argo Rollouts installed successfully"
}

install_argocd() {
  print_header "Installing ArgoCD"

  # Create namespace
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  # Install ArgoCD
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

  print_info "Waiting for ArgoCD to be ready..."
  kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

  print_success "ArgoCD installed successfully"
}

deploy_initial_version() {
  print_header "Deploying Initial Stable Version"

  # Create namespace
  kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

  # Create ArgoCD Application
  cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO}
    targetRevision: ${GIT_BRANCH}
    path: ${MANIFEST_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    syncOptions:
    - CreateNamespace=true
EOF

  print_info "Waiting for initial deployment to sync..."
  sleep 10
  kubectl wait --for=condition=available --timeout=300s deployment/api-service-stable -n ${NAMESPACE} || true

  print_success "Initial version deployed"
}

monitor_stable_version() {
  print_header "Monitoring Stable Version (v1.0)"

  print_info "Checking rollout status..."
  kubectl argo rollouts status api-service -n ${NAMESPACE} --watch=false || print_warning "Rollout not yet created"

  print_info "Checking pod status..."
  kubectl get pods -n ${NAMESPACE} -l app=api-service

  print_info "Tailing logs from stable version (10 seconds)..."
  timeout 10s kubectl logs -n ${NAMESPACE} -l app=api-service --tail=5 -f || true

  print_success "Stable version is running successfully"
  print_info "All requests succeed with v1 schema"
}

trigger_canary_deployment() {
  print_header "Triggering Canary Deployment (MISCONFIGURED)"

  print_warning "About to deploy canary with WRONG weight configuration"
  print_error "Bug: Canary weight set to 100% instead of 10%"
  print_error "This will send ALL traffic to incompatible canary version"

  # Trigger rollout by updating image
  kubectl argo rollouts set image api-service api=busybox:1.36 -n ${NAMESPACE}

  # Also inject the canary args from ConfigMap
  kubectl patch rollout api-service -n ${NAMESPACE} --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/command",
      "value": ["/bin/sh", "-c"]
    },
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args",
      "value": ["echo \"API Service starting...\"\necho \"Version: CANARY (v2.0)\"\necho \"DB Schema: v2 (NEW - INCOMPATIBLE with v1 data)\"\n\nREQUEST_COUNT=0\nSUCCESS_COUNT=0\nERROR_COUNT=0\n\nwhile true; do\n  REQUEST_COUNT=$((REQUEST_COUNT + 1))\n\n  # Canary version expects v2 schema, but production data is v1\n  echo \"[$(date)] Request #${REQUEST_COUNT} - Status: ERROR - Schema mismatch!\"\n  echo \"[$(date)] ERROR: Expected schema v2, got v1\"\n  echo \"[$(date)] ERROR: Field 'user_id' not found (renamed to 'userId' in v2)\"\n  echo \"[$(date)] ERROR: Validation failed: incompatible data format\"\n  ERROR_COUNT=$((ERROR_COUNT + 1))\n\n  ERROR_RATE=$((ERROR_COUNT * 100 / REQUEST_COUNT))\n  echo \"Stats: Total=${REQUEST_COUNT}, Success=${SUCCESS_COUNT}, Errors=${ERROR_COUNT}, Error Rate=${ERROR_RATE}%\"\n\n  sleep 2\ndone"]
    }
  ]'

  print_success "Canary deployment triggered"
}

observe_outage() {
  print_header "Observing Service Outage"

  print_error "Canary receiving 100% of traffic due to misconfiguration"
  print_error "Schema incompatibility causing validation failures"

  print_info "Watching rollout progression..."
  timeout 30s kubectl argo rollouts get rollout api-service -n ${NAMESPACE} --watch || true

  print_info "Checking error logs from canary pods (20 seconds)..."
  sleep 5
  timeout 20s kubectl logs -n ${NAMESPACE} -l app=api-service --tail=10 -f | grep -E "(ERROR|CANARY)" || true

  print_error "100% error rate detected!"
  print_error "All API requests failing due to schema mismatch"
}

demonstrate_slow_rollback() {
  print_header "Demonstrating Slow Rollback"

  print_warning "Analysis running but delayed due to 30s metric collection intervals"
  print_warning "Rollback will take several minutes to complete"

  print_info "Checking analysis status..."
  kubectl get analysisrun -n ${NAMESPACE}

  print_info "Initiating manual rollback due to critical errors..."
  kubectl argo rollouts abort api-service -n ${NAMESPACE}

  print_info "Watching rollback progress..."
  timeout 30s kubectl argo rollouts get rollout api-service -n ${NAMESPACE} --watch || true

  print_success "Rollback initiated (will take additional time to complete)"
}

show_impact() {
  print_header "Impact Summary"

  echo -e "${RED}${NC}"
  echo -e "${RED}         PRODUCTION INCIDENT          ${NC}"
  echo -e "${RED}${NC}"
  echo ""
  echo -e "${RED}Severity:${NC} P0 - Complete Outage"
  echo -e "${RED}Error Rate:${NC} 100% (all requests failing)"
  echo -e "${RED}Root Cause:${NC} Canary weight misconfigured (100% instead of 10%)"
  echo -e "${RED}Trigger:${NC} Schema incompatibility between v2 canary and v1 production data"
  echo ""
  echo -e "${YELLOW}Timeline:${NC}"
  echo "  T+0s:   Canary deployment triggered"
  echo "  T+5s:   100% traffic shifted to canary (WRONG)"
  echo "  T+10s:  Schema validation errors begin"
  echo "  T+30s:  First analysis run completes"
  echo "  T+60s:  Second analysis run fails"
  echo "  T+90s:  Manual rollback initiated"
  echo "  T+120s: Service recovery begins"
  echo ""
  echo -e "${YELLOW}Detection Signals:${NC}"
  echo "  " 100% error rate spike"
  echo "  " Schema validation failures"
  echo "  " Customer reports of API unavailability"
  echo "  " Analysis run failures"
  echo ""
  echo -e "${GREEN}Prevention:${NC}"
  echo "  1. Review canary weight configuration (should start at 10%)"
  echo "  2. Implement schema compatibility checks before deployment"
  echo "  3. Add faster analysis intervals (5s instead of 30s)"
  echo "  4. Use failFast policy for analysis"
  echo "  5. Add pre-deployment validation tests"
  echo "  6. Implement database migration strategy"
  echo "  7. Use feature flags for schema changes"
  echo ""
}

cleanup() {
  print_header "Cleanup"

  if $USE_EXISTING_CLUSTER; then
    read -p "Delete namespace ${NAMESPACE}? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      kubectl delete namespace ${NAMESPACE} --ignore-not-found
      kubectl delete application api-service -n argocd --ignore-not-found
      print_success "Namespace deleted"
    else
      print_info "Namespace preserved"
    fi
  else
    read -p "Delete cluster ${CLUSTER_NAME}? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      kind delete cluster --name ${CLUSTER_NAME}
      print_success "Cluster deleted"
    else
      print_info "Cluster preserved for investigation"
    fi
  fi
}

main() {
  print_header "Scenario 8: Argo Rollout Canary Misconfiguration"

  check_prerequisites
  create_cluster
  install_argo_rollouts
  install_argocd
  deploy_initial_version
  monitor_stable_version

  echo ""
  read -p "Press Enter to trigger misconfigured canary deployment..."
  echo ""

  trigger_canary_deployment
  observe_outage
  demonstrate_slow_rollback
  show_impact

  cleanup

  print_header "Scenario Complete"
  print_info "This scenario demonstrated how a misconfigured canary weight"
  print_info "combined with schema incompatibility can cause complete outages"
  print_info "and slow recovery times due to delayed metrics collection."
}

main
