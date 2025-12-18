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
echo -e "${BLUE}  Scenario 0: Broken Image → ImagePullBackOff${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW}This is the simplest failure scenario - perfect for beginners${NC}"

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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-0-cluster"
    fi

    CLUSTER_NAME="scenario-0-cluster"
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

# Create namespace
echo -e "\n${YELLOW}=== Creating Namespace ===${NC}"
kubectl create namespace sre-demo --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespace 'sre-demo' created${NC}"

# Deploy the broken pod
echo -e "\n${YELLOW}=== Deploying Pod with Broken Image ===${NC}"
echo "Deploying pod that references a non-existent container image..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: broken-image-demo
  namespace: sre-demo
  labels:
    app: broken-image-demo
    scenario: "0"
spec:
  containers:
  - name: app
    image: nonexistent-registry.io/invalid-image:v1.0
    imagePullPolicy: Always
    resources:
      requests:
        memory: "64Mi"
        cpu: "100m"
      limits:
        memory: "128Mi"
        cpu: "200m"
EOF

echo -e "${GREEN}✓ Pod manifest applied${NC}"

# Wait for the failure to occur
echo -e "\n${YELLOW}=== Waiting for ImagePullBackOff ===${NC}"
echo "Kubernetes will try to pull the image and fail..."
echo "This typically takes 10-30 seconds to show ImagePullBackOff..."

# Initial wait
sleep 5
echo -e "\n${BLUE}Initial Status:${NC}"
kubectl get pods -n sre-demo

# Wait more for backoff
echo -e "\nWaiting for ImagePullBackOff state..."
sleep 15

# Show final status
echo -e "\n${BLUE}=== Scenario 0 Status ===${NC}"

echo -e "\n${YELLOW}Pod Status:${NC}"
kubectl get pods -n sre-demo -o wide

echo -e "\n${YELLOW}Pod Description (showing image pull errors):${NC}"
kubectl describe pod broken-image-demo -n sre-demo | grep -A 20 "Events:" || \
  kubectl describe pod broken-image-demo -n sre-demo | tail -30

echo -e "\n${YELLOW}Pod Events:${NC}"
kubectl get events -n sre-demo --sort-by='.lastTimestamp' --field-selector involvedObject.name=broken-image-demo

echo -e "\n${YELLOW}Detailed Pod Status:${NC}"
kubectl get pod broken-image-demo -n sre-demo -o jsonpath='{.status.containerStatuses[0].state}' | python3 -m json.tool 2>/dev/null || \
  kubectl get pod broken-image-demo -n sre-demo -o jsonpath='{.status.containerStatuses[0].state}'
echo ""

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ Pod is stuck in ImagePullBackOff/ErrImagePull state${NC}"
echo -e "${RED}✗ Container image 'nonexistent-registry.io/invalid-image:v1.0' does not exist${NC}"
echo -e "${RED}✗ Kubernetes cannot start the container${NC}"

echo -e "\n${YELLOW}=== Root Cause ===${NC}"
echo "1. Pod references an image from a non-existent registry"
echo "2. Kubernetes kubelet tries to pull the image"
echo "3. Image pull fails (registry unreachable or image not found)"
echo "4. Kubelet enters exponential backoff retry loop"
echo "5. Pod status shows ErrImagePull → ImagePullBackOff"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "• Pod status: ImagePullBackOff or ErrImagePull"
echo "• Events: Failed to pull image, rpc error, image not found"
echo "• Container status: waiting with reason ImagePullBackOff"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this issue:"
echo ""
echo "Option 1: Fix the image reference"
echo "  1. kubectl edit pod broken-image-demo -n sre-demo"
echo "     (Note: For pods, you need to delete and recreate)"
echo "  2. Update image to a valid reference: nginx:latest"
echo "  3. Recreate the pod"
echo ""
echo "Option 2: Quick fix with a working image"
echo "  kubectl delete pod broken-image-demo -n sre-demo"
echo "  kubectl run broken-image-demo --image=nginx:latest -n sre-demo"
echo ""
echo "Option 3: If registry requires authentication"
echo "  1. Create imagePullSecret:"
echo "     kubectl create secret docker-registry regcred \\"
echo "       --docker-server=<registry> --docker-username=<user> \\"
echo "       --docker-password=<password> -n sre-demo"
echo "  2. Update pod spec with imagePullSecrets"

echo -e "\n${YELLOW}=== Common Causes of ImagePullBackOff ===${NC}"
echo "1. Image doesn't exist in registry"
echo "2. Wrong image name or tag"
echo "3. Private registry without imagePullSecrets"
echo "4. Registry is down or unreachable"
echo "5. Network policies blocking registry access"
echo "6. Rate limiting from container registries (Docker Hub)"

echo -e "\n${GREEN}=== Scenario 0 Complete ===${NC}"
echo "This demonstrates: Broken Image → ImagePullBackOff"
echo ""
echo "This is the most basic Kubernetes failure scenario."
echo "Every SRE should be able to diagnose and fix this quickly!"
