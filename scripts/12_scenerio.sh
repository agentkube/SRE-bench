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
echo -e "${BLUE}  Scenario 12: Misconfigured HPA ’ Cost Spike ’ Cluster Autoscaler${NC}"
echo -e "${BLUE}         ’ Throttled API ’ ArgoCD Sync Failure ’ Alertmanager Storm${NC}"
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
        echo -e "${GREEN} kind is installed${NC}"

        # Create cluster using setup script
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        bash "${SCRIPT_DIR}/setup.sh" "scenario-12-cluster"
    fi

    CLUSTER_NAME="scenario-12-cluster"
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
echo -e "${GREEN} Cluster access verified${NC}"
kubectl get nodes

# Install metrics-server (required for HPA)
echo -e "\n${YELLOW}=== Installing Metrics Server ===${NC}"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch metrics-server for kind (disable TLS verification)
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' 2>/dev/null || echo "Metrics server patch applied"

echo "Waiting for metrics-server to be ready..."
kubectl wait --for=condition=Available --timeout=120s deployment/metrics-server -n kube-system 2>/dev/null || echo "Metrics server taking longer..."
sleep 10
echo -e "${GREEN} Metrics server installed${NC}"

# Install ArgoCD
echo -e "\n${YELLOW}=== Installing ArgoCD ===${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "Installing ArgoCD components..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-server -n argocd 2>/dev/null || echo "ArgoCD server taking longer..."
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-repo-server -n argocd 2>/dev/null || echo "Repo server taking longer..."
echo -e "${GREEN} ArgoCD installed${NC}"

# Install Prometheus and Alertmanager
echo -e "\n${YELLOW}=== Installing Prometheus & Alertmanager ===${NC}"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: 'kubernetes-pods'
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
            action: keep
            regex: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        args:
          - '--config.file=/etc/prometheus/prometheus.yml'
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
      volumes:
      - name: config
        configMap:
          name: prometheus-config
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: monitoring
spec:
  selector:
    app: prometheus
  ports:
  - port: 9090
    targetPort: 9090
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alertmanager
  template:
    metadata:
      labels:
        app: alertmanager
    spec:
      containers:
      - name: alertmanager
        image: prom/alertmanager:latest
        ports:
        - containerPort: 9093
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
---
apiVersion: v1
kind: Service
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  selector:
    app: alertmanager
  ports:
  - port: 9093
    targetPort: 9093
EOF

echo "Waiting for monitoring stack to be ready..."
kubectl wait --for=condition=Available --timeout=120s deployment/prometheus -n monitoring 2>/dev/null || echo "Prometheus taking longer..."
kubectl wait --for=condition=Available --timeout=120s deployment/alertmanager -n monitoring 2>/dev/null || echo "Alertmanager taking longer..."
echo -e "${GREEN} Monitoring stack installed${NC}"

# Create application namespace
echo -e "\n${YELLOW}=== Creating Application Namespace ===${NC}"
kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -

# Deploy initial application with CORRECT HPA (70% CPU target)
echo -e "\n${YELLOW}=== Deploying Application with Correct HPA ===${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: app
  labels:
    app: web-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
      annotations:
        prometheus.io/scrape: "true"
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Web application starting..."
            echo "Simulating normal workload (3-8% CPU)"
            while true; do
              # Simulate light CPU usage
              for i in \$(seq 1 100); do
                echo "Processing request \$i" > /dev/null
              done
              sleep 5
            done
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: web-app
  namespace: app
spec:
  selector:
    app: web-app
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-app-hpa
  namespace: app
  annotations:
    version: "v1-correct"
    target: "70%"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-app
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
EOF

echo "Waiting for application to be ready..."
kubectl wait --for=condition=Available --timeout=120s deployment/web-app -n app 2>/dev/null || echo "Application taking longer..."
sleep 15

echo -e "${GREEN} Application deployed with correct HPA (target: 70% CPU)${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
kubectl get pods -n app
kubectl get hpa -n app
kubectl get nodes

echo -e "\n${YELLOW}Current resource usage:${NC}"
kubectl top nodes 2>/dev/null || echo "Metrics still warming up..."
kubectl top pods -n app 2>/dev/null || echo "Pod metrics still warming up..."

# Create mock cost monitoring agent
echo -e "\n${YELLOW}=== Creating Cost Monitoring Agent ===${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cost-monitor
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cost-monitor
  template:
    metadata:
      labels:
        app: cost-monitor
    spec:
      containers:
      - name: monitor
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Cost Monitoring Agent v1.0"
            echo "Polling cloud provider API every 30s..."
            API_CALLS=0
            while true; do
              API_CALLS=\$((API_CALLS + 1))
              echo "[COST] API Call #\${API_CALLS} - Fetching billing data..."
              sleep 30
            done
        resources:
          requests:
            memory: "32Mi"
            cpu: "25m"
EOF

kubectl wait --for=condition=Available --timeout=60s deployment/cost-monitor -n monitoring 2>/dev/null || echo "Cost monitor taking longer..."
echo -e "${GREEN} Cost monitoring agent deployed${NC}"

# TRIGGER: Misconfigure HPA to 5% CPU target
echo -e "\n${RED}=== TRIGGER: Misconfiguring HPA (70% ’ 5% CPU target) ===${NC}"
echo "Simulating: Platform engineer accidentally sets HPA target to 5%"
sleep 2

cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-app-hpa
  namespace: app
  annotations:
    version: "v2-misconfigured"
    target: "5%"
    modified-by: "manual-mistake"
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-app
  minReplicas: 3
  maxReplicas: 500
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 5
EOF

echo -e "${RED} HPA misconfigured: target changed to 5% CPU (was 70%)${NC}"
echo -e "${RED} maxReplicas increased to 500 (was 10)${NC}"

# Step 1: HPA Misfires - Aggressive Scaling
echo -e "\n${BLUE}=== Step 1: HPA Misfires (Aggressive Scaling) ===${NC}"
echo "HPA detects CPU usage above 5% threshold..."
echo "Triggering aggressive scale-up: 3 ’ 500 pods"
sleep 3

# Simulate the scaling by showing HPA status
kubectl get hpa -n app

echo -e "\n${YELLOW}HPA scaling events:${NC}"
kubectl get events -n app --sort-by='.lastTimestamp' | grep -i "horizontal" | tail -10 || echo "Scaling in progress..."

# Simulate rapid pod creation (in reality this would be gradual)
echo -e "\n${YELLOW}Simulating rapid pod scale-up (would reach 500 in ~10 minutes)${NC}"
for i in {1..3}; do
    CURRENT_PODS=$((3 + i * 30))
    echo "Wave $i: Replica count ’ ${CURRENT_PODS} pods (target: 500)"
    sleep 2
done

# Step 2: Cluster Autoscaler Expansion
echo -e "\n${BLUE}=== Step 2: Cluster Autoscaler Expansion ===${NC}"
echo "Cluster Autoscaler detects pod scheduling pressure..."
echo "Attempting to add 100+ nodes to accommodate 500 pods"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: autoscaler-status
  namespace: kube-system
data:
  status: |
    Cluster Autoscaler Status:

    Current node count: 1
    Target node count: 127
    Pending pods: 497

    Node provisioning:
    - us-east-1a: 42 nodes (provisioning)
    - us-east-1b: 43 nodes (provisioning)
    - us-east-1c: 42 nodes (provisioning)

    Cloud provider: AWS
    Instance type: t3.medium
    Status: SCALING UP RAPIDLY
EOF

kubectl get configmap autoscaler-status -n kube-system -o yaml | grep -A 15 "status:"

# Step 3: Cloud Billing Surge
echo -e "\n${BLUE}=== Step 3: Cloud Billing Surge ===${NC}"
echo "Cost monitoring agent detecting anomaly..."
sleep 2

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cost-alert
  namespace: monitoring
data:
  billing: |
       COST ALERT - CRITICAL

    Cloud Provider: AWS
    Region: us-east-1

    Hourly Cost Increase:
    - Previous: \$12/hour
    - Current: \$1,847/hour
    - Projected 24h: \$44,328
    - Monthly projection: \$1,329,840

    Resources:
    - EC2 instances: 127 (was 1)
    - Instance type: t3.medium
    - Per-instance cost: \$0.0416/hour

    Cost monitoring agent hitting AWS API rate limits!
    - API calls: 12,847 in last 10 minutes
    - Throttled: 8,234 requests (429 errors)
    - Quota: 10,000 calls/hour (EXCEEDED)
EOF

kubectl get configmap cost-alert -n monitoring -o yaml | grep -A 20 "billing:"

echo -e "\n${YELLOW}Cost Monitor Logs:${NC}"
kubectl logs -n monitoring -l app=cost-monitor --tail=15 2>/dev/null || echo "Cost monitor under heavy load"

# Step 4: K8s API Throttled
echo -e "\n${BLUE}=== Step 4: Kubernetes API Throttled (QPS Limits Hit) ===${NC}"
echo "kube-apiserver experiencing high load..."
echo "QPS throttling affecting controllers..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: apiserver-status
  namespace: kube-system
data:
  metrics: |
    kube-apiserver metrics:

    Request rate: 15,847 req/s (normal: 200 req/s)
    Throttled requests: 3,129/min
    Average latency: 2.4s (normal: 50ms)

    Top clients (by request count):
    1. controller-manager: 4,500 req/s (THROTTLED)
    2. cluster-autoscaler: 3,200 req/s (THROTTLED)
    3. argocd-application-controller: 1,800 req/s (THROTTLED)
    4. cost-monitor: 890 req/s (THROTTLED)
    5. metrics-server: 445 req/s

    HTTP Status Codes:
    - 429 Too Many Requests: 54%
    - 200 OK: 38%
    - 500 Internal Server Error: 8%
EOF

kubectl get configmap apiserver-status -n kube-system -o yaml | grep -A 20 "metrics:"

# Step 5: ArgoCD Sync Failure
echo -e "\n${BLUE}=== Step 5: ArgoCD Sync Failure ===${NC}"
echo "ArgoCD unable to sync applications due to API throttling..."
sleep 2

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-sync-status
  namespace: argocd
data:
  status: |
    ArgoCD Sync Status - DEGRADED

    Application: web-app
    Desired State: Git (3 replicas, HPA target 70%)
    Actual State: UNKNOWN (API timeout)
    Sync Status: OutOfSync

    Errors:
    - Failed to query resource status: context deadline exceeded
    - API server returned 429 Too Many Requests
    - Unable to determine drift from Git
    - Partial rollout detected but cannot reconcile

    Last successful sync: 12 minutes ago
    Sync attempts: 47 (all failed)
    Next retry: 60s

    Health Status: UNKNOWN (cannot fetch pod status)
EOF

kubectl get configmap argocd-sync-status -n argocd -o yaml | grep -A 20 "status:"

echo -e "\n${YELLOW}ArgoCD Application Status:${NC}"
echo "Application: web-app"
echo "Status: OutOfSync (Unknown)"
echo "Reason: API throttling preventing state queries"

# Step 6: Alertmanager Storm
echo -e "\n${BLUE}=== Step 6: Alertmanager Storm ===${NC}"
echo "Multiple alert rules firing simultaneously..."
sleep 2

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: alert-storm
  namespace: monitoring
data:
  alerts: |
    =¨ ALERTMANAGER - CRITICAL ALERT STORM =¨

    Total Active Alerts: 247
    Firing in last 5 min: 198
    Alert queue: OVERLOADED

    TOP FIRING ALERTS:

    [CRITICAL] CostAnomalyDetected (42 instances)
    - Monthly cost projection: \$1.3M (was \$8K)
    - Severity: P0

    [CRITICAL] HPAScalingAggressive (37 instances)
    - web-app: 3 ’ 500 replicas in 10 minutes
    - Severity: P0

    [CRITICAL] ClusterNodeExplosion (28 instances)
    - Node count: 127 (was 1)
    - Cloud quota approaching limit
    - Severity: P0

    [HIGH] APIServerThrottling (23 instances)
    - 429 error rate: 54%
    - Request latency: 2.4s
    - Severity: P1

    [HIGH] ArgoSyncFailure (19 instances)
    - All applications OutOfSync
    - Cannot determine cluster state
    - Severity: P1

    [HIGH] PrometheusScrapeFailing (15 instances)
    - Target down: 89/340
    - Metrics incomplete
    - Severity: P1

    [MEDIUM] PodPending (83 instances)
    - 497 pods waiting for nodes
    - Severity: P2

    ALERT FATIGUE WARNING:
    Engineers have silenced 142 alerts in last 10 minutes
    Root cause analysis: IN PROGRESS
    Incident commander: NOT ASSIGNED
EOF

kubectl get configmap alert-storm -n monitoring -o yaml | grep -A 45 "alerts:"

# Show final degraded state
echo -e "\n${BLUE}=== Final Degraded State ===${NC}"

echo -e "\n${YELLOW}Cluster Overview:${NC}"
kubectl get nodes
kubectl get hpa -n app
kubectl get pods -n app | head -20

echo -e "\n${YELLOW}Namespace Pod Counts:${NC}"
echo "app namespace: $(kubectl get pods -n app --no-headers 2>/dev/null | wc -l) pods"
echo "monitoring namespace: $(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l) pods"
echo "argocd namespace: $(kubectl get pods -n argocd --no-headers 2>/dev/null | wc -l) pods"

echo -e "\n${YELLOW}Cost Impact:${NC}"
kubectl get configmap cost-alert -n monitoring -o jsonpath='{.data.billing}' | grep -A 3 "Projected"

echo -e "\n${YELLOW}API Server Health:${NC}"
kubectl get configmap apiserver-status -n kube-system -o jsonpath='{.data.metrics}' | grep -A 2 "Request rate"

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED} HPA misconfigured: target changed to 5% CPU (was 70%)${NC}"
echo -e "${RED} Pods scaled from 3 ’ 500 in 10 minutes${NC}"
echo -e "${RED} Cluster Autoscaler added 100+ nodes (1 ’ 127)${NC}"
echo -e "${RED} Cloud billing spike: \$12/hour ’ \$1,847/hour${NC}"
echo -e "${RED} Projected monthly cost: \$1.3M (was \$8K)${NC}"
echo -e "${RED} Cost monitoring agent hit AWS API rate limit${NC}"
echo -e "${RED} kube-apiserver throttled (54% of requests = 429 errors)${NC}"
echo -e "${RED} ArgoCD sync failures (cannot determine cluster state)${NC}"
echo -e "${RED} Alertmanager storm: 247 active alerts${NC}"
echo -e "${RED} Alert fatigue: 142 alerts silenced by engineers${NC}"
echo -e "${RED} Production instability from partial deployments${NC}"

echo -e "\n${YELLOW}=== Propagation Chain (6 Levels) ===${NC}"
echo "1ã  HPA Misfires: Pods scale 3 ’ 500 in 10 min (5% CPU threshold)"
echo "2ã  Cluster Autoscaler: Adds 100+ nodes in AWS/GCP"
echo "3ã  Cloud Billing Surge: Cost agent hits API rate limit"
echo "4ã  K8s API Throttled: Controller-manager and ArgoCD fail (QPS throttling)"
echo "5ã  ArgoCD Drift: Sync status 'Unknown' ’ partial rollouts"
echo "6ã  Alertmanager Storm: Every HPA, cost, and Argo alert fires"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo " Abnormal replica count increase (3 ’ 500+ pods)"
echo " Node count explosion (1 ’ 127 nodes)"
echo " Cloud API throttling errors (429 responses)"
echo " Massive cost anomaly (\$8K/month ’ \$1.3M/month projected)"
echo " kube-apiserver high latency (2.4s) and QPS throttling"
echo " ArgoCD sync failures and 'Unknown' status"
echo " Alert storm in Alertmanager (247+ firing alerts)"
echo " HPA events showing aggressive scaling"
echo " Pod scheduling pressure (497 pending pods)"
echo " Engineers silencing alerts (142 silences in 10 min)"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this cascading failure:"
echo ""
echo "1. IMMEDIATE: Correct HPA target threshold:"
echo "   kubectl patch hpa web-app-hpa -n app --type merge \\"
echo "     -p '{\"spec\":{\"metrics\":[{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":70}}}],\"maxReplicas\":10}}'"
echo ""
echo "2. Manually scale down excess replicas:"
echo "   kubectl scale deployment web-app -n app --replicas=3"
echo ""
echo "3. Gradually drain and remove unnecessary nodes:"
echo "   # Identify new nodes"
echo "   kubectl get nodes --sort-by=.metadata.creationTimestamp"
echo "   # Drain nodes (do this gradually!)"
echo "   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data"
echo "   # Delete nodes in cloud provider console or via CLI"
echo ""
echo "4. Temporarily increase kube-apiserver QPS limits:"
echo "   # Edit kube-apiserver manifest"
echo "   # Add: --max-requests-inflight=800"
echo "   # Add: --max-mutating-requests-inflight=400"
echo ""
echo "5. Pause ArgoCD auto-sync until stability restored:"
echo "   kubectl patch application web-app -n argocd --type merge \\"
echo "     -p '{\"spec\":{\"syncPolicy\":{\"automated\":null}}}'"
echo ""
echo "6. Clear Alertmanager alert queue:"
echo "   # Access Alertmanager UI or API"
echo "   # Review and acknowledge alerts in batches"
echo "   curl -X DELETE http://alertmanager:9093/api/v1/alerts"
echo ""
echo "7. Disable cost monitoring agent temporarily:"
echo "   kubectl scale deployment cost-monitor -n monitoring --replicas=0"
echo ""
echo "8. Monitor recovery:"
echo "   watch kubectl get hpa -n app"
echo "   watch kubectl get nodes"
echo "   kubectl top nodes"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "" Set realistic HPA metrics (typically 70-80% CPU utilization)"
echo "" Configure maxReplicas limits on all HPAs (use reasonable caps)"
echo "" Implement HPA configuration validation in CI/CD pipeline"
echo "" Use cluster autoscaler limits (min/max nodes per node group)"
echo "" Set up cost guardrails and budget alerts (with email/SMS)"
echo "" Monitor kube-apiserver request rates and QPS metrics"
echo "" Implement rate limiting on cost monitoring tools"
echo "" Regular review of autoscaling configurations (monthly audits)"
echo "" Test autoscaling behavior in staging environments"
echo "" Use policy engines (OPA/Kyverno) to validate HPA configurations"
echo "" Implement cloud resource quotas and limits"
echo "" Set up automated rollback for HPA misconfigurations"
echo "" Use GitOps for all HPA changes (no manual kubectl apply)"
echo "" Configure Alertmanager deduplication and grouping"
echo "" Implement progressive rollout of infrastructure changes"
echo "" Set up cost anomaly detection with auto-response"

echo -e "\n${GREEN}=== Scenario 12 Complete ===${NC}"
echo "This demonstrates: Misconfigured HPA ’ Cost Spike ’ Cluster Autoscaler"
echo "                  ’ Throttled API ’ ArgoCD Sync Failure ’ Alertmanager Storm"
echo ""
echo -e "${YELLOW}Cluster Information:${NC}"
if [ "$SKIP_SETUP" = false ]; then
    echo "Cluster name: kind-${CLUSTER_NAME}"
    echo "To delete: kind delete cluster --name ${CLUSTER_NAME}"
else
    echo "Using existing cluster: ${CLUSTER_NAME:-default}"
fi
echo ""
echo -e "${YELLOW}Key Learnings:${NC}"
echo "" Small HPA misconfigurations can cause massive cost explosions"
echo "" Cluster Autoscaler amplifies HPA mistakes"
echo "" API throttling creates cascading failures across controllers"
echo "" Alert storms cause engineer fatigue and missed root causes"
echo "" Cost monitoring can contribute to the problem via rate limits"
echo "" 6-level dependency chains can unfold in minutes"
