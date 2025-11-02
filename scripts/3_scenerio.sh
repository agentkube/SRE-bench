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
echo -e "${BLUE}  Scenario 3: Node Pressure + HPA Misconfiguration → Evictions → Argo Rollback${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-3-cluster"
    fi

    CLUSTER_NAME="scenario-3-cluster"
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
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-applicationset-controller -n argocd 2>/dev/null || echo "ApplicationSet controller taking longer..."

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
  name: memory-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_BRANCH}
    path: manifests/scenario-3
  destination:
    server: https://kubernetes.default.svc
    namespace: app
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
kubectl get applications -n argocd memory-app

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

# Note: Namespace, Deployment, Service, and HPA are managed by ArgoCD from Git
echo -e "\n${YELLOW}=== Waiting for ArgoCD to Deploy v1 Application ===${NC}"
echo "ArgoCD is deploying from manifests/scenario-3/..."
sleep 15

# Show initial deployment status
echo -e "\n${BLUE}=== Initial Deployment (v1 from Git) ===${NC}"
kubectl get pods -n app 2>/dev/null || echo "Pods not yet created..."
kubectl get hpa -n app 2>/dev/null || echo "HPA not yet created..."

echo -e "\n${YELLOW}Waiting for v1 deployment to be ready...${NC}"
kubectl wait --for=condition=Available --timeout=120s deployment/memory-app -n app 2>/dev/null || echo "Deployment taking longer..."

echo -e "${GREEN}✓ Application v1 deployed and healthy from Git${NC}"

# Show deployed resources
kubectl get deployment,svc,hpa -n app

echo -e "${GREEN}✓ HPA deployed (misconfigured with minReplicas=5, CPU target=20% from Git)${NC}"
echo "Waiting for HPA to scale up to minReplicas..."
sleep 10

# Show initial healthy state
echo -e "\n${BLUE}=== Initial State (Before Memory Leak) ===${NC}"
kubectl get pods -n app
kubectl get hpa -n app
echo ""
kubectl top nodes 2>/dev/null || echo "Metrics not ready yet"

# Deploy new version (v2) with memory leak - BYPASSING GITOPS
echo -e "\n${YELLOW}=== Simulating Deployment Update to v2 (with Memory Leak) ===${NC}"
echo "NOTE: This update bypasses GitOps - deploying directly to cluster"
echo "This creates drift between Git (v1) and cluster (v2)"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: memory-app
  namespace: app
  labels:
    app: memory-app
    version: v2
  annotations:
    argocd.argoproj.io/tracking-id: "memory-app:apps/Deployment:app/memory-app"
spec:
  replicas: 5  # HPA will maintain this
  selector:
    matchLabels:
      app: memory-app
  template:
    metadata:
      labels:
        app: memory-app
        version: v2
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Application v2 starting..."
            echo "WARNING: This version has a memory leak!"

            # Simulate memory leak by accumulating data
            COUNTER=0
            LEAK_DATA=""

            while true; do
              COUNTER=\$((COUNTER + 1))

              # Memory leak: append data every iteration
              LEAK_DATA="\${LEAK_DATA}XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

              MEMORY_SIZE=\$((COUNTER * 2))
              echo "[\$(date)] Request #\${COUNTER} processed - Memory: \${MEMORY_SIZE}MB (LEAKING!)"

              # High CPU usage due to memory operations
              dd if=/dev/zero of=/dev/null bs=1M count=20 2>/dev/null &

              sleep 1

              # Simulate hitting memory limit
              if [ \$COUNTER -gt 30 ]; then
                echo "ERROR: Out of memory! Container will be OOMKilled soon..."
              fi
            done
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"  # Will hit this limit quickly
            cpu: "200m"
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'Request' > /dev/null"
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'sleep' > /dev/null"
          initialDelaySeconds: 10
          periodSeconds: 10
EOF

echo -e "${GREEN}✓ v2 deployed (with memory leak)${NC}"
echo "Waiting for memory leak to cause issues..."
sleep 20

# Show degraded state
echo -e "\n${BLUE}=== Degraded State (Memory Leak Active) ===${NC}"
echo -e "\n${YELLOW}Pod Status:${NC}"
kubectl get pods -n app

echo -e "\n${YELLOW}HPA Status:${NC}"
kubectl get hpa -n app

echo -e "\n${YELLOW}Node Resource Usage:${NC}"
kubectl top nodes 2>/dev/null || echo "Metrics collection in progress..."

echo -e "\n${YELLOW}Pod Resource Usage:${NC}"
kubectl top pods -n app 2>/dev/null || echo "Pod metrics collection in progress..."

echo -e "\n${YELLOW}Recent Pod Events:${NC}"
kubectl get events -n app --sort-by='.lastTimestamp' --field-selector involvedObject.kind=Pod | tail -20

echo -e "\n${YELLOW}Sample Pod Logs (showing memory leak):${NC}"
for pod in $(kubectl get pods -n app -l app=memory-app -o name | head -2); do
    echo -e "\n${BLUE}Logs from $pod:${NC}"
    kubectl logs $pod -n app --tail=10 2>/dev/null || echo "Pod not ready"
done

# Simulate node pressure and evictions
echo -e "\n${YELLOW}=== Simulating Node Pressure & Evictions ===${NC}"
echo "In a real scenario, nodes would experience memory pressure..."
echo "Simulating by scaling down and showing OOMKilled containers..."

# Check for OOMKilled containers
echo -e "\n${YELLOW}Checking for OOMKilled containers:${NC}"
kubectl get pods -n app -o json | grep -i "oomkilled" || echo "No OOMKilled containers yet (give it more time in real scenario)"

# Check ArgoCD drift detection
echo -e "\n${YELLOW}=== ArgoCD Drift Detection ===${NC}"
echo "ArgoCD detects that cluster state differs from Git..."
kubectl get applications -n argocd memory-app -o jsonpath='{.status.sync.status}' || echo ""
echo ""

# Simulate ArgoCD detecting unhealthy state and triggering rollback
echo -e "\n${YELLOW}=== ArgoCD Health Check Failure Detected ===${NC}"
echo "ArgoCD detects pods failing health checks (OOMKilled, restarts)..."
echo "Triggering sync to rollback to Git version (v1)..."
sleep 3

# Enable self-heal to trigger automatic rollback
echo -e "\n${YELLOW}=== ArgoCD Auto-Rollback (Sync to Git v1) ===${NC}"
kubectl patch application memory-app -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":true}}}}'  2>/dev/null || \
kubectl apply -f - <<SYNCEOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: memory-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_BRANCH}
    path: manifests/scenario-3
  destination:
    server: https://kubernetes.default.svc
    namespace: app
  syncPolicy:
    automated:
      prune: false
      selfHeal: true  # Enable self-heal to force rollback
    syncOptions:
    - CreateNamespace=true
SYNCEOF

echo -e "${GREEN}✓ ArgoCD sync triggered - rolling back to Git version (v1)${NC}"
echo "Note: Git has v1, which will be deployed now"

# Wait for ArgoCD to rollback
sleep 10

# But manually patch v1 to add the deprecated dependency issue (simulating a broken rollback)
echo -e "\n${YELLOW}=== Simulating v1 with Deprecated Dependency Issue ===${NC}"
echo "Even though v1 is rolled back, it has a problem with missing dependencies..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: memory-app
  namespace: app
  labels:
    app: memory-app
    version: v1-broken
  annotations:
    argocd.argoproj.io/tracking-id: "memory-app:apps/Deployment:app/memory-app"
spec:
  replicas: 5
  selector:
    matchLabels:
      app: memory-app
  template:
    metadata:
      labels:
        app: memory-app
        version: v1-broken
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Application v1 (rolled back) starting..."

            # Check for deprecated dependency
            echo "Checking dependencies..."
            if ! command -v deprecated-lib 2>/dev/null; then
              echo "WARNING: deprecated-lib not found!"
              echo "ERROR: Application partially broken - some features unavailable"
            fi

            echo "Starting with degraded functionality..."
            COUNTER=0
            ERROR_COUNT=0

            while true; do
              COUNTER=\$((COUNTER + 1))

              # Simulate partial functionality
              if [ \$((COUNTER % 3)) -eq 0 ]; then
                ERROR_COUNT=\$((ERROR_COUNT + 1))
                echo "[\$(date)] Request #\${COUNTER} - ERROR: Feature X unavailable (deprecated dependency missing)"
              else
                echo "[\$(date)] Request #\${COUNTER} - OK (limited functionality)"
              fi

              sleep 2
            done
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'Request' > /dev/null"
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 5  # More lenient to stay "ready" despite errors
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'sleep' > /dev/null"
          initialDelaySeconds: 10
          periodSeconds: 10
EOF

echo -e "${GREEN}✓ Rollback initiated${NC}"
echo "Waiting for rollback to complete..."
kubectl rollout status deployment/memory-app -n app --timeout=60s

# Show final degraded state
echo -e "\n${BLUE}=== Final State (After Rollback - Partially Broken) ===${NC}"
echo -e "\n${YELLOW}Pod Status:${NC}"
kubectl get pods -n app

echo -e "\n${YELLOW}HPA Status:${NC}"
kubectl get hpa -n app

echo -e "\n${YELLOW}Application Logs (showing partial failures):${NC}"
for pod in $(kubectl get pods -n app -l app=memory-app -o name | head -2); do
    echo -e "\n${BLUE}Logs from $pod:${NC}"
    kubectl logs $pod -n app --tail=15 2>/dev/null || echo "Pod not ready"
done

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ Application v2 deployed with memory leak${NC}"
echo -e "${RED}✗ HPA misconfigured (minReplicas=5, CPU target=20%)${NC}"
echo -e "${RED}✗ Aggressive scaling unable to handle memory leak${NC}"
echo -e "${RED}✗ Pods experiencing OOMKilled events${NC}"
echo -e "${RED}✗ Node memory pressure triggered evictions${NC}"
echo -e "${RED}✗ ArgoCD auto-rollback to v1${NC}"
echo -e "${RED}✗ v1 has deprecated dependency - partially broken${NC}"
echo -e "${RED}✗ Application in degraded state with error rate ~33%${NC}"

echo -e "\n${YELLOW}=== Root Cause ===${NC}"
echo "1. Application v2 introduced memory leak bug"
echo "2. HPA misconfigured with minReplicas too high (5) and CPU target too low (20%)"
echo "3. HPA aggressively scaled up, consuming more resources"
echo "4. Memory leak + high replica count → node memory pressure"
echo "5. Kubelet evicted pods due to memory pressure"
echo "6. ArgoCD detected failing health checks"
echo "7. Auto-rollback triggered to v1"
echo "8. v1 missing deprecated dependency → partial functionality"
echo "9. Result: Degraded service with persistent errors"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ OOMKilled container status"
echo "✓ Node memory pressure warnings"
echo "✓ Pod eviction events"
echo "✓ HPA unable to stabilize replica count"
echo "✓ Failed health checks"
echo "✓ ArgoCD rollback events"
echo "✓ Application errors in logs (deprecated dependency)"
echo "✓ Increased error rate (~33%)"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this issue:"
echo ""
echo "Option 1: Fix HPA in Git (GitOps way - RECOMMENDED)"
echo "  1. Update manifests/scenario-3/hpa.yaml:"
echo "     minReplicas: 2  # Change from 5"
echo "     averageUtilization: 70  # Change from 20"
echo "  2. Commit and push to Git"
echo "  3. Trigger ArgoCD sync:"
echo "     kubectl patch application memory-app -n argocd --type merge -p '{\"operation\":{\"sync\":{\"revision\":\"HEAD\"}}}'"
echo ""
echo "Option 2: Fix v1 deployment to include dependencies in Git"
echo "  1. Update manifests/scenario-3/deployment.yaml with required dependencies"
echo "  2. Commit and push"
echo "  3. ArgoCD will auto-sync"
echo ""
echo "Option 3: View ArgoCD Application status"
echo "  kubectl get applications -n argocd memory-app"
echo "  kubectl describe application memory-app -n argocd"
echo ""
echo "Option 4: Investigate memory leak in v2"
echo "   kubectl logs -n app -l app=memory-app,version=v2 --previous"
echo "   kubectl describe pod -n app <pod-name>"
echo ""
echo "Option 5: Monitor resource usage"
echo "   kubectl top nodes"
echo "   kubectl top pods -n app"
echo "   kubectl get hpa -n app --watch"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Set realistic HPA thresholds (typically 70-80% CPU)"
echo "• Configure appropriate minReplicas (start with 2-3)"
echo "• Set proper resource requests and limits based on profiling"
echo "• Implement memory profiling and leak detection in CI/CD"
echo "• Use Vertical Pod Autoscaler (VPA) for recommendations"
echo "• Test autoscaling under load in staging"
echo "• Add resource quotas per namespace to prevent runaway scaling"
echo "• Monitor node resource usage and set alerts"
echo "• Test rollback versions in staging before production"
echo "• Implement gradual rollout strategies (canary/blue-green)"
echo "• Set up ArgoCD sync windows for safer deployments"

echo -e "\n${GREEN}=== Scenario 3 Complete ===${NC}"
echo "This demonstrates: Node Pressure + HPA Misconfiguration → Evictions → Argo Rollback"
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
echo "• Try fixing the HPA configuration"
echo "• Deploy a v2.1 with the memory leak fixed"
echo "• Observe how proper HPA settings behave"
echo "• Practice identifying memory leaks from pod metrics"
