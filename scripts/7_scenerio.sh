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
echo -e "${BLUE}  Scenario 7: Redis Failover → Connection Leaks → Node Resource Pressure${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-7-cluster"
    fi

    CLUSTER_NAME="scenario-7-cluster"
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
kubectl create namespace cache-system --dry-run=client -o yaml | kubectl apply -f -

# Deploy Redis master
echo -e "\n${YELLOW}=== Deploying Redis Master ===${NC}"
kubectl apply -f https://raw.githubusercontent.com/agentkube/SRE-bench/${GIT_BRANCH:-main}/manifests/scenario-7/redis-master.yaml

echo "Waiting for Redis master to be ready..."
kubectl wait --for=condition=Ready pod/redis-master -n cache-system --timeout=60s 2>/dev/null || echo "Redis master taking longer..."
echo -e "${GREEN}✓ Redis master deployed${NC}"

# Deploy Redis replica
echo -e "\n${YELLOW}=== Deploying Redis Replica ===${NC}"
kubectl apply -f https://raw.githubusercontent.com/agentkube/SRE-bench/${GIT_BRANCH:-main}/manifests/scenario-7/redis-replica.yaml

echo "Waiting for Redis replica to be ready..."
sleep 10
kubectl wait --for=condition=Ready pod/redis-replica -n cache-system --timeout=60s 2>/dev/null || echo "Redis replica taking longer..."
echo -e "${GREEN}✓ Redis replica deployed${NC}"

# Deploy application
echo -e "\n${YELLOW}=== Deploying Web Application ===${NC}"
kubectl apply -f https://raw.githubusercontent.com/agentkube/SRE-bench/${GIT_BRANCH:-main}/manifests/scenario-7/app-deployment.yaml

echo "Waiting for application deployment..."
kubectl wait --for=condition=Available --timeout=60s deployment/web-app -n cache-system 2>/dev/null || echo "Deployment taking longer..."
echo -e "${GREEN}✓ Application deployed${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
echo -e "${YELLOW}Redis Pods:${NC}"
kubectl get pods -n cache-system -l app=redis

echo -e "\n${YELLOW}Application Pods:${NC}"
kubectl get pods -n cache-system -l app=web-app

echo -e "\n${YELLOW}Redis Master Status:${NC}"
kubectl exec -n cache-system redis-master -- redis-cli INFO replication | grep -E "role|connected_slaves"

echo -e "\n${YELLOW}Application Logs (healthy state):${NC}"
kubectl logs -n cache-system -l app=web-app --tail=10 | head -20

# Simulate zone failure - kill Redis master
echo -e "\n${RED}=== Simulating Zone Failure ===${NC}"
echo "Simulating zone failure by killing Redis master pod..."
kubectl delete pod redis-master -n cache-system

echo -e "${YELLOW}Waiting for Redis master to restart...${NC}"
sleep 10

# Show failover in progress
echo -e "\n${BLUE}=== During Failover ===${NC}"
echo -e "${YELLOW}Redis Pods:${NC}"
kubectl get pods -n cache-system -l app=redis

echo -e "\n${YELLOW}Application experiencing connection issues:${NC}"
kubectl logs -n cache-system -l app=web-app --tail=15 | head -30

# Wait for connection leaks to build up
echo -e "\n${YELLOW}=== Observing Connection Leaks ===${NC}"
echo "Application has buggy connection pool logic..."
echo "Connections to old master are not being released (FD leak)"
sleep 15

# Show degraded state
echo -e "\n${BLUE}=== Degraded State ===${NC}"

echo -e "\n${YELLOW}Application Pod Status:${NC}"
kubectl get pods -n cache-system -l app=web-app

echo -e "\n${YELLOW}Application Logs (showing connection leaks):${NC}"
for pod in $(kubectl get pods -n cache-system -l app=web-app -o name | head -2); do
    echo -e "\n${BLUE}Logs from $pod:${NC}"
    kubectl logs $pod -n cache-system --tail=20
done

echo -e "\n${YELLOW}Pod Resource Usage:${NC}"
kubectl top pods -n cache-system 2>/dev/null || echo "Metrics not available"

echo -e "\n${YELLOW}Node Resource Pressure:${NC}"
kubectl describe nodes | grep -A 5 "Conditions:" | head -20

echo -e "\n${YELLOW}Events:${NC}"
kubectl get events -n cache-system --sort-by='.lastTimestamp' | tail -20

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ Redis master pod killed (zone failure simulation)${NC}"
echo -e "${RED}✗ Application connection pool not reinitialized${NC}"
echo -e "${RED}✗ Old connections to dead master keep retrying${NC}"
echo -e "${RED}✗ File descriptor leak (connections not released)${NC}"
echo -e "${RED}✗ Memory pressure from leaked connections${NC}"
echo -e "${RED}✗ Node resource pressure increasing${NC}"
echo -e "${RED}✗ Potential pod evictions due to resource pressure${NC}"

echo -e "\n${YELLOW}=== Root Cause ===${NC}"
echo "1. Redis master pod killed (simulating zone failure)"
echo "2. Application has buggy connection pool implementation"
echo "3. Connection pool connects to redis-master service"
echo "4. When master dies, connections fail but are not released"
echo "5. Application keeps retrying with leaked connections"
echo "6. File descriptors accumulate (connection leak)"
echo "7. Memory usage increases (leaked connection state)"
echo "8. Node experiences resource pressure (memory + FDs)"
echo "9. Kubelet may evict pods to relieve pressure"
echo "10. Result: Degraded service + potential cascading failures"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ Redis connection errors in application logs"
echo "✓ Increasing connection count not being released"
echo "✓ File descriptor warnings"
echo "✓ Memory usage growing on application pods"
echo "✓ Node resource pressure events"
echo "✓ 'Connection pool exhausted' messages"
echo "✓ Growing number of CLOSE_WAIT connections"
echo "✓ Slow application response times"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this issue:"
echo ""
echo "Option 1: Restart Application Pods (Immediate)"
echo "  1. Restart pods to reset connection pools:"
echo "     kubectl rollout restart deployment/web-app -n cache-system"
echo "  2. Verify connections are healthy:"
echo "     kubectl logs -n cache-system -l app=web-app --tail=20"
echo ""
echo "Option 2: Fix Connection Pool Code"
echo "  1. Update application to properly handle Redis failover"
echo "  2. Implement connection pool reinitialization on errors"
echo "  3. Add connection health checks"
echo "  4. Set connection timeouts and max lifetime"
echo "  5. Deploy fixed version"
echo ""
echo "Option 3: Use Redis Sentinel/Cluster"
echo "  1. Deploy Redis Sentinel for automatic failover"
echo "  2. Update application to use Sentinel-aware client"
echo "  3. Test failover scenarios"
echo ""
echo "Option 4: Monitor and Alert"
echo "  kubectl exec -n cache-system <pod> -- sh -c 'ls -la /proc/self/fd | wc -l'"
echo "  kubectl top pods -n cache-system"
echo "  kubectl describe nodes | grep -i pressure"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Implement proper connection pool management in application"
echo "• Use Redis Sentinel or Redis Cluster for high availability"
echo "• Set connection pool limits (max connections, idle timeout)"
echo "• Implement connection health checks and reconnection logic"
echo "• Monitor file descriptor usage per pod"
echo "• Set resource limits to prevent runaway growth"
echo "• Test failover scenarios in staging regularly"
echo "• Use circuit breakers for external dependencies"
echo "• Add retry logic with exponential backoff"
echo "• Monitor connection pool metrics (active, idle, leaked)"
echo "• Use connection pool libraries with built-in failover support"
echo "• Implement graceful degradation when cache is unavailable"

echo -e "\n${YELLOW}=== Connection Pool Best Practices ===${NC}"
echo "Good practices:"
echo "  ✓ Set max pool size (e.g., 10-50 connections)"
echo "  ✓ Set connection timeout (e.g., 5s)"
echo "  ✓ Set idle timeout (e.g., 60s)"
echo "  ✓ Implement health checks on acquire"
echo "  ✓ Auto-reconnect on connection errors"
echo "  ✓ Use connection pool libraries (go-redis, ioredis, etc.)"
echo "  ✓ Monitor pool statistics"
echo ""
echo "Bad practices:"
echo "  ✗ Unlimited connection pool"
echo "  ✗ No connection timeout"
echo "  ✗ Not closing connections on errors"
echo "  ✗ Hardcoding master host instead of using service"
echo "  ✗ No retry logic"

echo -e "\n${YELLOW}=== Redis HA Options ===${NC}"
echo "1. Redis Sentinel:"
echo "   - Automatic failover"
echo "   - Sentinel nodes monitor master/replicas"
echo "   - Clients automatically discover new master"
echo ""
echo "2. Redis Cluster:"
echo "   - Horizontal scaling"
echo "   - Automatic sharding"
echo "   - Built-in failover"
echo ""
echo "3. Managed Redis:"
echo "   - AWS ElastiCache"
echo "   - GCP Memorystore"
echo "   - Azure Cache for Redis"

echo -e "\n${GREEN}=== Scenario 7 Complete ===${NC}"
echo "This demonstrates: Redis Failover → Connection Leaks → Node Resource Pressure"
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
echo "• Try restarting the application pods to fix connection leaks"
echo "• Practice monitoring file descriptor usage"
echo "• Learn about Redis Sentinel for automatic failover"
echo "• Understand connection pool configuration"
