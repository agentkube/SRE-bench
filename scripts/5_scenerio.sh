#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
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
echo -e "${BLUE}  Scenario 5: Misconfigured Autoscaler → Cost Spike → Cluster Autoscaler Backoff${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-5-cluster"
    fi

    CLUSTER_NAME="scenario-5-cluster"
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
  name: web-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_BRANCH}
    path: manifests/scenario-5
  destination:
    server: https://kubernetes.default.svc
    namespace: production
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
sleep 15

# Check ArgoCD app status
kubectl get applications -n argocd web-app

# Install metrics-server (for HPA)
echo -e "\n${YELLOW}=== Installing Metrics Server ===${NC}"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch metrics-server for kind cluster compatibility
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "--kubelet-insecure-tls"
  }
]'

echo "Waiting for metrics-server to be ready..."
kubectl wait --for=condition=Available --timeout=120s deployment/metrics-server -n kube-system 2>/dev/null || echo "Metrics server taking longer..."
echo -e "${GREEN}✓ Metrics server installed${NC}"

# Wait for deployment
echo -e "\n${YELLOW}=== Waiting for Application to Deploy ===${NC}"
kubectl wait --for=condition=Available --timeout=120s deployment/web-app -n production 2>/dev/null || echo "Deployment taking longer..."

echo -e "${GREEN}✓ Application deployed from Git${NC}"

# Show initial state
echo -e "\n${BLUE}=== Initial State ===${NC}"
echo -e "${YELLOW}Pods:${NC}"
kubectl get pods -n production

echo -e "\n${YELLOW}HPA Status:${NC}"
kubectl get hpa -n production
kubectl describe hpa web-app-hpa -n production | grep -A 5 "Metrics:"

echo -e "\n${YELLOW}Current Metrics:${NC}"
kubectl top pods -n production 2>/dev/null || echo "Metrics not ready yet"

# Wait for HPA to activate
echo -e "\n${YELLOW}=== Observing HPA Behavior ===${NC}"
echo "HPA is configured with CPU target of 10% (DANGEROUSLY LOW)"
echo "maxReplicas: 200 (DANGEROUSLY HIGH)"
sleep 10

# Simulate load or just let natural CPU usage trigger HPA
echo -e "\n${YELLOW}=== Simulating Aggressive Scaling ===${NC}"
echo "Normal application CPU usage (even minimal) will exceed 10% target..."
echo "HPA will start aggressively scaling up..."

# Watch HPA scale up
echo -e "\n${MAGENTA}Watching HPA scale (this will happen quickly)...${NC}"
for i in {1..6}; do
  echo -e "\n${YELLOW}=== Observation ${i}/6 ===${NC}"
  REPLICA_COUNT=$(kubectl get deployment web-app -n production -o jsonpath='{.spec.replicas}')
  echo "Current replicas: ${REPLICA_COUNT}"
  kubectl get hpa web-app-hpa -n production
  kubectl top pods -n production 2>/dev/null | head -5 || echo "Metrics collecting..."
  sleep 10
done

# Show scaled state
echo -e "\n${BLUE}=== Scaled State ===${NC}"
FINAL_REPLICAS=$(kubectl get deployment web-app -n production -o jsonpath='{.spec.replicas}')
echo -e "${MAGENTA}Replica count grew to: ${FINAL_REPLICAS}${NC}"

kubectl get pods -n production | head -20
echo "..."
kubectl get pods -n production | tail -5

# Simulate cost monitoring alert
echo -e "\n${RED}=== 💰 COST ALERT TRIGGERED 💰 ===${NC}"
echo -e "${RED}┌────────────────────────────────────────────────┐${NC}"
echo -e "${RED}│  CRITICAL: Budget Anomaly Detected!           │${NC}"
echo -e "${RED}│                                                │${NC}"
echo -e "${RED}│  Current replica count: ${FINAL_REPLICAS} (was 3)              │${NC}"
echo -e "${RED}│  Estimated hourly cost: \$$$$ (was \$\$)          │${NC}"
echo -e "${RED}│  Projected monthly cost: \$\$\$\$\$                 │${NC}"
echo -e "${RED}│                                                │${NC}"
echo -e "${RED}│  Action: Emergency shutdown policy activated  │${NC}"
echo -e "${RED}└────────────────────────────────────────────────┘${NC}"

# Simulate emergency scale-down
echo -e "\n${YELLOW}=== Emergency Shutdown Policy ===${NC}"
echo "Budget policy triggers automatic scale-down..."
sleep 3

echo "Scaling down to emergency level (5 replicas)..."
kubectl scale deployment web-app -n production --replicas=5

echo -e "\n${YELLOW}Waiting for scale-down...${NC}"
sleep 10

# Show aftermath
echo -e "\n${BLUE}=== Aftermath ===${NC}"
kubectl get pods -n production
kubectl get hpa -n production

echo -e "\n${YELLOW}Pod Events:${NC}"
kubectl get events -n production --sort-by='.lastTimestamp' | tail -20

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ HPA misconfigured with 10% CPU target (should be 70-80%)${NC}"
echo -e "${RED}✗ maxReplicas set to 200 (too high)${NC}"
echo -e "${RED}✗ No stabilization window configured${NC}"
echo -e "${RED}✗ Aggressive scaling: 3 → ${FINAL_REPLICAS} replicas in minutes${NC}"
echo -e "${RED}✗ In cloud environment, would spin up ~100+ nodes${NC}"
echo -e "${RED}✗ Massive cost spike triggered budget alerts${NC}"
echo -e "${RED}✗ Emergency shutdown caused service disruption${NC}"
echo -e "${RED}✗ Abrupt scale-down caused pod terminations${NC}"

echo -e "\n${YELLOW}=== Root Cause ===${NC}"
echo "1. HPA configured with 10% CPU target (way too low)"
echo "2. maxReplicas set to 200 (no reasonable limit)"
echo "3. No stabilization window (instant scaling)"
echo "4. scaleUp policy: 100% every 15 seconds (doubles pods rapidly)"
echo "5. Even minimal CPU usage exceeds 10% threshold"
echo "6. HPA aggressively scales: 3 → 6 → 12 → 24 → 48 → 96 → ..."
echo "7. In cloud: Cluster Autoscaler would add 100+ nodes"
echo "8. Cost monitoring detects anomaly"
echo "9. Budget policy triggers emergency shutdown"
echo "10. Result: Cost spike + service disruption"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ Abnormal replica count increase"
echo "✓ HPA scaling events (rapid succession)"
echo "✓ Node count spike (in cloud environments)"
echo "✓ Cloud provider quota warnings"
echo "✓ Cost anomaly alerts"
echo "✓ Budget threshold exceeded"
echo "✓ Cluster autoscaler backoff messages"
echo "✓ API throttling errors (quota exhaustion)"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this issue:"
echo ""
echo "Option 1: Fix HPA Configuration in Git (GitOps way - RECOMMENDED)"
echo "  1. Update manifests/scenario-5/hpa.yaml:"
echo "     spec:"
echo "       minReplicas: 3"
echo "       maxReplicas: 10  # Reasonable limit"
echo "       metrics:"
echo "       - type: Resource"
echo "         resource:"
echo "           name: cpu"
echo "           target:"
echo "             type: Utilization"
echo "             averageUtilization: 70  # Realistic threshold"
echo "       behavior:"
echo "         scaleUp:"
echo "           stabilizationWindowSeconds: 60  # Add stabilization"
echo "  2. Commit and push to Git"
echo "  3. ArgoCD will sync the fix"
echo ""
echo "Option 2: Immediate Manual Fix"
echo "  1. Update HPA directly:"
echo "     kubectl patch hpa web-app-hpa -n production --type='json' -p='["
echo "       {\"op\": \"replace\", \"path\": \"/spec/minReplicas\", \"value\": 3},"
echo "       {\"op\": \"replace\", \"path\": \"/spec/maxReplicas\", \"value\": 10},"
echo "       {\"op\": \"replace\", \"path\": \"/spec/metrics/0/resource/target/averageUtilization\", \"value\": 70}"
echo "     ]'"
echo "  2. Then update Git to match"
echo ""
echo "Option 3: Monitor Current State"
echo "  kubectl get hpa web-app-hpa -n production --watch"
echo "  kubectl top pods -n production"
echo "  kubectl get events -n production --watch"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Set realistic HPA metrics and thresholds (70-80% CPU is standard)"
echo "• Configure reasonable maxReplicas based on actual capacity needs"
echo "• Always include stabilization windows (60-120 seconds)"
echo "• Implement cost guardrails and alerts at multiple thresholds"
echo "• Use cluster autoscaler limits (min/max nodes per zone)"
echo "• Set resource quotas per namespace to limit runaway scaling"
echo "• Regular autoscaling configuration reviews"
echo "• Test autoscaling behavior under load in staging"
echo "• Use PodDisruptionBudgets to control scale-down impact"
echo "• Monitor cost trends and set up anomaly detection"
echo "• Implement gradual rollout of HPA configuration changes"
echo "• Use VPA (Vertical Pod Autoscaler) recommendations for resource requests"

echo -e "\n${YELLOW}=== Cost Impact Analysis (Simulated) ===${NC}"
echo "In a real cloud environment (AWS/GCP/Azure):"
echo ""
echo "Before (healthy state):"
echo "  - 3 replicas"
echo "  - 1 node (3 pods fit)"
echo "  - Cost: ~\$100/month per node = \$100/month"
echo ""
echo "After misconfiguration (worst case):"
echo "  - ${FINAL_REPLICAS}+ replicas (trending toward 200)"
echo "  - ~30-60 nodes needed (depending on instance size)"
echo "  - Cost: ~\$100/month × 50 nodes = \$5,000/month"
echo "  - Spike duration: 15-30 minutes before detection"
echo "  - Actual cost impact: \$50-100 for the incident"
echo ""
echo "Lessons:"
echo "  - Misconfigured HPA can 50x your infrastructure costs"
echo "  - Always set maxReplicas to a reasonable value"
echo "  - Cost monitoring is critical"

echo -e "\n${GREEN}=== Scenario 5 Complete ===${NC}"
echo "This demonstrates: Misconfigured Autoscaler → Cost Spike → Emergency Shutdown"
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
echo "• Try fixing the HPA configuration to proper values"
echo "• Observe how HPA behaves with 70% CPU target"
echo "• Experiment with different stabilization windows"
echo "• Practice cost monitoring and alerting strategies"
