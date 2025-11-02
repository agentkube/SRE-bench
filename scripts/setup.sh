#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

CLUSTER_NAME="${1:-sre-bench-cluster}"

echo -e "${GREEN}=== SRE-bench Setup Script ===${NC}"
echo "Cluster name: $CLUSTER_NAME"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check and install kind
echo -e "\n${YELLOW}Checking kind installation...${NC}"
if command_exists kind; then
    echo -e "${GREEN} kind is already installed${NC}"
    kind version
else
    echo -e "${YELLOW}kind not found. Installing kind...${NC}"

    # Detect OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
    esac

    KIND_VERSION="v0.20.0"
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind

    echo -e "${GREEN} kind installed successfully${NC}"
    kind version
fi

# Check and install kubectl
echo -e "\n${YELLOW}Checking kubectl installation...${NC}"
if command_exists kubectl; then
    echo -e "${GREEN} kubectl is already installed${NC}"
    kubectl version --client
else
    echo -e "${YELLOW}kubectl not found. Installing kubectl...${NC}"

    # Detect OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
    esac

    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/${OS}/${ARCH}/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/kubectl

    echo -e "${GREEN} kubectl installed successfully${NC}"
    kubectl version --client
fi

# Check if cluster already exists
echo -e "\n${YELLOW}Checking if cluster exists...${NC}"
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo -e "${YELLOW}Cluster '${CLUSTER_NAME}' already exists. Deleting it...${NC}"
    kind delete cluster --name "${CLUSTER_NAME}"
fi

# Create kind cluster
echo -e "\n${YELLOW}Creating kind cluster '${CLUSTER_NAME}'...${NC}"
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
- role: worker
EOF

echo -e "${GREEN} Cluster created successfully${NC}"

# Set kubectl context
kubectl cluster-info --context "kind-${CLUSTER_NAME}"

# Wait for nodes to be ready
echo -e "\n${YELLOW}Waiting for nodes to be ready...${NC}"
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo -e "\n${GREEN}=== Setup Complete ===${NC}"
echo -e "Cluster name: ${CLUSTER_NAME}"
echo -e "Kubeconfig: ${HOME}/.kube/config"
echo -e "\nTo use this cluster, run:"
echo -e "  kubectl config use-context kind-${CLUSTER_NAME}"
echo -e "\nTo delete this cluster, run:"
echo -e "  kind delete cluster --name ${CLUSTER_NAME}"
