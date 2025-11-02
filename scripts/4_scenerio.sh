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
echo -e "${BLUE}  Scenario 4: NetworkPolicy Change → Service Mesh Timeout → API Chain Failure${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-4-cluster"
    fi

    CLUSTER_NAME="scenario-4-cluster"
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
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-server -n argocd 2>/dev/null || echo "ArgoCD server taking longer..."
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-repo-server -n argocd 2>/dev/null || echo "Repo server taking longer..."

echo -e "${GREEN}✓ ArgoCD installed${NC}"

# Create ArgoCD Applications (pointing to this Git repo)
echo -e "\n${YELLOW}=== Creating ArgoCD Applications ===${NC}"

# Get the Git repo URL
GIT_REPO_URL="https://github.com/agentkube/SRE-bench.git"
GIT_BRANCH="${GIT_BRANCH:-main}"

echo "Using Git repository: $GIT_REPO_URL"
echo "Branch: $GIT_BRANCH"

# Create Application for frontend
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: web-frontend
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_BRANCH}
    path: manifests/scenario-4/frontend
  destination:
    server: https://kubernetes.default.svc
    namespace: frontend
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
    - CreateNamespace=true
EOF

# Create Application for backend
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: auth-backend
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_BRANCH}
    path: manifests/scenario-4/backend
  destination:
    server: https://kubernetes.default.svc
    namespace: backend
  syncPolicy:
    automated:
      prune: false
      selfHeal: false
    syncOptions:
    - CreateNamespace=true
EOF

echo -e "${GREEN}✓ ArgoCD Applications created${NC}"

# Wait for ArgoCD to sync
echo -e "\n${YELLOW}=== Waiting for ArgoCD Initial Sync ===${NC}"
echo "ArgoCD is syncing manifests from Git..."
sleep 15

# Check ArgoCD app status
kubectl get applications -n argocd

# Wait for deployments
echo -e "\n${YELLOW}=== Waiting for Services to Deploy ===${NC}"
kubectl wait --for=condition=Available --timeout=120s deployment/auth-service -n backend 2>/dev/null || echo "Backend taking longer..."
kubectl wait --for=condition=Available --timeout=120s deployment/web-frontend -n frontend 2>/dev/null || echo "Frontend taking longer..."

echo -e "${GREEN}✓ Services deployed from Git${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
echo -e "${YELLOW}Backend (auth-service):${NC}"
kubectl get pods -n backend

echo -e "\n${YELLOW}Frontend (web-frontend):${NC}"
kubectl get pods -n frontend

echo -e "\n${YELLOW}Testing cross-namespace connectivity:${NC}"
sleep 5
kubectl logs -n frontend -l app=web-frontend --tail=10 | head -20

# Apply NetworkPolicy from Git (allows traffic)
echo -e "\n${YELLOW}=== Applying Initial NetworkPolicy (Allow) ===${NC}"
echo "This policy allows frontend -> backend communication"
kubectl apply -f https://raw.githubusercontent.com/agentkube/SRE-bench/${GIT_BRANCH}/manifests/scenario-4/networkpolicy-allow.yaml

echo -e "${GREEN}✓ NetworkPolicy applied - traffic allowed${NC}"
sleep 5

# Verify connectivity still works
echo -e "\n${BLUE}=== Verifying Connectivity (Should Work) ===${NC}"
kubectl logs -n frontend -l app=web-frontend --tail=5

# Simulate security engineer applying restrictive NetworkPolicy
echo -e "\n${YELLOW}=== Simulating Security Policy Update ===${NC}"
echo "Security engineer applies stricter NetworkPolicy to isolate namespaces..."
echo "This will BLOCK frontend -> backend communication"

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
  namespace: backend
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  # No ingress rules = deny all
EOF

echo -e "${GREEN}✓ Restrictive NetworkPolicy applied${NC}"
echo "WARNING: This blocks ALL ingress to backend namespace"

# Wait for the issue to manifest
echo -e "\n${YELLOW}=== Observing Service Failures ===${NC}"
echo "Frontend can no longer reach backend auth service..."
sleep 10

# Show failing state
echo -e "\n${BLUE}=== Scenario 4 Status ===${NC}"

echo -e "\n${YELLOW}Frontend Pod Status:${NC}"
kubectl get pods -n frontend

echo -e "\n${YELLOW}Backend Pod Status:${NC}"
kubectl get pods -n backend

echo -e "\n${YELLOW}Frontend Logs (showing timeouts):${NC}"
kubectl logs -n frontend -l app=web-frontend --tail=20

echo -e "\n${YELLOW}NetworkPolicies:${NC}"
kubectl get networkpolicies -n backend
kubectl describe networkpolicy deny-all-ingress -n backend | grep -A 10 "Spec:"

echo -e "\n${YELLOW}Recent Events:${NC}"
kubectl get events -n frontend --sort-by='.lastTimestamp' | tail -10
kubectl get events -n backend --sort-by='.lastTimestamp' | tail -10

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ NetworkPolicy updated to deny all ingress to backend${NC}"
echo -e "${RED}✗ Frontend cannot reach backend auth service${NC}"
echo -e "${RED}✗ 504 Gateway Timeout errors${NC}"
echo -e "${RED}✗ Retry storms causing increased load${NC}"
echo -e "${RED}✗ Customers experiencing authentication failures${NC}"
echo -e "${RED}✗ Error rate approaching 100%${NC}"

echo -e "\n${YELLOW}=== Root Cause ===${NC}"
echo "1. Security engineer applied stricter NetworkPolicy"
echo "2. New policy denies ALL ingress traffic to backend namespace"
echo "3. Frontend pods cannot connect to auth-service.backend"
echo "4. Connection attempts timeout after 2 seconds"
echo "5. Retry logic causes retry storms"
echo "6. Service chain broken → cascading failures"
echo "7. Result: API chain failure with 504 timeouts"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ 504 Gateway Timeout errors in logs"
echo "✓ Connection timeout patterns"
echo "✓ NetworkPolicy applied events"
echo "✓ Increased retry attempts"
echo "✓ Error rate spike in monitoring"
echo "✓ Service mesh timeout metrics (if using Istio/Linkerd)"
echo "✓ Cross-namespace connection failures"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this issue:"
echo ""
echo "Option 1: Rollback NetworkPolicy (Quick Fix)"
echo "  1. Delete restrictive policy:"
echo "     kubectl delete networkpolicy deny-all-ingress -n backend"
echo "  2. Verify connectivity restored:"
echo "     kubectl logs -n frontend -l app=web-frontend --tail=10"
echo ""
echo "Option 2: Update NetworkPolicy to Allow Required Traffic (GitOps Way)"
echo "  1. Review manifests/scenario-4/networkpolicy-allow.yaml"
echo "  2. Update backend NetworkPolicy in Git to allow frontend traffic"
echo "  3. Apply via kubectl or let ArgoCD sync"
echo "  4. Verify: kubectl get networkpolicies -n backend"
echo ""
echo "Option 3: Test Network Connectivity"
echo "  1. Get a frontend pod:"
echo "     kubectl exec -it -n frontend <pod-name> -- sh"
echo "  2. Test connection:"
echo "     nc -zv auth-service.backend.svc.cluster.local 8080"
echo "  3. Check NetworkPolicy:"
echo "     kubectl describe networkpolicy -n backend"
echo ""
echo "Option 4: View Service Communication"
echo "  kubectl get svc -n backend"
echo "  kubectl get svc -n frontend"
echo "  kubectl get endpoints -n backend"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Test NetworkPolicy changes in staging environment first"
echo "• Use network policy visualization tools (Cilium Editor, etc.)"
echo "• Implement gradual rollout of security policies"
echo "• Document service dependencies and communication patterns"
echo "• Add pre-deployment validation for NetworkPolicies"
echo "• Use service mesh observability (Istio/Linkerd) for impact analysis"
echo "• Set up monitoring for cross-namespace connectivity"
echo "• Create NetworkPolicy templates with known-good configurations"
echo "• Implement policy dry-run testing"
echo "• Require peer review for NetworkPolicy changes"

echo -e "\n${YELLOW}=== Quick Fix (Uncommenting will fix) ===${NC}"
echo "# Restore connectivity by deleting restrictive policy:"
echo "# kubectl delete networkpolicy deny-all-ingress -n backend"
echo "#"
echo "# Or apply the allow policy:"
echo "# kubectl apply -f manifests/scenario-4/networkpolicy-allow.yaml"

echo -e "\n${GREEN}=== Scenario 4 Complete ===${NC}"
echo "This demonstrates: NetworkPolicy Change → Service Mesh Timeout → API Chain Failure"
echo ""
echo -e "${YELLOW}Cluster Information:${NC}"
if [ "$SKIP_SETUP" = false ]; then
    echo "Cluster name: kind-${CLUSTER_NAME}"
    echo "To delete: kind delete cluster --name ${CLUSTER_NAME}"
else
    echo "Using existing cluster: ${CLUSTER_NAME:-default}"
fi
echo ""
echo -e "${YELLOW}Next Steps for Learning:${NC}"
echo "• Try deleting the restrictive NetworkPolicy and observe recovery"
echo "• Experiment with different NetworkPolicy configurations"
echo "• Practice debugging cross-namespace connectivity issues"
echo "• Learn about NetworkPolicy selectors and rules"
