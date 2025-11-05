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
echo -e "${BLUE}  Scenario 11: ArgoCD Drift -> Secret Mismatch -> DB Connection Leak${NC}"
echo -e "${BLUE}           -> Node Pressure -> Prometheus Throttle -> Alert Delays${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-11-cluster"
    fi

    CLUSTER_NAME="scenario-11-cluster"
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

# Install ArgoCD
echo -e "\n${YELLOW}=== Installing ArgoCD ===${NC}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "Installing ArgoCD components..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-server -n argocd 2>/dev/null || echo "ArgoCD server taking longer..."
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-repo-server -n argocd 2>/dev/null || echo "Repo server taking longer..."

echo -e "${GREEN} ArgoCD installed${NC}"

# Install Prometheus (simplified for monitoring)
echo -e "\n${YELLOW}=== Installing Prometheus (for monitoring) ===${NC}"
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
          - '--storage.tsdb.path=/prometheus'
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
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
EOF

echo "Waiting for Prometheus to be ready..."
kubectl wait --for=condition=Available --timeout=120s deployment/prometheus -n monitoring 2>/dev/null || echo "Prometheus taking longer..."
echo -e "${GREEN} Prometheus installed${NC}"

# Create application namespace and initial secret
echo -e "\n${YELLOW}=== Creating Application Namespace and Initial Secret ===${NC}"
kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -

# Create initial database secret with correct password (v1)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: app
  annotations:
    version: "v1"
    created-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
type: Opaque
stringData:
  DB_HOST: "postgres.app.svc.cluster.local"
  DB_PORT: "5432"
  DB_USER: "appuser"
  DB_PASSWORD: "correctpassword123"
EOF

echo -e "${GREEN} Initial secret created (v1 - correct password)${NC}"

# Create mock Postgres database
echo -e "\n${YELLOW}=== Creating Mock PostgreSQL Database ===${NC}"
cat <<EOF | kubectl apply -f -
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
            echo "PostgreSQL Server starting..."
            echo "Valid credentials: user=appuser, password=correctpassword123"
            echo "Max connections: 100"

            # Keep running
            while true; do
              sleep 10
              ACTIVE_CONN=\$((RANDOM % 20))
              echo "[DB] Active connections: \${ACTIVE_CONN}/100"
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

echo "Waiting for database to be ready..."
kubectl wait --for=condition=Available --timeout=60s deployment/postgres -n app 2>/dev/null || echo "Database taking longer..."
echo -e "${GREEN} PostgreSQL database ready${NC}"

# Create application deployment (v1 - using correct credentials from Git)
echo -e "\n${YELLOW}=== Creating Application Deployment (v1 from GitOps) ===${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: app
  labels:
    app: web-app
    version: v1
  annotations:
    argocd.argoproj.io/tracking-id: "web-app:apps/Deployment:app/web-app"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-app
  template:
    metadata:
      labels:
        app: web-app
        version: v1
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Application v1 starting..."
            echo "Connecting to database at \${DB_HOST}:\${DB_PORT}"
            echo "Using credentials: \${DB_USER}/\${DB_PASSWORD}"

            # Simulate successful DB connection
            if [ "\${DB_PASSWORD}" = "correctpassword123" ]; then
              echo " Database connection successful"
              echo " Connection pool initialized (size: 10)"

              while true; do
                sleep 5
                POOL_SIZE=\$((RANDOM % 10 + 1))
                echo "[APP] Healthy - DB pool: \${POOL_SIZE}/10 connections"
              done
            else
              echo " Database authentication failed!"
              echo "ERROR: Invalid credentials - password mismatch"
              echo "Retrying connection..."

              # Simulate connection leak - infinite retries
              while true; do
                echo "RETRY: Attempting to connect to database..."
                sleep 2
              done
            fi
        env:
        - name: DB_HOST
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: DB_HOST
        - name: DB_PORT
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: DB_PORT
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: DB_USER
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: DB_PASSWORD
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'Healthy' > /dev/null"
          initialDelaySeconds: 10
          periodSeconds: 5
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
EOF

echo "Waiting for application to be ready..."
kubectl wait --for=condition=Available --timeout=120s deployment/web-app -n app 2>/dev/null || echo "Application taking longer..."
echo -e "${GREEN} Application v1 deployed and healthy${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
kubectl get pods -n app
echo ""
echo -e "${YELLOW}Sample application logs:${NC}"
kubectl logs -n app -l app=web-app --tail=5 | head -15

# TRIGGER: Manual hotfix bypassing ArgoCD (changing secret)
echo -e "\n${YELLOW}=== TRIGGER: Manual Hotfix (Bypassing GitOps) ===${NC}"
echo "Simulating: DevOps engineer manually patches Secret in cluster"
echo "This change bypasses ArgoCD sync and is NOT in Git!"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: app
  annotations:
    version: "v2-manual-hotfix"
    created-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    modified-by: "manual-kubectl-apply"
    drift: "true"
type: Opaque
stringData:
  DB_HOST: "postgres.app.svc.cluster.local"
  DB_PORT: "5432"
  DB_USER: "appuser"
  DB_PASSWORD: "wrongpassword999"
EOF

echo -e "${RED} Secret manually updated with wrong password (wrongpassword999)${NC}"
echo -e "${YELLOW}Note: Existing pods still cached old secret values${NC}"

# Step 1: ArgoCD Drift Detection
echo -e "\n${BLUE}=== Step 1: ArgoCD Drift Detection ===${NC}"
echo "ArgoCD detects that cluster state differs from Git..."
sleep 3
echo -e "${YELLOW}ArgoCD status: OutOfSync${NC}"

# Step 2: Force pod restart to trigger secret mismatch
echo -e "\n${BLUE}=== Step 2: Secret Mismatch (Pod Restart) ===${NC}"
echo "Forcing pod restart to pick up new (wrong) credentials..."
kubectl rollout restart deployment/web-app -n app

echo "Waiting for pods to restart with wrong credentials..."
sleep 15

# Show failing authentication
echo -e "\n${YELLOW}Pod Status (authentication failing):${NC}"
kubectl get pods -n app

echo -e "\n${YELLOW}Application Logs (showing auth failures):${NC}"
for pod in $(kubectl get pods -n app -l app=web-app -o name | head -2); do
    echo -e "\n${BLUE}Logs from $pod:${NC}"
    kubectl logs $pod -n app --tail=10 2>/dev/null || echo "Pod not ready"
done

# Step 3: DB Connection Leak
echo -e "\n${BLUE}=== Step 3: DB Connection Leak ===${NC}"
echo "Application pods retry infinitely, leaking connections..."
echo "Connection pool exhausted, Postgres refusing new connections..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: db-status
  namespace: app
data:
  status: |
    PostgreSQL Connection Status:
    - Max connections: 100
    - Active connections: 98/100
    - Idle connections: 0
    - Failed auth attempts: 1,247
    - Status: CRITICAL - Connection pool near exhaustion
EOF

kubectl get configmap db-status -n app -o yaml | grep -A 10 "status:"

# Step 4: Node Pressure
echo -e "\n${BLUE}=== Step 4: Node Pressure (CPU/Memory from Retry Loop) ===${NC}"
echo "App pods consuming resources on infinite retry loop..."
echo "Kubelet starting to evict low-priority pods..."

# Simulate node pressure by creating high-resource pods
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: resource-hog-1
  namespace: app
  labels:
    priority: low
spec:
  containers:
  - name: hog
    image: busybox:latest
    command: ["/bin/sh", "-c"]
    args:
      - |
        echo "Low priority pod running..."
        while true; do sleep 10; done
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
EOF

echo "Simulating OOMKilled events on low-priority pods..."
sleep 5

kubectl get pods -n app
kubectl get events -n app --sort-by='.lastTimestamp' | tail -15

# Step 5: Prometheus Throttle
echo -e "\n${BLUE}=== Step 5: Prometheus Scrape Failures (Kubelet Throttled) ===${NC}"
echo "Kubelet metrics endpoint throttled due to node pressure..."
echo "Prometheus /metrics returning 500 errors..."

kubectl logs -n monitoring -l app=prometheus --tail=20 2>/dev/null | head -20 || \
echo "Prometheus experiencing scrape failures due to throttled endpoints"

# Step 6: Alertmanager Delay
echo -e "\n${BLUE}=== Step 6: Alert Delays ===${NC}"
echo "Alertmanager missing metric data, alert thresholds not met..."
echo "High latency alerts arrive 15 minutes late..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: alert-status
  namespace: monitoring
data:
  alerts: |
    Alertmanager Status:

    Pending Alerts:
    - DatabaseConnectionFailure: PENDING (data incomplete)
    - HighPodRestartRate: PENDING (15 min delay)
    - NodeMemoryPressure: PENDING (stale metrics)
    - ApplicationDown: PENDING (scrape failure)

    Alert Delivery: DELAYED (15 min behind)
    Metric Freshness: STALE (last update 10 min ago)

    Root Cause: Prometheus scrape failures due to throttled Kubelet
EOF

kubectl get configmap alert-status -n monitoring -o yaml | grep -A 15 "alerts:"

# Show final degraded state
echo -e "\n${BLUE}=== Final Degraded State ===${NC}"
echo -e "\n${YELLOW}Cluster Overview:${NC}"
kubectl get pods -n app
kubectl get pods -n monitoring

echo -e "\n${YELLOW}Database Connection Status:${NC}"
kubectl get configmap db-status -n app -o jsonpath='{.data.status}' 2>/dev/null

echo -e "\n${YELLOW}Prometheus Scrape Health:${NC}"
echo "Scrape failures: High"
echo "Metrics staleness: 10+ minutes"
echo "Alert evaluation: Delayed"

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED} Manual patch bypassed ArgoCD sync (Secret password changed)${NC}"
echo -e "${RED} App restarts unable to authenticate with DB${NC}"
echo -e "${RED} Infinite retry loop causing connection leak${NC}"
echo -e "${RED} PostgreSQL connection pool exhausted (98/100)${NC}"
echo -e "${RED} Node pressure from CPU/memory consumption${NC}"
echo -e "${RED} Kubelet OOM killing low-priority pods${NC}"
echo -e "${RED} Prometheus scrapes failing (throttled endpoints)${NC}"
echo -e "${RED} Alertmanager alerts delayed by 15+ minutes${NC}"
echo -e "${RED} False sense of cluster health (dashboards stale)${NC}"

echo -e "\n${YELLOW}=== Propagation Chain (6 Levels) ===${NC}"
echo "1->  ArgoCD Drift: Manual hotfix changed DB_PASSWORD in Secret"
echo "2->  Secret Mismatch: App restarts can't connect to DB (wrong credentials)"
echo "3->  DB Connection Leak: Connection pool retries infinitely -> Postgres refusing connections"
echo "4->  Node Pressure: App pods consume CPU/memory -> Kubelet OOM kills other pods"
echo "5->  Prometheus Throttle: Kubelet /metrics returns 500s -> scrape failures"
echo "6->  Alert Delays: Alert thresholds missed -> high latency alerts 15 min late"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo " ArgoCD drift warnings (OutOfSync status)"
echo " Database connection pool exhaustion errors"
echo " Application authentication failures in logs"
echo " OOMKilled containers"
echo " Node resource pressure events"
echo " Prometheus scrape failure errors"
echo " Alert delivery delays in Alertmanager"
echo " Kubelet /metrics endpoint 500 errors"
echo " Pod restart count increasing"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this cascading failure:"
echo ""
echo "1. Identify and revert manual cluster changes:"
echo "   kubectl get secret db-credentials -n app -o yaml"
echo "   # Check annotations for 'modified-by' and 'drift' markers"
echo ""
echo "2. Restore correct secret from Git/source of truth:"
echo "   kubectl create secret generic db-credentials -n app \\"
echo "     --from-literal=DB_HOST=postgres.app.svc.cluster.local \\"
echo "     --from-literal=DB_PORT=5432 \\"
echo "     --from-literal=DB_USER=appuser \\"
echo "     --from-literal=DB_PASSWORD=correctpassword123 \\"
echo "     --dry-run=client -o yaml | kubectl apply -f -"
echo ""
echo "3. Sync ArgoCD to restore GitOps state:"
echo "   kubectl patch application web-app -n argocd --type merge \\"
echo "     -p '{\"operation\":{\"sync\":{\"revision\":\"HEAD\"}}}'"
echo ""
echo "4. Restart affected pods to reset connection pools:"
echo "   kubectl rollout restart deployment/web-app -n app"
echo ""
echo "5. Verify Prometheus scrape health:"
echo "   kubectl logs -n monitoring -l app=prometheus --tail=50"
echo ""
echo "6. Check Alertmanager queue:"
echo "   # Review and flush delayed alerts"
echo ""
echo "7. Monitor recovery:"
echo "   kubectl get pods -n app --watch"
echo "   kubectl logs -n app -l app=web-app -f"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "" Enforce GitOps-only workflows with admission controllers (OPA/Kyverno)"
echo "" Enable ArgoCD drift detection with automated notifications"
echo "" Implement webhook alerts for manual kubectl apply operations"
echo "" Configure connection pool limits and timeouts in applications"
echo "" Set appropriate resource requests/limits on all pods"
echo "" Monitor Prometheus scrape success rates and alert on failures"
echo "" Use PodDisruptionBudgets to protect critical workloads"
echo "" Implement chaos engineering to test cascading failure scenarios"
echo "" Set up pre-commit hooks to validate manifests"
echo "" Use policy engines to prevent manual Secret modifications"
echo "" Implement Secret rotation workflows (Vault, External Secrets)"
echo "" Monitor database connection pool metrics"
echo "" Set up Kubelet health monitoring and alerting"

echo -e "\n${GREEN}=== Scenario 11 Complete ===${NC}"
echo "This demonstrates: ArgoCD Drift -> Secret Mismatch -> DB Connection Leak"
echo "                  -> Node Pressure -> Prometheus Throttle -> Alert Delays"
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
echo "" Manual changes bypass GitOps and create drift"
echo "" Secret mismatches cascade into connection pool issues"
echo "" Resource pressure affects monitoring systems"
echo "" Observability blind spots hide critical failures"
echo "" 6-level dependency chains create complex incidents"
