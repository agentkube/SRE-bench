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
echo -e "${BLUE}  Scenario 10: Throttled API Rate Limits → Prometheus Scrape Failures → HPA Misfires${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-10-cluster"
    fi

    CLUSTER_NAME="scenario-10-cluster"
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

# Create namespaces
echo -e "\n${YELLOW}=== Creating Namespaces ===${NC}"
kubectl apply -f https://raw.githubusercontent.com/agentkube/SRE-bench/${GIT_BRANCH:-main}/manifests/scenario-10/namespace.yaml

# Deploy application
echo -e "\n${YELLOW}=== Deploying API Server Application ===${NC}"
kubectl apply -f https://raw.githubusercontent.com/agentkube/SRE-bench/${GIT_BRANCH:-main}/manifests/scenario-10/deployment.yaml
kubectl apply -f https://raw.githubusercontent.com/agentkube/SRE-bench/${GIT_BRANCH:-main}/manifests/scenario-10/service.yaml

echo "Waiting for application deployment..."
kubectl wait --for=condition=Available --timeout=60s deployment/api-server -n workload 2>/dev/null || echo "Deployment taking longer..."
echo -e "${GREEN}✓ Application deployed${NC}"

# Deploy HPA
echo -e "\n${YELLOW}=== Creating HPA ===${NC}"
kubectl apply -f https://raw.githubusercontent.com/agentkube/SRE-bench/${GIT_BRANCH:-main}/manifests/scenario-10/hpa.yaml
echo -e "${GREEN}✓ HPA created${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
echo -e "${YELLOW}Pods:${NC}"
kubectl get pods -n workload

echo -e "\n${YELLOW}HPA Status:${NC}"
kubectl get hpa -n workload
kubectl describe hpa api-server-hpa -n workload | grep -A 5 "Metrics:"

echo -e "\n${YELLOW}Metrics Server Status:${NC}"
kubectl top pods -n workload 2>/dev/null || echo "Metrics collecting..."

# Simulate API rate limiting scenario
echo -e "\n${CYAN}=== Simulating API Server Rate Limiting ===${NC}"
echo "In a real scenario, this happens when:"
echo "  - Too many Prometheus scrapes"
echo "  - High metric cardinality"
echo "  - Many controllers querying API"
echo "  - Excessive watch/list operations"
echo ""
echo "Simulating by overwhelming API server with requests..."

# Create many pods to simulate high API load
echo -e "\n${YELLOW}=== Creating Load on API Server ===${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: api-load-simulator
  namespace: monitoring
spec:
  containers:
  - name: loader
    image: busybox:latest
    command: ["/bin/sh", "-c"]
    args:
      - |
        echo "API Load Simulator starting..."
        echo "Simulating excessive API requests..."

        while true; do
          echo "[$(date)] Sending burst of API requests..."
          echo "Simulating: Prometheus scraping 1000+ targets every 15s"
          echo "Simulating: Multiple controllers watching resources"
          echo "Result: API server throttling incoming requests"
          sleep 5
        done
EOF

sleep 10

# Simulate metrics server issues
echo -e "\n${RED}=== Simulating Metrics Collection Failures ===${NC}"
echo "Metrics server experiencing issues due to API throttling..."
echo "Prometheus scrape errors:"
echo "  ERROR: context deadline exceeded (Client.Timeout exceeded)"
echo "  ERROR: 429 Too Many Requests from kube-apiserver"
echo "  WARNING: Scrape failed for target workload/api-server"

# Scale down metrics-server temporarily to simulate metrics unavailability
kubectl scale deployment metrics-server -n kube-system --replicas=0

echo -e "\n${YELLOW}Waiting for HPA to detect missing metrics...${NC}"
sleep 15

# Show degraded state
echo -e "\n${BLUE}=== Degraded State (Missing Metrics) ===${NC}"

echo -e "\n${YELLOW}HPA Status (No Metrics):${NC}"
kubectl get hpa -n workload
kubectl describe hpa api-server-hpa -n workload | grep -A 10 "Conditions:"

echo -e "\n${YELLOW}Metrics Server Status:${NC}"
kubectl get pods -n kube-system -l k8s-app=metrics-server
kubectl top pods -n workload 2>&1 || echo "Metrics unavailable!"

echo -e "\n${YELLOW}API Server Events (simulated throttling):${NC}"
cat <<EOF
LAST SEEN   TYPE      REASON                  MESSAGE
2m          Warning   FailedGetResourceMetric unable to get metrics for resource cpu: unable to fetch metrics from resource metrics API
1m          Warning   APIServerThrottling     429 Too Many Requests (QPS limit exceeded)
1m          Normal    ScaleDown               Incorrectly scaled down from 3 to 2 (missing metrics interpreted as low load)
30s         Warning   MissingMetrics          No metrics available for evaluation
EOF

# Show incorrect scale down
echo -e "\n${RED}=== HPA Misfires (Incorrect Scale Down) ===${NC}"
echo "Without metrics, HPA assumes load is low..."
echo "Scaling down deployment (INCORRECT DECISION)"

# Manually scale down to simulate HPA misfire
kubectl scale deployment api-server -n workload --replicas=1

echo -e "\n${YELLOW}Waiting for scale down...${NC}"
sleep 10

echo -e "\n${BLUE}=== Impact of Incorrect Scaling ===${NC}"
echo -e "${YELLOW}Pod Status (Under-provisioned):${NC}"
kubectl get pods -n workload

echo -e "\n${YELLOW}Simulated Performance Impact:${NC}"
echo "With only 1 pod handling production traffic:"
echo "  ✗ Latency spike: 50ms → 500ms (10x increase)"
echo "  ✗ Error rate: 0.1% → 15% (requests dropped)"
echo "  ✗ CPU utilization: 60% → 95% (pod overloaded)"
echo "  ✗ Request queue backing up"

echo -e "\n${YELLOW}Application Logs (showing overload):${NC}"
for pod in $(kubectl get pods -n workload -l app=api-server -o name); do
    echo -e "\n${BLUE}Logs from $pod (OVERLOADED):${NC}"
    echo "[$(date)] WARNING: High request rate detected"
    echo "[$(date)] WARNING: CPU at 95%"
    echo "[$(date)] ERROR: Request timeout (queue full)"
    echo "[$(date)] ERROR: Dropping requests due to overload"
done

# Restore metrics server
echo -e "\n${GREEN}=== Restoring Metrics Server ===${NC}"
kubectl scale deployment metrics-server -n kube-system --replicas=1

echo "Waiting for metrics-server to come back..."
kubectl wait --for=condition=Available --timeout=60s deployment/metrics-server -n kube-system 2>/dev/null || echo "Metrics server taking longer..."

sleep 10

echo -e "\n${BLUE}=== After Metrics Restoration ===${NC}"
echo -e "${YELLOW}Metrics Available Again:${NC}"
kubectl top pods -n workload 2>/dev/null || echo "Still collecting..."

echo -e "\n${YELLOW}HPA Re-evaluating:${NC}"
kubectl get hpa -n workload

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ API server throttled due to excessive requests${NC}"
echo -e "${RED}✗ Prometheus unable to scrape metrics (429 errors)${NC}"
echo -e "${RED}✗ Metrics-server failed to collect pod metrics${NC}"
echo -e "${RED}✗ HPA missing metrics for evaluation${NC}"
echo -e "${RED}✗ HPA incorrectly scaled down (assumed low load)${NC}"
echo -e "${RED}✗ Application under-provisioned (1 pod vs needed 3+)${NC}"
echo -e "${RED}✗ Latency spike and error rate increase${NC}"
echo -e "${RED}✗ Delayed detection due to missing metrics${NC}"

echo -e "\n${YELLOW}=== Root Cause ===${NC}"
echo "1. High load on kube-apiserver (many metric queries)"
echo "2. API server rate limiting kicks in (429 Too Many Requests)"
echo "3. Prometheus scrape failures (can't reach API server)"
echo "4. Metrics-server unable to collect pod metrics"
echo "5. HPA evaluation fails (no CPU metrics available)"
echo "6. HPA misinterprets missing metrics as 'low load'"
echo "7. HPA scales down from 3 → 1 pod (incorrect decision)"
echo "8. Single pod overloaded with production traffic"
echo "9. Latency spikes, errors increase"
echo "10. Result: Performance degradation + delayed detection"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ Prometheus scrape failure errors"
echo "✓ Kube-apiserver 429 throttling logs"
echo "✓ Metrics-server connection errors"
echo "✓ HPA showing 'unknown' for metrics"
echo "✓ Unexpected scale-down events"
echo "✓ 'unable to get metrics' warnings"
echo "✓ Gaps in metric graphs"
echo "✓ Application latency spike without traffic increase"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this issue:"
echo ""
echo "Option 1: Immediate - Manually Scale Up"
echo "  kubectl scale deployment api-server -n workload --replicas=3"
echo ""
echo "Option 2: Fix API Server Rate Limits"
echo "  Edit kube-apiserver configuration:"
echo "  --max-requests-inflight=400 (default: 400)"
echo "  --max-mutating-requests-inflight=200 (default: 200)"
echo ""
echo "Option 3: Optimize Prometheus"
echo "  - Reduce scrape frequency: 30s → 60s"
echo "  - Reduce metric cardinality with relabeling"
echo "  - Implement Prometheus federation/sharding"
echo "  - Use remote write to offload storage"
echo ""
echo "Option 4: HPA Fallback Behavior"
echo "  Configure HPA behavior on missing metrics:"
echo "  spec:"
echo "    behavior:"
echo "      scaleDown:"
echo "        policies:"
echo "        - type: Pods"
echo "          value: 0  # Don't scale down on missing metrics"
echo ""
echo "Option 5: Monitor API Server"
echo "  kubectl top nodes"
echo "  kubectl logs -n kube-system <apiserver-pod>"
echo "  kubectl get --raw /metrics | grep apiserver_request"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Monitor kube-apiserver request rates and throttling"
echo "• Set appropriate API server QPS limits"
echo "• Optimize Prometheus metric collection:"
echo "  - Use metric relabeling to reduce cardinality"
echo "  - Adjust scrape intervals based on needs"
echo "  - Implement Prometheus sharding for large clusters"
echo "• Configure HPA to handle missing metrics gracefully"
echo "• Set up alerts for Prometheus scrape failures"
echo "• Use multiple metrics sources (not just Prometheus)"
echo "• Implement circuit breakers for metric collection"
echo "• Review and optimize controller watch/list patterns"
echo "• Use caching where appropriate"
echo "• Set appropriate HPA evaluation intervals (default: 15s)"

echo -e "\n${YELLOW}=== API Server Rate Limit Best Practices ===${NC}"
echo "Monitoring:"
echo "  apiserver_request_total (counter)"
echo "  apiserver_request_duration_seconds (histogram)"
echo "  apiserver_current_inflight_requests (gauge)"
echo "  apiserver_rejected_requests_total (counter)"
echo ""
echo "Tuning:"
echo "  --max-requests-inflight: Total concurrent requests"
echo "  --max-mutating-requests-inflight: Write requests"
echo "  --request-timeout: Default 60s"
echo ""
echo "Prometheus Optimization:"
echo "  - Drop high-cardinality metrics"
echo "  - Use recording rules for expensive queries"
echo "  - Implement metric retention policies"
echo "  - Use remote storage for long-term data"

echo -e "\n${GREEN}=== Scenario 10 Complete ===${NC}"
echo "This demonstrates: Throttled API Rate Limits → Prometheus Scrape Failures → HPA Misfires"
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
echo "• Practice monitoring kube-apiserver metrics"
echo "• Learn about Prometheus optimization techniques"
echo "• Understand HPA behavior with missing metrics"
echo "• Experiment with API server rate limit configurations"
