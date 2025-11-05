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
echo -e "${BLUE}  Scenario 14: Postgres Schema Drift → ORM Migration Failure${NC}"
echo -e "${BLUE}    → API Crash → Prometheus Missing Series → Alert Flap → Argo Rollback Loop${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-14-cluster"
    fi

    CLUSTER_NAME="scenario-14-cluster"
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
kubectl create namespace app --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespaces created${NC}"

# Install ArgoCD
echo -e "\n${YELLOW}=== Installing ArgoCD ===${NC}"
echo "Installing ArgoCD components..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-server -n argocd 2>/dev/null || echo "ArgoCD server taking longer..."
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-repo-server -n argocd 2>/dev/null || echo "Repo server taking longer..."
kubectl wait --for=condition=Available --timeout=300s deployment/argocd-application-controller -n argocd 2>/dev/null || echo "Controller taking longer..."
echo -e "${GREEN}✓ ArgoCD installed${NC}"

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

# Deploy PostgreSQL with correct schema (v1)
echo -e "\n${YELLOW}=== Deploying PostgreSQL Database (Schema v1) ===${NC}"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: db-schema
  namespace: app
  annotations:
    version: "v1"
    migration: "baseline"
data:
  schema.sql: |
    -- Schema v1 (Baseline)
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      username VARCHAR(255) NOT NULL,
      email VARCHAR(255) NOT NULL,
      created_at TIMESTAMP DEFAULT NOW()
    );
---
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
            echo "PostgreSQL Database v13.8"
            echo "Schema version: v1 (baseline)"
            echo ""
            echo "Current Schema:"
            echo "  Table: users"
            echo "    - id (SERIAL PRIMARY KEY)"
            echo "    - username (VARCHAR NOT NULL)"
            echo "    - email (VARCHAR NOT NULL)"
            echo "    - created_at (TIMESTAMP)"
            echo ""
            while true; do
              sleep 10
              echo "[DB] Schema v1 - Accepting connections"
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
echo -e "${GREEN}✓ PostgreSQL deployed with schema v1${NC}"

# Deploy API application (v1 - compatible with schema v1)
echo -e "\n${YELLOW}=== Deploying API Application (v1) ===${NC}"
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: app
  labels:
    app: api-service
    version: v1
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-service
  template:
    metadata:
      labels:
        app: api-service
        version: v1
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
            echo "API Service v1.0"
            echo "ORM: SQLAlchemy 1.4"
            echo "Expected schema: v1"
            echo ""
            echo "Running database migrations..."
            echo "✓ Migration check passed - Schema v1 compatible"
            echo "✓ Application started successfully"
            echo ""
            
            REQUEST_COUNT=0
            while true; do
              sleep 3
              REQUEST_COUNT=\$((REQUEST_COUNT + 1))
              LATENCY=\$((RANDOM % 100 + 20))
              echo "[API] Request #\${REQUEST_COUNT} - Latency: \${LATENCY}ms - Status: 200 OK"
            done
        ports:
        - containerPort: 8080
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'Application started' > /dev/null"
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'API Service' > /dev/null"
          initialDelaySeconds: 15
          periodSeconds: 10
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
---
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
EOF

kubectl wait --for=condition=Available --timeout=120s deployment/api-service -n app 2>/dev/null || echo "API service taking longer..."
echo -e "${GREEN}✓ API Service v1 deployed and healthy${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
kubectl get pods -n app
kubectl get pods -n argocd | head -10

echo -e "\n${YELLOW}Database Schema (v1):${NC}"
kubectl get configmap db-schema -n app -o jsonpath='{.data.schema\.sql}' | head -10

echo -e "\n${YELLOW}API Service Logs:${NC}"
kubectl logs -n app -l app=api-service --tail=8 | head -15

echo -e "\n${YELLOW}Prometheus Metrics (API latency):${NC}"
echo "api_request_duration_ms{service=\"api-service\",version=\"v1\"} present"
echo "api_requests_total{service=\"api-service\",version=\"v1\"} present"

# TRIGGER: Manual Schema Change (outside migration control)
echo -e "\n${RED}=== TRIGGER: Manual Database Schema Change ===${NC}"
echo "Simulating: DBA manually alters schema outside migration workflow"
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: db-schema
  namespace: app
  annotations:
    version: "v2-manual"
    migration: "MANUAL-CHANGE"
    modified-by: "dba-direct-access"
    drift: "true"
data:
  schema.sql: |
    -- Schema v2 (Manual modification - NOT from migration tool!)
    CREATE TABLE IF NOT EXISTS users (
      id SERIAL PRIMARY KEY,
      username VARCHAR(255) NOT NULL,
      email VARCHAR(255) NOT NULL,
      phone VARCHAR(50),  -- NEW COLUMN (added manually)
      created_at TIMESTAMP DEFAULT NOW()
    );
    
    -- Manual ALTER (not tracked in migrations)
    ALTER TABLE users ADD COLUMN IF NOT EXISTS phone VARCHAR(50);
EOF

echo -e "${RED}✗ Schema altered: Added 'phone' column to users table${NC}"
echo -e "${RED}✗ Change NOT tracked in migration system (Flyway/Alembic)${NC}"
echo -e "${RED}✗ Application ORM expects schema v1${NC}"

# Step 1: Schema Drift
echo -e "\n${BLUE}=== Step 1: Schema Drift ===${NC}"
echo "Database schema altered outside migration workflow"
echo "Current schema (v2) != Expected schema (v1)"

kubectl get configmap db-schema -n app -o yaml | grep -A 3 "annotations:"

# Step 2: ORM Migration Failure (simulating new deployment)
echo -e "\n${BLUE}=== Step 2: ORM Migration Failure ===${NC}"
echo "ArgoCD triggers deployment of new version..."
echo "Application startup migration check fails..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-service
  namespace: app
  labels:
    app: api-service
    version: v2
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-service
  template:
    metadata:
      labels:
        app: api-service
        version: v2
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
            echo "API Service v2.0"
            echo "ORM: SQLAlchemy 1.4"
            echo "Expected schema: v1"
            echo ""
            echo "Running database migrations..."
            echo "ERROR: Migration check failed!"
            echo "ERROR: Schema mismatch detected"
            echo "ERROR: Unknown column 'phone' in database"
            echo "ERROR: Migration history inconsistent"
            echo "FATAL: Cannot start application - schema validation failed"
            echo ""
            echo "Migration error: alembic.migration.MigrationError"
            echo "  Database schema at revision 'unknown'"
            echo "  Expected revision: '001_baseline'"
            echo "  Manual changes detected outside migration control"
            
            # Keep container running but fail readiness
            while true; do
              sleep 5
              echo "ERROR: Application failed to start"
            done
        ports:
        - containerPort: 8080
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'Application started' > /dev/null"
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 3
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'API Service' > /dev/null"
          initialDelaySeconds: 15
          periodSeconds: 10
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
EOF

sleep 15
echo -e "\n${YELLOW}Deployment Status:${NC}"
kubectl get pods -n app

echo -e "\n${YELLOW}Migration Failure Logs:${NC}"
kubectl logs -n app -l app=api-service,version=v2 --tail=15 2>/dev/null | head -20 || echo "Pods starting..."

# Step 3: API Crash (CrashLoopBackOff)
echo -e "\n${BLUE}=== Step 3: API Crash (CrashLoopBackOff) ===${NC}"
echo "Pods failing readiness probe due to migration failure..."
sleep 5

kubectl get pods -n app -l app=api-service
kubectl get events -n app --sort-by='.lastTimestamp' | grep -i "readiness\|unhealthy" | tail -10 || echo "Events loading..."

# Step 4: Prometheus Missing Time-Series
echo -e "\n${BLUE}=== Step 4: Prometheus Missing Time-Series ===${NC}"
echo "API pods not ready → metrics endpoints unavailable..."
echo "Time-series for API latency disappearing from TSDB..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-series-status
  namespace: monitoring
data:
  status: |
    Prometheus Time-Series Status:

    MISSING SERIES:
    - api_request_duration_ms{service="api-service",version="v2"} - MISSING
    - api_requests_total{service="api-service",version="v2"} - MISSING
    - http_server_requests_seconds{app="api-service"} - MISSING
    
    Last seen: 3m 45s ago
    
    Scrape Targets:
    - api-service-pod-1: DOWN (readiness probe failed)
    - api-service-pod-2: DOWN (readiness probe failed)
    - api-service-pod-3: DOWN (readiness probe failed)
    
    Impact:
    - Dashboards showing gaps in metrics
    - Alert rules cannot evaluate (no data)
    - Query results incomplete
EOF

kubectl get configmap prometheus-series-status -n monitoring -o jsonpath='{.data.status}'

# Step 5: Alert Flap
echo -e "\n${BLUE}=== Step 5: Alert Flap (Firing → Resolved → Firing) ===${NC}"
echo "Missing metrics cause alerts to flap..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: alert-flapping
  namespace: monitoring
data:
  alerts: |
    Alertmanager - Alert Flapping Detected:

    [HIGH] APIHighLatency
    - Status: FIRING (3m ago)
    - Status: RESOLVED (2m ago) - metrics disappeared
    - Status: FIRING (1m ago) - old metrics reappeared
    - Status: RESOLVED (30s ago) - metrics missing again
    - Current: PENDING (insufficient data)
    - Flap count: 4 in 5 minutes

    [CRITICAL] APIServiceDown
    - Status: FIRING (4m ago)
    - Status: RESOLVED (3m ago) - false recovery
    - Status: FIRING (2m ago)
    - Status: RESOLVED (1m ago) - metrics gap
    - Current: FIRING
    - Flap count: 4 in 5 minutes

    [HIGH] HighErrorRate
    - Status: Cannot evaluate (no time-series data)
    - Last evaluation: 4m 12s ago
    - Current: UNKNOWN

    Root Cause: Prometheus time-series disappearing
    Engineers confused by inconsistent alert states
EOF

kubectl get configmap alert-flapping -n monitoring -o jsonpath='{.data.alerts}'

# Step 6: ArgoCD Rollback Loop
echo -e "\n${BLUE}=== Step 6: ArgoCD Rollback Loop ===${NC}"
echo "ArgoCD detects failing health checks..."
echo "Attempting automatic rollback..."
sleep 2

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rollback-status
  namespace: argocd
data:
  status: |
    ArgoCD Application Controller - Rollback Loop Detected

    Application: api-service
    Target Revision: main/HEAD
    
    Sync/Rollback History:
    
    [2m 30s ago] Sync attempt #1
      → Deployment api-service updated (v2)
      → Health check: Progressing
      → Health check: Degraded (pods not ready)
      → AUTO-ROLLBACK triggered
    
    [2m 00s ago] Rollback to previous version (v1)
      → Deployment api-service updated (v1)
      → Health check: Progressing
      → Migration fails (schema mismatch from v2)
      → Health check: Degraded
      → Rollback FAILED
    
    [1m 30s ago] Sync attempt #2
      → Deployment api-service updated (v2)
      → Health check: Progressing
      → Health check: Degraded (same error)
      → AUTO-ROLLBACK triggered
    
    [1m 00s ago] Rollback to previous version (v1)
      → Same failure pattern
      → Health check: Degraded
      → Rollback FAILED
    
    [30s ago] Sync attempt #3
      → LOOP DETECTED
      → Manual intervention required
    
    Status: ROLLBACK LOOP
    Reason: Both versions fail due to schema drift
    Manual intervention: REQUIRED
EOF

kubectl get configmap argocd-rollback-status -n argocd -o jsonpath='{.data.status}'

echo -e "\n${YELLOW}ArgoCD Application Status:${NC}"
echo "Sync Status: OutOfSync (Rollback Loop)"
echo "Health Status: Degraded"
echo "Last Sync: Failed (3 attempts)"

# Show final degraded state
echo -e "\n${BLUE}=== Final Degraded State ===${NC}"

echo -e "\n${YELLOW}Pod Status:${NC}"
kubectl get pods -n app

echo -e "\n${YELLOW}Deployment Status:${NC}"
kubectl get deployment api-service -n app

echo -e "\n${YELLOW}Recent Events:${NC}"
kubectl get events -n app --sort-by='.lastTimestamp' | tail -15

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ Database schema manually altered (added 'phone' column)${NC}"
echo -e "${RED}✗ Schema change NOT tracked in migration system${NC}"
echo -e "${RED}✗ Application deployment fails migration check${NC}"
echo -e "${RED}✗ Pods enter CrashLoopBackOff (readiness probe fails)${NC}"
echo -e "${RED}✗ Prometheus time-series disappear from TSDB${NC}"
echo -e "${RED}✗ Alerts flap: Firing → Resolved → Firing (4 flaps in 5 min)${NC}"
echo -e "${RED}✗ ArgoCD rollback loop (both v1 and v2 fail)${NC}"
echo -e "${RED}✗ No clear root cause visible in monitoring${NC}"
echo -e "${RED}✗ Dev team blames CI/CD pipeline${NC}"
echo -e "${RED}✗ Extended outage (recovery blocked by endless loop)${NC}"

echo -e "\n${YELLOW}=== Propagation Chain (6 Levels) ===${NC}"
echo "1️⃣  Schema Drift: DB table altered outside migration workflow"
echo "2️⃣  ORM Migration Fails: App deploy fails startup migration check"
echo "3️⃣  API Crash: App CrashLoopBackOff, readiness probe fails"
echo "4️⃣  Prometheus Missing Series: Metrics labels disappear from TSDB"
echo "5️⃣  Alert Flap: Missing metrics → alerts resolve/fire intermittently"
echo "6️⃣  Argo Rollback Loop: Repeated rollback + redeploy (same failure)"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ Database migration failure errors in application logs"
echo "✓ CrashLoopBackOff pod status"
echo "✓ ArgoCD sync/rollback events in rapid succession"
echo "✓ Missing Prometheus time-series (metrics disappearing)"
echo "✓ Alert state flapping (firing → resolved → firing)"
echo "✓ Readiness probe failures"
echo "✓ Schema validation errors in logs"
echo "✓ Database audit logs showing manual schema changes"
echo "✓ ArgoCD application health: Degraded"
echo "✓ ORM/migration tool errors (alembic, flyway, liquibase)"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this cascading failure:"
echo ""
echo "1. Identify schema drift in database:"
echo "   kubectl exec -it postgres-pod -n app -- psql -U postgres"
echo "   \d users;  -- Show current schema"
echo "   # Check for columns not in migration history"
echo ""
echo "2. Check migration history vs actual schema:"
echo "   # Review migration tool history (Alembic/Flyway)"
echo "   kubectl logs -n app -l app=api-service | grep -i migration"
echo ""
echo "3. Pause ArgoCD auto-sync to break rollback loop:"
echo "   kubectl patch application api-service -n argocd --type merge \\"
echo "     -p '{\"spec\":{\"syncPolicy\":{\"automated\":null}}}'"
echo ""
echo "4. Option A - Revert unauthorized schema changes:"
echo "   kubectl exec -it postgres-pod -n app -- psql -U postgres"
echo "   ALTER TABLE users DROP COLUMN phone;"
echo ""
echo "5. Option B - Update migration scripts to match current schema:"
echo "   # Create new migration capturing the manual change"
echo "   # Update application to handle new schema"
echo "   # Deploy via GitOps"
echo ""
echo "6. Fix application migration scripts:"
echo "   # Update ORM models and migration files"
echo "   # Test migrations in staging"
echo ""
echo "7. Deploy corrected version manually:"
echo "   kubectl apply -f fixed-deployment.yaml"
echo ""
echo "8. Verify Prometheus metrics recovery:"
echo "   kubectl logs -n monitoring -l app=prometheus --tail=50"
echo ""
echo "9. Resume ArgoCD auto-sync after stability:"
echo "   kubectl patch application api-service -n argocd --type merge \\"
echo "     -p '{\"spec\":{\"syncPolicy\":{\"automated\":{\"prune\":true,\"selfHeal\":true}}}}'"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Enforce database schema change controls (no direct DB access)"
echo "• Use migration tools exclusively (Flyway, Liquibase, Alembic)"
echo "• Implement database change approval workflows"
echo "• Enable database audit logging for schema changes"
echo "• Test migrations in staging environments before production"
echo "• Use schema validation in CI/CD pipeline"
echo "• Configure migration failure alerts"
echo "• Implement database GitOps workflows"
echo "• Use read-only database users for application runtime"
echo "• Add pre-deployment schema compatibility checks"
echo "• Disable ArgoCD auto-rollback for database-dependent services"
echo "• Set up database schema monitoring and drift detection"
echo "• Implement schema versioning with strict controls"
echo "• Use database migration dry-run/preview before applying"
echo "• Create baseline schema snapshots for disaster recovery"
echo "• Document all schema changes in version control"

echo -e "\n${GREEN}=== Scenario 14 Complete ===${NC}"
echo "This demonstrates: Postgres Schema Drift → ORM Migration Failure"
echo "                  → API Crash → Prometheus Missing Series → Alert Flap → Argo Rollback Loop"
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
echo "• Manual database changes outside migration control cause drift"
echo "• ORM tools fail when schema doesn't match migration history"
echo "• Rollback loops occur when both old and new versions fail"
echo "• Missing metrics create observability gaps and alert flapping"
echo "• Root cause hidden when dev teams blame CI/CD instead of DB"
echo "• Database schema changes need strict governance"
