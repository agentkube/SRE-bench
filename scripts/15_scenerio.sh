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
echo -e "${BLUE}  Scenario 15: Prometheus High Cardinality → TSDB Corruption${NC}"
echo -e "${BLUE}    → Metrics Drop → Alert Delay → Argo Rollout Overshoot → DB Overload${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-15-cluster"
    fi

    CLUSTER_NAME="scenario-15-cluster"
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
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespaces created${NC}"

# Install Argo Rollouts
echo -e "\n${YELLOW}=== Installing Argo Rollouts ===${NC}"
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
echo "Waiting for Argo Rollouts..."
kubectl wait --for=condition=Available --timeout=120s deployment/argo-rollouts -n argo-rollouts 2>/dev/null || echo "Argo Rollouts taking longer..."
echo -e "${GREEN}✓ Argo Rollouts installed${NC}"

# Install Prometheus with normal cardinality
echo -e "\n${YELLOW}=== Installing Prometheus ===${NC}"
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
          - '--storage.tsdb.path=/prometheus'
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        - name: storage
          mountPath: /prometheus
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "1Gi"
            cpu: "500m"
      volumes:
      - name: config
        configMap:
          name: prometheus-config
      - name: storage
        emptyDir: {}
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
echo -e "${GREEN}✓ Prometheus & Alertmanager installed${NC}"

# Deploy PostgreSQL Database
echo -e "\n${YELLOW}=== Deploying PostgreSQL Database ===${NC}"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "PostgreSQL Database v13"
            echo "Max connections: 100"
            CONN_COUNT=0
            while true; do
              sleep 2
              NEW_CONNS=\$((RANDOM % 5))
              CONN_COUNT=\$((CONN_COUNT + NEW_CONNS))
              if [ \$CONN_COUNT -gt 100 ]; then CONN_COUNT=100; fi
              if [ \$CONN_COUNT -ge 90 ]; then
                echo "[CRITICAL] DB CPU: 100% - Connection pool: \${CONN_COUNT}/100"
              elif [ \$CONN_COUNT -ge 50 ]; then
                echo "[WARNING] DB CPU: \$((CONN_COUNT / 2))% - Connections: \${CONN_COUNT}/100"
              else
                echo "[INFO] DB healthy - Connections: \${CONN_COUNT}/100"
              fi
            done
        ports:
        - containerPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: app
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
EOF

kubectl wait --for=condition=Available --timeout=60s deployment/postgres -n app 2>/dev/null || echo "Database taking longer..."
echo -e "${GREEN}✓ PostgreSQL deployed${NC}"

# Deploy API application (stable version v1 with normal metrics)
echo -e "\n${YELLOW}=== Deploying API Application (Stable v1) ===${NC}"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: api-service
  namespace: app
spec:
  selector:
    app: api-service
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service-stable
  namespace: app
  labels:
    app: api-service
    version: stable
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-service
      version: stable
  template:
    metadata:
      labels:
        app: api-service
        version: stable
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      containers:
      - name: api
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "API Service (Stable) v1.0"
            echo "Metrics: Normal cardinality"
            REQUEST_COUNT=0
            while true; do
              sleep 2
              REQUEST_COUNT=\$((REQUEST_COUNT + 1))
              LATENCY=\$((RANDOM % 50 + 20))
              echo "[API-STABLE] Request #\${REQUEST_COUNT} - Latency: \${LATENCY}ms"
            done
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
EOF

kubectl wait --for=condition=Available --timeout=120s deployment/api-service-stable -n app 2>/dev/null || echo "API taking longer..."
echo -e "${GREEN}✓ API Service (stable) deployed${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
kubectl get pods -n app
kubectl get pods -n monitoring

echo -e "\n${YELLOW}Prometheus Status (Healthy):${NC}"
echo "Time-series count: ~5,000 (normal)"
echo "Storage usage: 45MB"
echo "Scrape success rate: 100%"
echo "WAL status: Healthy"

# TRIGGER: Deploy version with high-cardinality metrics
echo -e "\n${RED}=== TRIGGER: Deploying Version with High-Cardinality Metrics ===${NC}"
echo "New version includes user_id label in metrics..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service-canary
  namespace: app
  labels:
    app: api-service
    version: canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api-service
      version: canary
  template:
    metadata:
      labels:
        app: api-service
        version: canary
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      containers:
      - name: api
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "API Service (Canary) v2.0"
            echo "WARNING: High-cardinality metrics enabled!"
            echo "Exposing user_id label in /metrics"
            
            REQUEST_COUNT=0
            while true; do
              sleep 1
              REQUEST_COUNT=\$((REQUEST_COUNT + 1))
              USER_ID=\$((RANDOM % 10000))
              LATENCY=\$((RANDOM % 100 + 30))
              
              # Simulating high-cardinality metric export
              echo "[API-CANARY] http_requests{user_id=\"\${USER_ID}\"} - Latency: \${LATENCY}ms"
              echo "[METRICS] Exporting metric with user_id=\${USER_ID}"
            done
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
EOF

kubectl wait --for=condition=Available --timeout=60s deployment/api-service-canary -n app 2>/dev/null || echo "Canary taking longer..."
echo -e "${RED}✗ Canary deployed with unbounded user_id label${NC}"
echo -e "${RED}✗ Metrics endpoint includes dynamic user IDs${NC}"

# Step 1: High-Cardinality Metric
echo -e "\n${BLUE}=== Step 1: High-Cardinality Metric Explosion ===${NC}"
echo "Prometheus scraping metrics with unbounded user_id labels..."
sleep 3

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cardinality-explosion
  namespace: monitoring
data:
  status: |
    Prometheus Cardinality Analysis:

    Time-Series Growth:
    - T+0min: 5,000 series (baseline)
    - T+2min: 125,000 series (canary scraped)
    - T+5min: 847,000 series (25x growth)
    - T+8min: 2,347,000 series (469x growth)

    High-Cardinality Metrics:
    - http_requests_total{user_id="<dynamic>"}: 2.1M series
    - http_request_duration{user_id="<dynamic>"}: 245K series

    Root Cause:
    - user_id label with 10,000+ unique values
    - Each user creates new time-series
    - Unbounded label cardinality

    Storage Impact:
    - Disk usage: 45MB → 8.7GB (193x increase)
    - Memory usage: 512MB → 2.1GB (4x increase)
    - WAL write queue: 847 entries/sec
EOF

kubectl get configmap cardinality-explosion -n monitoring -o jsonpath='{.data.status}'

echo -e "\n${YELLOW}Canary Logs (showing user_id exports):${NC}"
kubectl logs -n app -l version=canary --tail=10 | head -15

# Step 2: Prometheus TSDB Corruption
echo -e "\n${BLUE}=== Step 2: Prometheus TSDB Corruption ===${NC}"
echo "WAL write queue overflow, block compaction failing..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: tsdb-corruption
  namespace: monitoring
data:
  status: |
    Prometheus TSDB Status - CRITICAL

    WAL (Write-Ahead Log):
    - Write queue: 2,847 entries (overflow threshold: 1,000)
    - WAL segments: 94 (normal: 3-5)
    - WAL size: 4.2GB (normal: 100MB)
    - Status: OVERFLOW

    Block Compaction:
    - Last successful compaction: 12m ago
    - Pending compactions: 18
    - Compaction failures: 7 (out of memory)
    - Error: "cannot compact: insufficient memory"

    Head Block:
    - Series in head: 2,347,000
    - Chunks in head: 8,942,000
    - Memory usage: 2.1GB (limit: 1GB)
    - Status: CRITICAL

    Errors:
    - "WAL write failed: disk full"
    - "head block compaction failed: OOM"
    - "block checkpoint incomplete"

    Impact: Data loss risk, query performance degraded
EOF

kubectl get configmap tsdb-corruption -n monitoring -o jsonpath='{.data.status}'

echo -e "\n${YELLOW}Prometheus Logs:${NC}"
cat <<EOFLOG
level=error msg="WAL write queue overflow" pending=2847
level=error msg="Block compaction failed" err="out of memory"
level=warn msg="Head block size exceeding limit" size_mb=2100 limit_mb=1024
level=error msg="Checkpoint creation failed" reason="insufficient disk space"
EOFLOG

# Step 3: Metrics Drop
echo -e "\n${BLUE}=== Step 3: Metrics Drop (CPU/Memory Stale) ===${NC}"
echo "Critical metrics becoming stale, HPA reading old data..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: metrics-staleness
  namespace: monitoring
data:
  status: |
    Prometheus Query Status:

    STALE METRICS:
    - container_cpu_usage_seconds_total: 8m 45s stale
    - container_memory_working_set_bytes: 8m 45s stale
    - kube_pod_container_resource_requests: 9m 12s stale

    HPA Impact:
    - api-service HPA: reading 8m old CPU metrics
    - Current actual CPU: 65% (8 min ago: 25%)
    - HPA decision: SCALE DOWN (based on stale 25%)
    - Actual needed: SCALE UP (current 65%)

    Query Results:
    - Latest metric timestamp: 2024-11-05 21:42:15
    - Current time: 2024-11-05 21:51:00
    - Staleness: 8 minutes 45 seconds

    Root Cause: TSDB corruption preventing new data ingestion
EOF

kubectl get configmap metrics-staleness -n monitoring -o jsonpath='{.data.status}'

# Step 4: Alert Delay
echo -e "\n${BLUE}=== Step 4: Alert Delay (Alertmanager Backlog) ===${NC}"
echo "Alert evaluation delayed, firing 10+ minutes late..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: alert-delays
  namespace: monitoring
data:
  status: |
    Alertmanager Status - DELAYED

    Alert Queue:
    - Pending evaluations: 347
    - Backlog size: 10m 30s
    - Processing rate: 3 alerts/min (normal: 50 alerts/min)

    DELAYED ALERTS:

    [CRITICAL] DatabaseHighCPU
    - Condition met: 12m ago
    - Alert fired: Not yet (pending evaluation)
    - Expected fire time: +2m from now
    - Total delay: ~14 minutes

    [HIGH] APIHighLatency
    - Condition met: 11m ago
    - Alert fired: Not yet
    - Total delay: ~13 minutes

    [CRITICAL] HighErrorRate
    - Condition met: 10m ago
    - Alert fired: Not yet
    - Total delay: ~12 minutes

    Root Cause: Prometheus query performance degraded
    - Query duration: 45s (normal: 100ms)
    - Alert rule evaluation slow
    - Alertmanager backlog growing
EOF

kubectl get configmap alert-delays -n monitoring -o jsonpath='{.data.status}'

# Step 5: Argo Rollout Overshoot
echo -e "\n${BLUE}=== Step 5: Argo Rollout Overshoot (Canary → 100%) ===${NC}"
echo "Rollout controller reading stale metrics, increasing canary weight..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rollout-overshoot
  namespace: app
data:
  status: |
    Argo Rollout Status - OVERSHOOT DETECTED

    Rollout: api-service
    Strategy: Canary

    Weight Progression (based on stale metrics):
    - T+0m: 10% canary (3 stable, 1 canary)
    - T+5m: 25% canary (metrics show healthy - but STALE)
    - T+10m: 50% canary (metrics still "healthy" - 8m old)
    - T+15m: 100% canary (FULL ROLLOUT - metrics 12m old)

    Analysis Results (INCORRECT - using stale data):
    - Success rate: 99.9% (8 minutes old)
    - Error rate: 0.1% (8 minutes old)
    - Latency p99: 145ms (8 minutes old)
    - Decision: PROMOTE to 100%

    ACTUAL Current Metrics (if fresh data available):
    - Success rate: 87.3% (DEGRADED!)
    - Error rate: 12.7% (HIGH!)
    - Latency p99: 847ms (HIGH!)
    - Database queries with schema bug

    Result: Buggy canary promoted to 100% traffic
EOF

kubectl get configmap rollout-overshoot -n app -o jsonpath='{.data.status}'

echo -e "\n${YELLOW}Rollout Events:${NC}"
cat <<EOFEVENTS
[T+0m] Canary deployment started (weight: 10%)
[T+5m] Analysis: SUCCESS (based on stale metrics) - Increasing to 25%
[T+10m] Analysis: SUCCESS (based on stale metrics) - Increasing to 50%
[T+15m] Analysis: SUCCESS (based on stale metrics) - Promoting to 100%
[T+15m] Traffic shift: 100% canary, 0% stable
EOFEVENTS

# Step 6: DB Overload
echo -e "\n${BLUE}=== Step 6: Database Overload ===${NC}"
echo "Canary v2 has schema bug, hitting DB with inefficient queries..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: db-overload
  namespace: app
data:
  status: |
    PostgreSQL Database - CRITICAL OVERLOAD

    Connection Pool:
    - Active connections: 98/100
    - Idle connections: 0
    - Waiting connections: 47

    CPU & Performance:
    - CPU usage: 100% (was 15%)
    - Query latency avg: 8,470ms (was 12ms)
    - Slow queries: 847 (threshold: 10)

    Problem Queries (from Canary v2):
    - SELECT * FROM users WHERE id IN (SELECT ...)
      Execution time: 12,400ms
      N+1 query problem
      Missing index on user_preferences table

    - UPDATE user_stats SET ... (no WHERE clause)
      Full table scan
      Locking 2.4M rows

    Impact:
    - API timeout rate: 73%
    - Database connection refused errors
    - Transaction rollbacks: High
    - User-facing errors: 100% failure rate

    Root Cause: Schema bug in canary v2 (inefficient queries)
EOF

kubectl get configmap db-overload -n app -o jsonpath='{.data.status}'

echo -e "\n${YELLOW}Database Logs:${NC}"
kubectl logs -n app -l app=postgres --tail=10 | head -15

# Show final degraded state
echo -e "\n${BLUE}=== Final Degraded State ===${NC}"

echo -e "\n${YELLOW}Cluster Overview:${NC}"
kubectl get pods -n app
kubectl get pods -n monitoring

echo -e "\n${YELLOW}Prometheus TSDB:${NC}"
echo "Time-series: 2.3M (was 5K)"
echo "Storage: 8.7GB (was 45MB)"
echo "WAL status: OVERFLOW"
echo "Compaction: FAILING"

echo -e "\n${YELLOW}Application Status:${NC}"
echo "Canary traffic: 100% (incorrect promotion)"
echo "Error rate: 73% (database timeouts)"
echo "Database CPU: 100%"

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ High-cardinality metrics with user_id label${NC}"
echo -e "${RED}✗ Prometheus time-series exploded: 5K → 2.3M${NC}"
echo -e "${RED}✗ TSDB WAL overflow, block compaction failed${NC}"
echo -e "${RED}✗ Critical metrics stale for 8+ minutes${NC}"
echo -e "${RED}✗ HPA reading outdated metrics (incorrect scale decisions)${NC}"
echo -e "${RED}✗ Alerts delayed 10-14 minutes (backlog)${NC}"
echo -e "${RED}✗ Argo Rollout promoted canary to 100% (stale metrics)${NC}"
echo -e "${RED}✗ Canary has schema bug → DB queries inefficient${NC}"
echo -e "${RED}✗ Database CPU: 100%, connections: 98/100${NC}"
echo -e "${RED}✗ API error rate: 73% (user-facing outage)${NC}"
echo -e "${RED}✗ Monitoring silent during failure (TSDB corrupted)${NC}"

echo -e "\n${YELLOW}=== Propagation Chain (6 Levels) ===${NC}"
echo "1️⃣  High-Cardinality Metric: user_id label → millions of time-series"
echo "2️⃣  TSDB Corruption: WAL overflow, compaction fails"
echo "3️⃣  Metrics Drop: CPU/memory metrics stale 8+ min"
echo "4️⃣  Alert Delay: Alertmanager backlog → firing delayed 10+ min"
echo "5️⃣  Rollout Overshoot: Reads stale metrics → promotes canary to 100%"
echo "6️⃣  DB Overload: Canary schema bug → DB CPU 100%"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ Prometheus TSDB corruption errors"
echo "✓ WAL write failures in Prometheus logs"
echo "✓ Metrics cardinality explosion (5K → 2.3M series)"
echo "✓ Prometheus storage usage spike (45MB → 8.7GB)"
echo "✓ Stale metrics in queries"
echo "✓ HPA showing outdated metric values"
echo "✓ Argo Rollout events showing unexpected weight changes"
echo "✓ Database CPU saturation (100%)"
echo "✓ Alert delivery delays in Alertmanager"
echo "✓ API error rate spike"
echo "✓ Database slow query logs"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this cascading failure:"
echo ""
echo "1. Immediately rollback Argo Rollout:"
echo "   kubectl argo rollouts abort api-service -n app"
echo "   kubectl argo rollouts promote api-service -n app --full"
echo ""
echo "2. Identify high-cardinality metrics:"
echo "   kubectl exec -it prometheus-pod -n monitoring -- promtool tsdb analyze /prometheus"
echo ""
echo "3. Restart Prometheus to clear WAL corruption:"
echo "   kubectl rollout restart deployment/prometheus -n monitoring"
echo ""
echo "4. Implement metric relabeling to drop user_id label:"
cat <<'EOFYAML'
   # Add to prometheus.yml
   metric_relabel_configs:
     - source_labels: [user_id]
       action: labeldrop
EOFYAML
echo ""
echo "5. Scale database to handle load temporarily:"
echo "   kubectl scale deployment postgres -n app --replicas=3"
echo ""
echo "6. Fix application code (remove user_id from metrics):"
echo "   # Update instrumentation to use aggregated metrics"
echo "   # Deploy fixed version via proper rollout"
echo ""
echo "7. Clear Alertmanager backlog:"
echo "   kubectl delete pod -n monitoring -l app=alertmanager"
echo ""
echo "8. Monitor recovery:"
echo "   kubectl logs -n monitoring -l app=prometheus -f"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Monitor Prometheus cardinality and series count"
echo "• Implement metric relabeling rules to limit cardinality"
echo "• Set cardinality limits in instrumentation libraries"
echo "• Use metric label allowlists (only allow specific labels)"
echo "• Regular Prometheus performance reviews"
echo "• Implement TSDB storage monitoring and alerts"
echo "• Use metric naming conventions avoiding dynamic labels"
echo "• Configure Prometheus retention policies appropriately"
echo "• Implement progressive delivery safeguards (small canary weights)"
echo "• Add Argo Rollout analysis templates with strict thresholds"
echo "• Use database connection pooling and query timeouts"
echo "• Test new instrumentation in staging first"
echo "• Review metrics cardinality before production deployment"
echo "• Set up Prometheus TSDB health alerts"
echo "• Use metric aggregation for high-cardinality data"
echo "• Implement query performance monitoring on database"

echo -e "\n${GREEN}=== Scenario 15 Complete ===${NC}"
echo "This demonstrates: Prometheus High Cardinality → TSDB Corruption"
echo "                  → Metrics Drop → Alert Delay → Argo Rollout Overshoot → DB Overload"
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
echo "• Unbounded metric labels cause cardinality explosion"
echo "• TSDB corruption creates cascading monitoring failures"
echo "• Stale metrics lead to incorrect automated decisions"
echo "• Progressive delivery fails when metrics are unreliable"
echo "• Monitoring system failure hides critical application bugs"
echo "• Metric cardinality must be controlled at instrumentation level"
