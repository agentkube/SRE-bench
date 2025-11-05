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
echo -e "${BLUE}  Scenario 13: NetworkPolicy Restriction → Service Mesh Retry Storm${NC}"
echo -e "${BLUE}      → DB Saturation → Prometheus Lag → Alert Suppression → Partial Outage${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-13-cluster"
    fi

    CLUSTER_NAME="scenario-13-cluster"
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

# Create namespaces
echo -e "\n${YELLOW}=== Creating Namespaces ===${NC}"
kubectl create namespace frontend --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace frontend name=frontend --overwrite
kubectl create namespace backend --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace backend name=backend --overwrite
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespaces created${NC}"

# Install Prometheus and Alertmanager
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
echo -e "${GREEN}✓ Monitoring stack installed${NC}"

# Deploy PostgreSQL database in backend namespace
echo -e "\n${YELLOW}=== Deploying PostgreSQL Database ===${NC}"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-db
  namespace: backend
  labels:
    app: auth-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: auth-db
  template:
    metadata:
      labels:
        app: auth-db
    spec:
      containers:
      - name: postgres
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "PostgreSQL Database Server (Auth DB)"
            echo "Max connections: 100"
            CONNECTION_COUNT=0
            while true; do
              sleep 2
              INCOMING=\$((RANDOM % 5))
              CONNECTION_COUNT=\$((CONNECTION_COUNT + INCOMING))
              if [ \$CONNECTION_COUNT -gt 100 ]; then CONNECTION_COUNT=100; fi
              if [ \$CONNECTION_COUNT -ge 95 ]; then
                echo "[CRITICAL] Connection pool near exhaustion: \${CONNECTION_COUNT}/100"
              elif [ \$CONNECTION_COUNT -ge 80 ]; then
                echo "[WARNING] High connection usage: \${CONNECTION_COUNT}/100"
              else
                echo "[INFO] Active connections: \${CONNECTION_COUNT}/100"
              fi
            done
        ports:
        - containerPort: 5432
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: auth-db
  namespace: backend
spec:
  selector:
    app: auth-db
  ports:
  - port: 5432
    targetPort: 5432
EOF

echo "Waiting for database..."
kubectl wait --for=condition=Available --timeout=60s deployment/auth-db -n backend 2>/dev/null || echo "Database taking longer..."
echo -e "${GREEN}✓ Database deployed${NC}"

# Deploy Auth Service
echo -e "\n${YELLOW}=== Deploying Auth Service ===${NC}"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service
  namespace: backend
  labels:
    app: auth-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app: auth-service
  template:
    metadata:
      labels:
        app: auth-service
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      containers:
      - name: auth
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Auth Service v1.0"
            echo "Connected to: auth-db.backend.svc.cluster.local:5432"
            REQUEST_COUNT=0
            while true; do
              sleep 2
              REQUEST_COUNT=\$((REQUEST_COUNT + 1))
              echo "[AUTH] Request #\${REQUEST_COUNT} - Response: 200 OK"
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
  name: auth-service
  namespace: backend
spec:
  selector:
    app: auth-service
  ports:
  - port: 8080
    targetPort: 8080
EOF

kubectl wait --for=condition=Available --timeout=60s deployment/auth-service -n backend 2>/dev/null || echo "Auth service taking longer..."
echo -e "${GREEN}✓ Auth service deployed${NC}"

# Deploy API Gateway with Istio sidecar
echo -e "\n${YELLOW}=== Deploying API Gateway (with Istio Sidecar) ===${NC}"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-gateway
  namespace: frontend
  labels:
    app: api-gateway
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-gateway
  template:
    metadata:
      labels:
        app: api-gateway
      annotations:
        prometheus.io/scrape: "true"
    spec:
      containers:
      - name: gateway
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "API Gateway v1.0"
            echo "Routes: POST /login -> auth-service.backend:8080"
            REQUEST_COUNT=0
            while true; do
              sleep 3
              REQUEST_COUNT=\$((REQUEST_COUNT + 1))
              echo "[GATEWAY] Request #\${REQUEST_COUNT} - Status: 200 OK"
            done
        ports:
        - containerPort: 8080
      - name: istio-proxy
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Istio Proxy v1.18 - Retry: 5 attempts"
            while true; do sleep 5; echo "[ISTIO] Proxying..."; done
---
apiVersion: v1
kind: Service
metadata:
  name: api-gateway
  namespace: frontend
spec:
  selector:
    app: api-gateway
  ports:
  - port: 80
    targetPort: 8080
EOF

kubectl wait --for=condition=Available --timeout=60s deployment/api-gateway -n frontend 2>/dev/null || echo "Gateway taking longer..."
echo -e "${GREEN}✓ API gateway deployed${NC}"

# Create initial OPEN NetworkPolicy
echo -e "\n${YELLOW}=== Creating Initial NetworkPolicy (OPEN) ===${NC}"
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-allow-all
  namespace: backend
  annotations:
    version: "v1-open"
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector: {}
EOF

echo -e "${GREEN}✓ Initial NetworkPolicy applied (allows cross-namespace)${NC}"

# Show initial state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
kubectl get pods -n frontend
kubectl get pods -n backend
kubectl get networkpolicy -n backend

echo -e "\n${YELLOW}Connectivity: frontend → backend: ALLOWED${NC}"
sleep 3

# TRIGGER
echo -e "\n${RED}=== TRIGGER: NetworkPolicy Restriction ===${NC}"
echo "Security team applies strict isolation..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-deny-cross-namespace
  namespace: backend
  annotations:
    version: "v2-restricted"
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector: {}
EOF

echo -e "${RED}✗ NetworkPolicy: Cross-namespace traffic BLOCKED${NC}"

# Continue with remaining steps...
echo -e "\n${BLUE}=== Step 1: NetworkPolicy Restriction ===${NC}"
echo "✗ frontend → backend: BLOCKED"

echo -e "\n${BLUE}=== Step 2: Service Mesh Retry Storm ===${NC}"
echo "Istio retries: 5x per request → Traffic amplification"

echo -e "\n${BLUE}=== Step 3: DB Saturation ===${NC}"
echo "Database connections: 98/100 (CRITICAL)"

echo -e "\n${BLUE}=== Step 4: Prometheus Lag ===${NC}"
echo "Metrics stale: 2+ minutes"

echo -e "\n${BLUE}=== Step 5: Alert Suppression ===${NC}"
echo "No alerts fired (insufficient data)"

echo -e "\n${BLUE}=== Step 6: Partial Outage ===${NC}"
echo "Users unable to login (100% failure)"
echo "Monitoring: GREEN (false negative)"

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ NetworkPolicy blocks cross-namespace traffic${NC}"
echo -e "${RED}✗ Istio retry storm: 5x amplification${NC}"
echo -e "${RED}✗ Database pool exhausted: 98/100${NC}"
echo -e "${RED}✗ Prometheus metrics stale: 2+ min${NC}"
echo -e "${RED}✗ No alerts fired (observability blind spot)${NC}"
echo -e "${RED}✗ Users cannot login - detected via support tickets${NC}"

echo -e "\n${GREEN}=== Scenario 13 Complete ===${NC}"
echo "This demonstrates the observability blind spot problem"
echo ""
if [ "$SKIP_SETUP" = false ]; then
    echo "To delete: kind delete cluster --name ${CLUSTER_NAME}"
fi
