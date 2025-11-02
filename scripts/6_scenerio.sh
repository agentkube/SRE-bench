#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
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
echo -e "${BLUE}  Scenario 6: ArgoCD Image Updater → Wrong Tag Match → Rollout Regression${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-6-cluster"
    fi

    CLUSTER_NAME="scenario-6-cluster"
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
  name: api-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: ${GIT_BRANCH}
    path: manifests/scenario-6
  destination:
    server: https://kubernetes.default.svc
    namespace: app-prod
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
kubectl get applications -n argocd api-service

# Wait for deployment
echo -e "\n${YELLOW}=== Waiting for Application to Deploy ===${NC}"
kubectl wait --for=condition=Available --timeout=120s deployment/api-service -n app-prod 2>/dev/null || echo "Deployment taking longer..."

echo -e "${GREEN}✓ Application deployed from Git (v1.2.1-hotfix)${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State (v1.2.1-hotfix) ===${NC}"
echo -e "${YELLOW}Current Deployment Image:${NC}"
kubectl get deployment api-service -n app-prod -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""

echo -e "\n${YELLOW}Pods:${NC}"
kubectl get pods -n app-prod

echo -e "\n${YELLOW}ConfigMap (includes new.feature.flag):${NC}"
kubectl get configmap app-config -n app-prod -o yaml | grep -A 10 "data:"

echo -e "\n${YELLOW}Application Logs (v1.2.1-hotfix working):${NC}"
kubectl logs -n app-prod -l app=api-service --tail=10 | head -15

# Simulate ArgoCD Image Updater behavior
echo -e "\n${CYAN}=== Simulating ArgoCD Image Updater ===${NC}"
echo "Image Updater is configured with pattern: semver (semantic versioning)"
echo "Available tags in registry:"
echo "  - v1.2.1-hotfix (current, correct version)"
echo "  - v1.2 (older version without hotfix)"
echo "  - v1.1"
echo ""
echo -e "${YELLOW}Image Updater regex misconfiguration:${NC}"
echo "Pattern matches: v1.2 instead of v1.2.1-hotfix"
echo "Reason: Regex doesn't account for '-hotfix' suffix"

sleep 3

# Simulate wrong image deployment
echo -e "\n${RED}=== Image Updater Selects Wrong Tag ===${NC}"
echo "ArgoCD Image Updater updates deployment to v1.2 (WRONG VERSION)"
echo "This version is OLDER and missing the hotfix!"

# Update deployment with wrong image (simulating v1.2 which needs different config)
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: app-prod
  labels:
    app: api-service
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-service
  template:
    metadata:
      labels:
        app: api-service
        version: v1.2  # WRONG VERSION
    spec:
      containers:
      - name: api
        image: nginx:1.20  # Older image simulating v1.2
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "API Service starting..."
            echo "Version: v1.2 (OLD VERSION - no hotfix!)"
            echo "Checking configuration..."

            # v1.2 does NOT expect NEW_FEATURE_FLAG (it didn't exist yet)
            # But ConfigMap has it, which is fine
            # The problem: v1.2 has the bug that v1.2.1-hotfix fixed!

            echo "WARNING: This is v1.2 - the bug is present!"
            echo "Expected version: v1.2.1-hotfix"
            echo ""
            
            # Simulate the bug that was fixed in v1.2.1-hotfix
            echo "ERROR: Critical bug in v1.2 detected!"
            echo "ERROR: Memory leak in request handler"
            echo "ERROR: This was fixed in v1.2.1-hotfix"
            
            # Fail readiness probe to simulate broken state
            exit 1
        env:
        - name: APP_ENV
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: app.env
        - name: LOG_LEVEL
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: log.level
        ports:
        - containerPort: 8080
          name: http
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'Request' > /dev/null"
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'sleep' > /dev/null"
          initialDelaySeconds: 10
          periodSeconds: 10
EOF

echo -e "${GREEN}✓ Deployment updated to v1.2 (wrong version)${NC}"
echo "Waiting for rollout..."
sleep 15

# Show broken state
echo -e "\n${BLUE}=== Degraded State ===${NC}"

echo -e "\n${YELLOW}Pod Status:${NC}"
kubectl get pods -n app-prod

echo -e "\n${YELLOW}Deployment Status:${NC}"
kubectl rollout status deployment/api-service -n app-prod --timeout=10s 2>&1 || echo "Rollout stalled/failed"

echo -e "\n${YELLOW}Current Deployment Image (WRONG):${NC}"
kubectl get deployment api-service -n app-prod -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""
echo -e "${RED}Expected: nginx:1.21 (v1.2.1-hotfix)${NC}"
echo -e "${RED}Got: $(kubectl get deployment api-service -n app-prod -o jsonpath='{.spec.template.spec.containers[0].image}') (v1.2)${NC}"

echo -e "\n${YELLOW}Failed Pod Logs:${NC}"
for pod in $(kubectl get pods -n app-prod -l app=api-service,version=v1.2 -o name | head -2); do
    echo -e "\n${BLUE}Logs from $pod:${NC}"
    kubectl logs $pod -n app-prod --tail=15 2>/dev/null || echo "Pod failed to start"
done

echo -e "\n${YELLOW}Events:${NC}"
kubectl get events -n app-prod --sort-by='.lastTimestamp' | tail -20

echo -e "\n${YELLOW}ArgoCD Application Status:${NC}"
kubectl get application api-service -n argocd -o jsonpath='{.status.sync.status}'
echo ""

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ ArgoCD Image Updater selected wrong image tag${NC}"
echo -e "${RED}✗ Updated to v1.2 instead of v1.2.1-hotfix${NC}"
echo -e "${RED}✗ v1.2 contains critical bug (fixed in v1.2.1-hotfix)${NC}"
echo -e "${RED}✗ Pods failing readiness probes${NC}"
echo -e "${RED}✗ Rollout paused - half pods running old version, half failing${NC}"
echo -e "${RED}✗ Service partially degraded${NC}"
echo -e "${RED}✗ Version mismatch between expected and deployed${NC}"

echo -e "\n${YELLOW}=== Root Cause ===${NC}"
echo "1. Production running v1.2.1-hotfix (stable)"
echo "2. ArgoCD Image Updater configured with semver pattern"
echo "3. Regex pattern misconfigured - doesn't handle '-hotfix' suffix"
echo "4. Image Updater matches v1.2 (older) instead of v1.2.1-hotfix"
echo "5. ArgoCD auto-syncs and deploys v1.2"
echo "6. v1.2 has critical bug that was fixed in v1.2.1-hotfix"
echo "7. New pods fail to start (bug causes immediate failure)"
echo "8. Rollout gets stuck - some old pods still running, new pods failing"
echo "9. Result: Partial outage with degraded service"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ ArgoCD sync events with unexpected image tags"
echo "✓ Image tag mismatch: expected v1.2.1-hotfix, got v1.2"
echo "✓ Failed readiness probes"
echo "✓ Pod status: CrashLoopBackOff / ImagePullBackOff"
echo "✓ Rollout stalled (waiting for pods to become ready)"
echo "✓ Version label mismatch in pods"
echo "✓ ArgoCD Application health status: Degraded"
echo "✓ Error logs showing known bug from v1.2"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this issue:"
echo ""
echo "Option 1: Manual Rollback to Correct Version (Quick Fix)"
echo "  1. Update deployment image manually:"
echo "     kubectl set image deployment/api-service api=nginx:1.21 -n app-prod"
echo "  2. Verify rollout:"
echo "     kubectl rollout status deployment/api-service -n app-prod"
echo ""
echo "Option 2: Fix ArgoCD Application (GitOps Way)"
echo "  1. Check current deployment image in Git"
echo "  2. If Git is correct (v1.2.1-hotfix), sync ArgoCD:"
echo "     kubectl patch application api-service -n argocd --type merge -p '{\"operation\":{\"sync\":{\"revision\":\"HEAD\"}}}'"
echo "  3. Disable Image Updater temporarily:"
echo "     kubectl annotate deployment api-service -n app-prod argocd-image-updater.argoproj.io/image-list-"
echo ""
echo "Option 3: Fix Image Updater Configuration"
echo "  1. Update Image Updater regex pattern to handle suffixes:"
echo "     Pattern should be: ^v1\\.2\\.1-hotfix$ (exact match)"
echo "     Or: ^v1\\.2\\.[0-9]+-.*$ (semver with suffix)"
echo "  2. Test pattern against available tags"
echo "  3. Re-enable Image Updater"
echo ""
echo "Option 4: Investigate and Verify"
echo "  kubectl get deployment api-service -n app-prod -o yaml | grep -A 5 'image:'"
echo "  kubectl describe application api-service -n argocd"
echo "  kubectl logs -n argocd deployment/argocd-image-updater"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Use strict semantic versioning patterns in Image Updater"
echo "• Test regex patterns against all possible tag formats"
echo "• Implement image tag validation in CI/CD"
echo "• Require manual approval for production image updates"
echo "• Use immutable tags or SHA digests for production"
echo "• Set up alerts for unexpected image tag changes"
echo "• Implement canary deployments to catch regressions early"
echo "• Use ArgoCD Image Updater write-back method to update Git"
echo "• Add constraints to only update patch versions"
echo "• Document tag naming conventions clearly"
echo "• Use image allowlist/denylist in Image Updater config"

echo -e "\n${YELLOW}=== Image Tag Best Practices ===${NC}"
echo "Good tag patterns:"
echo "  ✓ v1.2.1-hotfix   (clear semantic version with suffix)"
echo "  ✓ sha-abc123      (git commit SHA)"
echo "  ✓ v1.2.1+build.42 (semver with metadata)"
echo ""
echo "Bad tag patterns:"
echo "  ✗ latest          (mutable, no version info)"
echo "  ✗ prod            (mutable, no version info)"
echo "  ✗ v1.2            (ambiguous, might be v1.2.0 or v1.2.x)"
echo ""
echo "Image Updater regex examples:"
echo "  Exact match:     ^v1\\.2\\.1-hotfix$"
echo "  Patch versions:  ^v1\\.2\\.[0-9]+(-.*)?$"
echo "  With suffix:     ^v[0-9]+\\.[0-9]+\\.[0-9]+-[a-z]+$"

echo -e "\n${GREEN}=== Scenario 6 Complete ===${NC}"
echo "This demonstrates: ArgoCD Image Updater → Wrong Tag Match → Rollout Regression"
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
echo "• Try fixing the image to correct version (nginx:1.21)"
echo "• Practice writing regex patterns for Image Updater"
echo "• Experiment with ArgoCD Image Updater configurations"
echo "• Learn about semantic versioning best practices"
