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
echo -e "${BLUE}  Scenario 16: Kube-API Slowdown → Prometheus Scrape Failures${NC}"
echo -e "${BLUE}    → Alert Silencing → Cost Anomaly → Cluster Node Eviction → App Downtime${NC}"
echo -e "${BLUE}========================================${NC}"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Setup phase - only if not skipped
if [ "$SKIP_SETUP" = false ]; then
    echo -e "\n${YELLOW}=== Running Setup ===${NC}"

    if ! command_exists kind; then
        echo -e "${YELLOW}kind not found. Running setup script...${NC}"
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        bash "${SCRIPT_DIR}/setup.sh"
    else
        echo -e "${GREEN}✓ kind is installed${NC}"
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        bash "${SCRIPT_DIR}/setup.sh" "scenario-16-cluster"
    fi

    CLUSTER_NAME="scenario-16-cluster"
    kubectl config use-context "kind-${CLUSTER_NAME}"
else
    echo -e "\n${YELLOW}=== Using Existing Cluster ===${NC}"

    if [ -n "$KUBECONFIG_PATH" ]; then
        export KUBECONFIG="$KUBECONFIG_PATH"
        echo -e "${GREEN}Using kubeconfig: $KUBECONFIG_PATH${NC}"
    fi

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

# Create namespaces
echo -e "\n${YELLOW}=== Creating Namespaces ===${NC}"
kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespaces created${NC}"

# Simulate etcd (showing healthy state initially)
echo -e "\n${YELLOW}=== Simulating etcd (Control Plane Storage) ===${NC}"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: etcd-status
  namespace: kube-system
data:
  status: |
    etcd Status: HEALTHY
    
    Performance Metrics:
    - Disk fsync duration: 8ms (normal)
    - Backend commit duration: 12ms (normal)
    - Disk IOPS: 3000 (provisioned)
    - Storage latency: <10ms
    
    Cluster Health: OK
EOF

echo -e "${GREEN}✓ etcd healthy (initial state)${NC}"

# Install kube-state-metrics
echo -e "\n${YELLOW}=== Installing kube-state-metrics ===${NC}"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-state-metrics
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kube-state-metrics
  template:
    metadata:
      labels:
        app: kube-state-metrics
    spec:
      containers:
      - name: kube-state-metrics
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "kube-state-metrics v2.9.2"
            echo "Exposing cluster state metrics on :8080/metrics"
            while true; do
              sleep 5
              echo "[KSM] Exporting pod/node/deployment metrics"
            done
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: kube-state-metrics
  namespace: kube-system
spec:
  selector:
    app: kube-state-metrics
  ports:
  - port: 8080
    targetPort: 8080
EOF

kubectl wait --for=condition=Available --timeout=60s deployment/kube-state-metrics -n kube-system 2>/dev/null || echo "kube-state-metrics taking longer..."
echo -e "${GREEN}✓ kube-state-metrics installed${NC}"

# Install Prometheus & Alertmanager
echo -e "\n${YELLOW}=== Installing Prometheus & Alertmanager ===${NC}"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: monitoring
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      scrape_timeout: 10s
    scrape_configs:
      - job_name: 'kubernetes-apiservers'
        kubernetes_sd_configs:
          - role: endpoints
        scheme: https
        tls_config:
          insecure_skip_verify: true
      - job_name: 'kube-state-metrics'
        static_configs:
          - targets: ['kube-state-metrics.kube-system.svc:8080']
      - job_name: 'kubernetes-pods'
        kubernetes_sd_configs:
          - role: pod
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
            memory: "512Mi"
            cpu: "200m"
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

kubectl wait --for=condition=Available --timeout=120s deployment/prometheus -n monitoring 2>/dev/null || echo "Prometheus taking longer..."
kubectl wait --for=condition=Available --timeout=120s deployment/alertmanager -n monitoring 2>/dev/null || echo "Alertmanager taking longer..."
echo -e "${GREEN}✓ Monitoring stack installed${NC}"

# Deploy cost monitoring agent
echo -e "\n${YELLOW}=== Deploying Cost Monitoring Agent ===${NC}"
kubectl apply -f - <<EOF
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
            echo "Cloud Cost Monitor v1.0"
            echo "Polling cloud provider API every 30s..."
            API_CALLS=0
            while true; do
              sleep 30
              API_CALLS=\$((API_CALLS + 1))
              echo "[COST] API call #\${API_CALLS} - Fetching billing data (200 OK)"
            done
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
EOF

kubectl wait --for=condition=Available --timeout=60s deployment/cost-monitor -n monitoring 2>/dev/null || echo "Cost monitor taking longer..."
echo -e "${GREEN}✓ Cost monitoring agent deployed${NC}"

# Deploy application with HPA
echo -e "\n${YELLOW}=== Deploying Application with HPA ===${NC}"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: app
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
            echo "Web Application v1.0"
            echo "Processing requests..."
            REQUEST_COUNT=0
            while true; do
              sleep 2
              REQUEST_COUNT=\$((REQUEST_COUNT + 1))
              echo "[APP] Request #\${REQUEST_COUNT} - Status: 200 OK"
            done
        ports:
        - containerPort: 8080
        resources:
          requests:
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

kubectl wait --for=condition=Available --timeout=120s deployment/web-app -n app 2>/dev/null || echo "Application taking longer..."
echo -e "${GREEN}✓ Application with HPA deployed${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
kubectl get pods -n app
kubectl get pods -n monitoring
kubectl get pods -n kube-system | grep -E "kube-state|etcd"

echo -e "\n${YELLOW}System Health:${NC}"
echo "✓ etcd: Healthy (fsync: 8ms)"
echo "✓ kube-apiserver: Responsive (<50ms)"
echo "✓ kube-state-metrics: Running"
echo "✓ Prometheus: Scraping successfully"
echo "✓ HPA: Active, metrics available"
echo "✓ Cost monitor: Polling normally"

# TRIGGER: etcd I/O Latency Spike
echo -e "\n${RED}=== TRIGGER: etcd I/O Latency Spike (Cloud Disk Throttling) ===${NC}"
echo "Simulating: Cloud provider throttles disk I/O..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: etcd-status
  namespace: kube-system
data:
  status: |
    etcd Status: DEGRADED
    
    Performance Metrics:
    - Disk fsync duration: 2,847ms (CRITICAL - was 8ms)
    - Backend commit duration: 3,124ms (CRITICAL - was 12ms)
    - Disk IOPS: 100 (THROTTLED - was 3000)
    - Storage latency: >2000ms (CRITICAL)
    
    ROOT CAUSE: Cloud disk throttling
    - Burst credits exhausted
    - I/O queue depth: 847 (max: 32)
    - Disk throughput: 10 MB/s (limit: 250 MB/s)
    
    Impact: All API requests delayed
EOF

echo -e "${RED}✗ etcd fsync duration: 8ms → 2,847ms (355x slower)${NC}"
echo -e "${RED}✗ Cloud disk I/O throttled (burst credits exhausted)${NC}"

# Step 1: Kube-API Slowdown
echo -e "\n${BLUE}=== Step 1: Kube-API Slowdown ===${NC}"
echo "API server call latency increasing..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: apiserver-latency
  namespace: kube-system
data:
  metrics: |
    kube-apiserver Performance - DEGRADED
    
    Request Latency:
    - P50: 2,147ms (normal: 45ms)
    - P95: 4,289ms (normal: 120ms)
    - P99: 6,847ms (normal: 200ms)
    
    Request Volume:
    - Total requests: 847/sec
    - GET requests: 612/sec
    - LIST requests: 235/sec (expensive)
    
    Top Slow Endpoints:
    - GET /api/v1/pods: 3,200ms avg
    - LIST /api/v1/nodes: 4,500ms avg
    - GET /apis/metrics.k8s.io: 2,800ms avg
    
    Timeout Errors:
    - Client timeout: 247 requests/min
    - Context deadline exceeded: 189 requests/min
    
    Root Cause: etcd slow response times
EOF

kubectl get configmap apiserver-latency -n kube-system -o jsonpath='{.data.metrics}'

# Step 2: Prometheus Scrape Failures
echo -e "\n${BLUE}=== Step 2: Prometheus Scrape Failures ===${NC}"
echo "kube-state-metrics timing out, pod/node metrics missing..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-scrape-status
  namespace: monitoring
data:
  status: |
    Prometheus Scrape Status - FAILING
    
    Target: kube-state-metrics
    - Status: DOWN
    - Last successful scrape: 4m 30s ago
    - Recent errors: context deadline exceeded (timeout: 10s)
    - Actual scrape duration: 32s (configured timeout: 10s)
    
    Target: kube-apiserver
    - Status: DOWN
    - Last successful scrape: 5m 12s ago
    - Error: dial tcp: i/o timeout
    
    Missing Metrics:
    - kube_pod_container_resource_requests
    - kube_pod_container_resource_limits
    - kube_node_status_condition
    - kube_deployment_status_replicas
    
    Impact on Dependent Systems:
    - HPA: Cannot fetch pod metrics
    - Dashboards: Stale data
    - Alerts: Cannot evaluate rules
EOF

kubectl get configmap prometheus-scrape-status -n monitoring -o jsonpath='{.data.status}'

echo -e "\n${YELLOW}Prometheus Logs:${NC}"
cat <<EOFLOG
level=error msg="Scrape failed" target="kube-state-metrics" err="context deadline exceeded"
level=error msg="Scrape failed" target="kube-apiserver" err="dial tcp: i/o timeout"
level=warn msg="Target down" job="kube-state-metrics" duration="4m30s"
EOFLOG

# Step 3: Alert Silencing
echo -e "\n${BLUE}=== Step 3: Alert Silencing (Incomplete Data) ===${NC}"
echo "Alertmanager suppressing alerts due to missing metrics..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: alert-silencing
  namespace: monitoring
data:
  status: |
    Alertmanager Status - SILENCING ACTIVE
    
    Silenced Alerts (Insufficient Data):
    
    [HIGH] PodCPUThresholdExceeded
    - Condition: cpu_usage > 80% for 5m
    - Status: SILENCED (no metrics for 4m 30s)
    - Reason: kube-state-metrics unavailable
    
    [CRITICAL] NodeMemoryPressure
    - Condition: memory_pressure == true
    - Status: SILENCED (no metrics for 5m 12s)
    - Reason: kube-state-metrics unavailable
    
    [HIGH] DeploymentReplicasMismatch
    - Condition: desired != available
    - Status: SILENCED (no metrics)
    - Reason: Cannot query deployment status
    
    Automatic Silencing Policy:
    - Rule: Silence alerts when data source unavailable
    - Duration: Until data returns or manual intervention
    - Risk: Real incidents may go undetected
EOF

kubectl get configmap alert-silencing -n monitoring -o jsonpath='{.data.status}'

# Step 4: HPA Failure & Autoscaler Issues
echo -e "\n${BLUE}=== Step 4: HPA Failure (No Metrics) ===${NC}"
echo "HPA cannot fetch metrics, scaling down to minReplicas..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: hpa-failure
  namespace: app
data:
  status: |
    HPA Status - UNABLE TO COMPUTE REPLICA COUNT
    
    HPA: web-app-hpa
    Current replicas: 3
    Desired replicas: UNKNOWN
    
    Error Messages:
    - "unable to get metrics for resource cpu: unable to fetch metrics from resource metrics API"
    - "the HPA was unable to compute the replica count: unable to get metrics"
    - "failed to get cpu utilization: unable to get metrics"
    
    Fallback Behavior:
    - Scaling to minReplicas: 3 (from current: 3)
    - Actual load: HIGH (but cannot measure)
    - Risk: Underprovisioning during peak load
    
    Timeline:
    [T-5m] Last successful metric fetch
    [T-4m] First metric fetch failure
    [T-2m] HPA warning: unable to compute replicas
    [T-0m] HPA maintains minReplicas (incorrect decision)
EOF

kubectl get configmap hpa-failure -n app -o jsonpath='{.data.status}'

kubectl get hpa -n app 2>/dev/null || echo "HPA showing unknown/missing metrics"

# Step 5: Cost Anomaly (Retry Storm)
echo -e "\n${BLUE}=== Step 5: Cost Anomaly Detection (API Quota Exhaustion) ===${NC}"
echo "Cost monitor retrying failed API calls, hitting cloud quota..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cost-anomaly
  namespace: monitoring
data:
  status: |
    Cost Monitor - API QUOTA EXCEEDED
    
    Cloud API Status:
    - Billing API calls: 12,847 in last 10 min
    - Success rate: 12% (was 100%)
    - Failed calls: 11,305 (88%)
    - Error: 429 Too Many Requests
    
    Retry Behavior:
    - Retry attempts: 5x per failed call
    - Backoff: Exponential (max: 60s)
    - Total retries: 56,525
    
    Cloud Provider Quota:
    - Quota: 1,000 calls/hour
    - Usage: 12,847 calls/hour (EXCEEDED)
    - Throttling: Active
    - Reset time: 42 minutes
    
    Root Cause:
    - Cost monitor retrying due to API server timeouts
    - Each timeout triggers 5 retries
    - Retry storm overwhelms cloud API quota
EOF

kubectl get configmap cost-anomaly -n monitoring -o jsonpath='{.data.status}'

echo -e "\n${YELLOW}Cost Monitor Logs:${NC}"
kubectl logs -n monitoring -l app=cost-monitor --tail=15 2>/dev/null | head -15 || cat <<EOFCOST
[COST] API call #247 - ERROR: context deadline exceeded (retrying...)
[COST] Retry 1/5 - ERROR: 429 Too Many Requests
[COST] Retry 2/5 - ERROR: 429 Too Many Requests
[COST] Retry 3/5 - ERROR: 429 Too Many Requests
[COST] WARN: Cloud API quota exceeded
EOFCOST

# Step 6: Node Pressure & Pod Evictions
echo -e "\n${BLUE}=== Step 6: Node Pressure & Pod Evictions ===${NC}"
echo "Resource pressure rising, Kubelet evicting pods..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-pressure
  namespace: kube-system
data:
  status: |
    Node Pressure Status - CRITICAL
    
    Node: kind-scenario-16-cluster-control-plane
    Pressure Type: DiskPressure, MemoryPressure
    
    Disk Pressure:
    - Available disk: 4% (threshold: 10%)
    - etcd WAL size: 8.2GB (growing)
    - Kubelet logs: 2.1GB
    - Container images: 18GB
    
    Memory Pressure:
    - Available memory: 847MB (threshold: 1GB)
    - etcd process: 2.1GB (growing)
    - kube-apiserver: 1.8GB
    - System pods: 3.2GB
    
    Kubelet Actions:
    - Evicting low-priority pods
    - Garbage collecting images
    - Throttling new pod scheduling
    
    Evicted Pods (last 5 min):
    - web-app-pod-1 (app namespace)
    - cost-monitor-pod (monitoring namespace)
    - kube-state-metrics-pod (kube-system)
    
    Impact: Service degradation
EOF

kubectl get configmap node-pressure -n kube-system -o jsonpath='{.data.status}'

kubectl get events -n app --sort-by='.lastTimestamp' | grep -i "evict\|pressure" | tail -10 || echo "Pod eviction events occurring..."

# Step 7: Application Downtime
echo -e "\n${BLUE}=== Step 7: Application Downtime ===${NC}"
echo "Pods evicted mid-transaction, service unavailable..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-downtime
  namespace: app
data:
  status: |
    Application Status - DOWN
    
    Service: web-app
    Desired replicas: 3
    Available replicas: 1 (2 pods evicted)
    
    Pod Status:
    - web-app-pod-1: Evicted (DiskPressure)
    - web-app-pod-2: Running (degraded)
    - web-app-pod-3: Evicted (MemoryPressure)
    
    Service Health:
    - Healthy endpoints: 1/3
    - Error rate: 67%
    - Response time: >10s (timeouts)
    - Status: CRITICAL
    
    User Impact:
    - 502 Bad Gateway errors
    - Request timeouts
    - Service unavailable
    - Data loss (in-flight transactions)
    
    Detection Delay:
    - Actual downtime start: 8m ago
    - First alert: None (silenced)
    - Detection method: User reports
EOF

kubectl get configmap app-downtime -n app -o jsonpath='{.data.status}'

# Show final degraded state
echo -e "\n${BLUE}=== Final Degraded State ===${NC}"

echo -e "\n${YELLOW}Cluster Overview:${NC}"
kubectl get pods -n app 2>/dev/null || echo "Pods in degraded state"
kubectl get pods -n monitoring 2>/dev/null | head -10
kubectl get nodes

echo -e "\n${YELLOW}System Health:${NC}"
echo "✗ etcd: DEGRADED (fsync: 2,847ms)"
echo "✗ kube-apiserver: SLOW (latency: >2s)"
echo "✗ kube-state-metrics: DOWN (timeout)"
echo "✗ Prometheus: FAILING (scrapes timeout)"
echo "✗ Alertmanager: SILENCING (no data)"
echo "✗ HPA: UNABLE TO COMPUTE (no metrics)"
echo "✗ Cost monitor: QUOTA EXCEEDED (429 errors)"
echo "✗ Nodes: PRESSURE (disk & memory)"
echo "✗ Application: DOWN (67% error rate)"

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ etcd I/O latency spike (8ms → 2,847ms)${NC}"
echo -e "${RED}✗ Cloud disk throttling (burst credits exhausted)${NC}"
echo -e "${RED}✗ kube-apiserver slow (P99: 6,847ms)${NC}"
echo -e "${RED}✗ Prometheus scrapes timeout (kube-state-metrics DOWN)${NC}"
echo -e "${RED}✗ Missing pod/node metrics for 4-5 minutes${NC}"
echo -e "${RED}✗ Alertmanager silencing all alerts (no data)${NC}"
echo -e "${RED}✗ HPA unable to compute replicas (scales to minReplicas)${NC}"
echo -e "${RED}✗ Cost monitor retry storm (12,847 API calls → quota exceeded)${NC}"
echo -e "${RED}✗ Node disk/memory pressure (DiskPressure, MemoryPressure)${NC}"
echo -e "${RED}✗ Pod evictions (2/3 app pods evicted mid-transaction)${NC}"
echo -e "${RED}✗ Application downtime (67% error rate)${NC}"
echo -e "${RED}✗ No alerts fired (monitoring unreliable)${NC}"
echo -e "${RED}✗ Misdiagnosed as HPA regression (actual: infrastructure)${NC}"

echo -e "\n${YELLOW}=== Propagation Chain (6 Levels) ===${NC}"
echo "1️⃣  etcd Latency: API responses slow (>2s) due to disk throttling"
echo "2️⃣  Prometheus Scrape Failures: kube-state-metrics timeout → missing metrics"
echo "3️⃣  Alert Silencing: Alertmanager suppresses alerts (data incomplete)"
echo "4️⃣  Autoscaler Fails: HPA sees 'no metrics' → scales to minReplicas"
echo "5️⃣  Cost Anomaly: Cost monitor retry storm → hits cloud API quota"
echo "6️⃣  Node Eviction: Disk/memory pressure → pods evicted → service down"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ etcd high latency warnings (fsync duration >100ms)"
echo "✓ Kube-apiserver slow request logs"
echo "✓ Prometheus scrape timeout errors"
echo "✓ kube-state-metrics unavailability"
echo "✓ HPA showing 'unable to fetch metrics'"
echo "✓ Alertmanager silence events"
echo "✓ Unexpected scale-down events"
echo "✓ Cloud API throttling (429 errors)"
echo "✓ Node pressure events (DiskPressure, MemoryPressure)"
echo "✓ Pod eviction events"
echo "✓ Disk I/O throttling metrics (cloud provider)"
echo "✓ User-reported errors (first indicator)"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this cascading failure:"
echo ""
echo "1. Identify etcd disk I/O bottleneck:"
echo "   kubectl exec -n kube-system etcd-pod -- etcdctl endpoint status"
echo "   # Check disk latency metrics in cloud provider console"
echo ""
echo "2. Increase etcd disk IOPS (emergency):"
echo "   # Cloud provider console: Modify disk performance"
echo "   # AWS: Change to io2 volume with higher IOPS"
echo "   # GCP: Increase pd-ssd IOPS provisioning"
echo ""
echo "3. Reduce kube-apiserver load temporarily:"
echo "   # Increase API server rate limits"
echo "   kubectl edit configmap -n kube-system kube-apiserver"
echo "   # Add: --max-requests-inflight=800"
echo ""
echo "4. Manually scale up underprovisioned workloads:"
echo "   kubectl scale deployment web-app -n app --replicas=5"
echo ""
echo "5. Disable cost monitoring agent temporarily:"
echo "   kubectl scale deployment cost-monitor -n monitoring --replicas=0"
echo ""
echo "6. Add or scale nodes to relieve pressure:"
echo "   # Manually add nodes or adjust autoscaler"
echo ""
echo "7. Verify Prometheus scrape recovery:"
echo "   kubectl logs -n monitoring -l app=prometheus --tail=50"
echo ""
echo "8. Review and restore silenced alerts:"
echo "   # Access Alertmanager UI"
echo "   kubectl port-forward -n monitoring svc/alertmanager 9093:9093"
echo ""
echo "9. Implement etcd performance tuning:"
echo "   # Adjust etcd memory limits, snapshot intervals"
echo "   # Consider etcd defragmentation"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Monitor etcd performance metrics (disk latency, fsync duration)"
echo "• Use high-performance storage for etcd (SSD, provisioned IOPS)"
echo "• Set baseline IOPS to avoid burst credit exhaustion"
echo "• Implement etcd disk I/O alerts (fsync >100ms)"
echo "• Optimize kube-apiserver configuration and rate limits"
echo "• Use Prometheus federation/sharding to reduce API load"
echo "• Configure HPA evaluation intervals and fallback behavior"
echo "• Implement rate limiting on cost monitoring tools"
echo "• Set PodDisruptionBudgets to prevent excessive evictions"
echo "• Use node affinity to isolate critical workloads"
echo "• Regular etcd performance testing and capacity planning"
echo "• Monitor cloud resource quotas and set up alerts"
echo "• Implement graceful degradation for metrics unavailability"
echo "• Use etcd compaction and defragmentation schedules"
echo "• Set up synthetic monitoring (doesn't rely on Prometheus)"
echo "• Configure separate monitoring for infrastructure health"
echo "• Implement etcd backup and recovery procedures"

echo -e "\n${GREEN}=== Scenario 16 Complete ===${NC}"
echo "This demonstrates: Kube-API Slowdown → Prometheus Scrape Failures"
echo "                  → Alert Silencing → Cost Anomaly → Node Eviction → App Downtime"
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
echo "• Infrastructure bottlenecks (etcd) cause cascading control plane failures"
echo "• Monitoring systems fail when dependent on unhealthy infrastructure"
echo "• Alert silencing creates dangerous blind spots during incidents"
echo "• Misdiagnosis is common when root cause is hidden (blamed HPA)"
echo "• Cloud resource quotas can amplify failures through retry storms"
echo "• Multiple systems fail simultaneously from single root cause"
echo "• Detection relies on user reports when monitoring is unreliable"
