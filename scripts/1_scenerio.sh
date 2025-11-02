#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
CLUSTER_NAME=""
KUBECONFIG_PATH=""
SKIP_SETUP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster)
            CLUSTER_NAME="$2"
            SKIP_SETUP=true
            shift 2
            ;;
        --kubeconfig)
            KUBECONFIG_PATH="$2"
            SKIP_SETUP=true
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --cluster NAME        Use existing cluster (skips setup)"
            echo "  --kubeconfig PATH     Path to kubeconfig file (skips setup)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "If no options provided, will run setup.sh to create new cluster"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Scenario 1: Stale ConfigMap → Argo CD Drift → Application CrashLoopBackOff${NC}"
echo -e "${BLUE}========================================${NC}"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Setup phase - only if not skipped
if [ "$SKIP_SETUP" = false ]; then
    echo -e "\n${YELLOW}=== Running Setup ===${NC}"

    # Check if kind is installed
    if ! command_exists kind; then
        echo -e "${YELLOW}kind not found. Running setup script...${NC}"
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        bash "${SCRIPT_DIR}/setup.sh"
    else
        echo -e "${GREEN}✓ kind is installed${NC}"

        # Create cluster using setup script
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        bash "${SCRIPT_DIR}/setup.sh" "scenario-1-cluster"
    fi

    CLUSTER_NAME="scenario-1-cluster"
    kubectl config use-context "kind-${CLUSTER_NAME}"
else
    echo -e "\n${YELLOW}=== Using Existing Cluster ===${NC}"

    # Set kubeconfig if provided
    if [ -n "$KUBECONFIG_PATH" ]; then
        export KUBECONFIG="$KUBECONFIG_PATH"
        echo -e "${GREEN}Using kubeconfig: $KUBECONFIG_PATH${NC}"
    fi

    # Set cluster context if provided
    if [ -n "$CLUSTER_NAME" ]; then
        kubectl config use-context "$CLUSTER_NAME" 2>/dev/null || \
        kubectl config use-context "kind-$CLUSTER_NAME" 2>/dev/null || {
            echo -e "${RED}Error: Could not set context for cluster '$CLUSTER_NAME'${NC}"
            exit 1
        }
        echo -e "${GREEN}Using cluster: $CLUSTER_NAME${NC}"
    fi
fi

# Verify cluster access
echo -e "\n${YELLOW}=== Verifying Cluster Access ===${NC}"
if ! kubectl cluster-info &>/dev/null; then
    echo -e "${RED}Error: Cannot access Kubernetes cluster${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Cluster access verified${NC}"
kubectl get nodes

# Install ArgoCD
echo -e "\n${YELLOW}=== Installing ArgoCD ===${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "Installing ArgoCD components..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-server -n argocd
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-repo-server -n argocd
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-applicationset-controller -n argocd

echo -e "${GREEN}✓ ArgoCD installed successfully${NC}"

# Create ArgoCD Application (pointing to this Git repo)
echo -e "\n${YELLOW}=== Creating ArgoCD Application ===${NC}"

# Get the Git repo URL
GIT_REPO_URL="https://github.com/agentkube/SRE-bench.git"
GIT_BRANCH="${GIT_BRANCH:-main}"

echo "Using Git repository: $GIT_REPO_URL"
echo "Branch: $GIT_BRANCH"

cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_BRANCH}
    path: manifests/scenario-1
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-app
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
    - CreateNamespace=true
EOF

echo -e "${GREEN}✓ ArgoCD Application created${NC}"

# Wait for ArgoCD to sync
echo -e "\n${YELLOW}=== Waiting for ArgoCD Initial Sync ===${NC}"
echo "ArgoCD is syncing manifests from Git..."
sleep 10

# Check ArgoCD app status
kubectl get applications -n argocd demo-app

# Note: ArgoCD will deploy from Git, which has the stale ConfigMap (missing new.feature)
echo -e "\n${YELLOW}Application will fail to start due to missing new.feature in Git ConfigMap${NC}"
echo "Waiting for initial deployment (pods will crash)..."
sleep 15

# Show failing pods
echo -e "\n${BLUE}=== Initial Deployment Status (From Git) ===${NC}"
kubectl get pods -n demo-app 2>/dev/null || echo "Namespace/pods not created yet"
kubectl get configmap app-config -n demo-app -o yaml 2>/dev/null | grep -A 10 "data:" || echo "ConfigMap not found"

echo -e "\n${YELLOW}=== Simulating Manual Hotfix (bypassing GitOps) ===${NC}"
echo "DevOps engineer updates ConfigMap directly in cluster..."
kubectl patch configmap app-config -n demo-app --type merge -p '{"data":{"new.feature":"enabled"}}'

echo -e "${GREEN}✓ ConfigMap patched with new.feature${NC}"

# Restart deployment to pick up new config
echo -e "\n${YELLOW}=== Restarting Deployment ===${NC}"
kubectl rollout restart deployment/demo-app -n demo-app
kubectl rollout status deployment/demo-app -n demo-app --timeout=60s

echo -e "${GREEN}✓ Application is now running with hotfixed config${NC}"

# Check ArgoCD drift detection
echo -e "\n${YELLOW}=== Checking ArgoCD Drift Detection ===${NC}"
echo "ArgoCD detects that cluster state differs from Git..."
kubectl get applications -n argocd demo-app -o jsonpath='{.status.sync.status}' || echo ""
echo ""

# Simulate engineer triggering ArgoCD sync/refresh (or it happens automatically)
echo -e "\n${YELLOW}=== Triggering ArgoCD Sync (Rollback to Git) ===${NC}"
echo "Syncing application to Git state (which has stale ConfigMap)..."

# Use kubectl patch to trigger sync (simulates 'argocd app sync demo-app')
kubectl patch application demo-app -n argocd --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'  2>/dev/null || \
kubectl apply -f - <<SYNCEOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_BRANCH}
    path: manifests/scenario-1
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-app
  syncPolicy:
    automated:
      prune: false
      selfHeal: true  # Enable self-heal to force rollback
    syncOptions:
    - CreateNamespace=true
SYNCEOF

echo -e "${GREEN}✓ ArgoCD sync triggered - rolling back to Git version${NC}"
echo "Note: Git ConfigMap is missing new.feature key"

# Wait for ArgoCD to rollback the ConfigMap
sleep 10

# Verify ConfigMap was rolled back
echo -e "\n${YELLOW}Verifying ConfigMap rollback:${NC}"
kubectl get configmap app-config -n demo-app -o yaml | grep -A 5 "data:"

# Trigger rollout to show CrashLoopBackOff
echo -e "\n${YELLOW}=== Pods Restarting with Rolled-Back Config ===${NC}"
kubectl rollout restart deployment/demo-app -n demo-app 2>/dev/null || echo "Deployment restarting..."

echo "Waiting to observe CrashLoopBackOff..."
sleep 15

echo -e "\n${BLUE}=== Scenario 1 Status ===${NC}"
echo -e "\n${YELLOW}Pod Status:${NC}"
kubectl get pods -n demo-app

echo -e "\n${YELLOW}Pod Events:${NC}"
kubectl get events -n demo-app --sort-by='.lastTimestamp' | tail -20

echo -e "\n${YELLOW}Pod Logs (showing failures):${NC}"
for pod in $(kubectl get pods -n demo-app -l app=demo-app -o name | head -1); do
    echo -e "\n${BLUE}Logs from $pod:${NC}"
    kubectl logs $pod -n demo-app --tail=20 || echo "Pod not ready yet"
done

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ Application pods are crashing${NC}"
echo -e "${RED}✗ Missing NEW_FEATURE environment variable${NC}"
echo -e "${RED}✗ ConfigMap was manually updated (bypassing GitOps)${NC}"
echo -e "${RED}✗ ArgoCD sync rolled back to stale config${NC}"
echo -e "${RED}✗ Application now in CrashLoopBackOff${NC}"

echo -e "\n${YELLOW}=== Root Cause ===${NC}"
echo "1. Manual hotfix applied directly to cluster (bypassing Git)"
echo "2. ArgoCD detected drift but auto-sync was disabled"
echo "3. ArgoCD reconciliation rolled back to Git version"
echo "4. Application requires new.feature config that's now missing"
echo "5. Result: CrashLoopBackOff"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this issue:"
echo ""
echo "Option 1: Fix in Git (GitOps way - RECOMMENDED)"
echo "  1. Update manifests/scenario-1/configmap.yaml to add new.feature key:"
echo "     data:"
echo "       new.feature: \"enabled\""
echo "  2. Commit and push to Git"
echo "  3. Trigger ArgoCD sync:"
echo "     kubectl patch application demo-app -n argocd --type merge -p '{\"operation\":{\"sync\":{\"revision\":\"HEAD\"}}}'"
echo "  4. Verify: kubectl get pods -n demo-app"
echo ""
echo "Option 2: Manual hotfix (NOT recommended - creates drift)"
echo "  1. kubectl patch configmap app-config -n demo-app --type merge -p '{\"data\":{\"new.feature\":\"enabled\"}}'"
echo "  2. kubectl rollout restart deployment/demo-app -n demo-app"
echo "  3. Then update Git to match cluster state"
echo ""
echo "Option 3: View ArgoCD Application status"
echo "  kubectl get applications -n argocd demo-app"
echo "  kubectl describe application demo-app -n argocd"

echo -e "\n${GREEN}=== Scenario 1 Complete ===${NC}"
echo "This demonstrates: Stale ConfigMap → Argo CD Drift → Application CrashLoopBackOff"
