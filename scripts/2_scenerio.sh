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
echo -e "${BLUE}  Scenario 2: Expired Secret Rotation → Database Auth Failures → API Downtime${NC}"
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
        bash "${SCRIPT_DIR}/setup.sh" "scenario-2-cluster"
    fi

    CLUSTER_NAME="scenario-2-cluster"
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

# Create application namespace
echo -e "\n${YELLOW}=== Creating Application Namespace ===${NC}"
kubectl create namespace api-app --dry-run=client -o yaml | kubectl apply -f -

# Create initial database secret (v1 - valid credentials)
echo -e "\n${YELLOW}=== Creating Database Secret (v1 - valid) ===${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: api-app
  annotations:
    secret-version: "v1"
    created-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    expires-at: "$(date -u -v+5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
type: Opaque
stringData:
  username: "dbuser"
  password: "validpassword123"
EOF

echo -e "${GREEN}✓ Database secret created${NC}"

# Create mock database pod
echo -e "\n${YELLOW}=== Creating Mock Database Pod ===${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: mock-database
  namespace: api-app
  labels:
    app: database
spec:
  containers:
  - name: db
    image: busybox:latest
    command: ["/bin/sh", "-c"]
    args:
      - |
        echo "Database server starting..."
        echo "Valid credentials: username=dbuser, password=validpassword123"

        # Create a simple auth check script
        cat > /tmp/check_auth.sh <<'AUTHSCRIPT'
        #!/bin/sh
        USER="\$1"
        PASS="\$2"

        if [ "\$USER" = "dbuser" ] && [ "\$PASS" = "validpassword123" ]; then
          echo "AUTH_SUCCESS"
          exit 0
        else
          echo "AUTH_FAILED: Invalid credentials"
          exit 1
        fi
        AUTHSCRIPT
        chmod +x /tmp/check_auth.sh

        echo "Database ready to accept connections"
        while true; do sleep 3600; done
    ports:
    - containerPort: 5432
      name: postgres
---
apiVersion: v1
kind: Service
metadata:
  name: database
  namespace: api-app
spec:
  selector:
    app: database
  ports:
  - port: 5432
    targetPort: 5432
    name: postgres
EOF

echo "Waiting for database pod to be ready..."
kubectl wait --for=condition=Ready pod/mock-database -n api-app --timeout=60s
echo -e "${GREEN}✓ Database pod ready${NC}"

# Create API application deployment
echo -e "\n${YELLOW}=== Creating API Application Deployment ===${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-app
  namespace: api-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: api-app
  template:
    metadata:
      labels:
        app: api-app
    spec:
      containers:
      - name: api
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "API Server starting..."
            echo "Connecting to database at database.api-app.svc.cluster.local:5432"
            echo "Using credentials: \${DB_USER}/\${DB_PASS}"

            # Simulate database connection
            MAX_RETRIES=3
            RETRY_COUNT=0

            while [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; do
              echo "Attempting database connection (attempt \$((RETRY_COUNT + 1))/\$MAX_RETRIES)..."

              # In a real scenario, this would connect to DB
              # Here we simulate auth check
              if [ "\${DB_USER}" = "dbuser" ] && [ "\${DB_PASS}" = "validpassword123" ]; then
                echo "✓ Database connection successful"
                echo "✓ Connection pool initialized (max: 10 connections)"
                echo "API server ready to handle requests"

                # Keep the container running
                while true; do
                  sleep 10
                  echo "API healthy - Active connections: \$((RANDOM % 8 + 1))/10"
                done
              else
                echo "✗ Database authentication failed!"
                echo "Credentials rejected by database"
                RETRY_COUNT=\$((RETRY_COUNT + 1))

                if [ \$RETRY_COUNT -lt \$MAX_RETRIES ]; then
                  echo "Retrying in 5 seconds..."
                  sleep 5
                else
                  echo "ERROR: Max retries exceeded. Connection pool exhausted."
                  echo "API server cannot start - exiting"
                  exit 1
                fi
              fi
            done
        env:
        - name: DB_HOST
          value: "database.api-app.svc.cluster.local"
        - name: DB_PORT
          value: "5432"
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: username
        - name: DB_PASS
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: password
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'API healthy' > /dev/null"
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - "pgrep -f 'sleep' > /dev/null"
          initialDelaySeconds: 15
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: api-app
  namespace: api-app
spec:
  selector:
    app: api-app
  ports:
  - port: 80
    targetPort: 8080
    name: http
EOF

echo "Waiting for API deployment to be ready..."
kubectl rollout status deployment/api-app -n api-app --timeout=120s
echo -e "${GREEN}✓ API application running with valid credentials${NC}"

# Show initial healthy state
echo -e "\n${BLUE}=== Initial Healthy State ===${NC}"
kubectl get pods -n api-app
echo ""
kubectl logs -n api-app -l app=api-app --tail=5 | head -20

# Create a secret rotation CronJob (that will fail)
echo -e "\n${YELLOW}=== Creating Secret Rotation CronJob (misconfigured) ===${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: rotate-db-secret
  namespace: api-app
spec:
  schedule: "*/5 * * * *"  # Every 5 minutes
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: default
          containers:
          - name: rotator
            image: busybox:latest
            command: ["/bin/sh", "-c"]
            args:
              - |
                echo "Secret rotation job starting..."
                echo "ERROR: Missing RBAC permissions to update secrets"
                echo "ERROR: Secret rotation failed!"
                exit 1
          restartPolicy: OnFailure
EOF

echo -e "${GREEN}✓ Secret rotation CronJob created (but will fail)${NC}"

# Simulate time passing and secret expiration
echo -e "\n${YELLOW}=== Simulating Secret Expiration ===${NC}"
echo "In a real scenario, database would expire the credentials after TTL..."
echo "Simulating by updating secret with expired/invalid credentials..."
sleep 5

# Update secret with expired credentials
echo -e "\n${YELLOW}=== Updating Secret to Expired Credentials ===${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
  namespace: api-app
  annotations:
    secret-version: "v1-expired"
    created-at: "$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)"
    expires-at: "$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
    status: "EXPIRED"
type: Opaque
stringData:
  username: "dbuser"
  password: "expiredpassword999"
EOF

echo -e "${GREEN}✓ Secret updated to expired credentials${NC}"
echo "Note: Existing pods still have old cached secret values"

# Force pods to restart and pick up new (expired) secret
echo -e "\n${YELLOW}=== Forcing Pod Restart to Pick Up Expired Secret ===${NC}"
echo "Simulating pods restarting (e.g., due to deployment update or node failure)..."
kubectl rollout restart deployment/api-app -n api-app

echo "Waiting to observe connection failures..."
sleep 15

# Show failing state
echo -e "\n${BLUE}=== Scenario 2 Status ===${NC}"
echo -e "\n${YELLOW}Pod Status:${NC}"
kubectl get pods -n api-app

echo -e "\n${YELLOW}Recent Events:${NC}"
kubectl get events -n api-app --sort-by='.lastTimestamp' | tail -20

echo -e "\n${YELLOW}Pod Logs (showing failures):${NC}"
for pod in $(kubectl get pods -n api-app -l app=api-app -o name | head -2); do
    echo -e "\n${BLUE}Logs from $pod:${NC}"
    kubectl logs $pod -n api-app --tail=15 2>/dev/null || echo "Pod not ready yet or crashing"
done

echo -e "\n${YELLOW}Secret Rotation Job Status:${NC}"
kubectl get cronjobs -n api-app
kubectl get jobs -n api-app 2>/dev/null || echo "No jobs executed yet"

echo -e "\n${RED}=== Incident Summary ===${NC}"
echo -e "${RED}✗ Database credentials expired${NC}"
echo -e "${RED}✗ Secret rotation CronJob failed (RBAC misconfiguration)${NC}"
echo -e "${RED}✗ API pods unable to authenticate with database${NC}"
echo -e "${RED}✗ Connection pool exhaustion${NC}"
echo -e "${RED}✗ API pods in CrashLoopBackOff${NC}"
echo -e "${RED}✗ Service returning 502 Bad Gateway errors${NC}"

echo -e "\n${YELLOW}=== Root Cause ===${NC}"
echo "1. Database credentials reached expiration (TTL expired)"
echo "2. Secret rotation CronJob failed due to missing RBAC permissions"
echo "3. Existing pods cached old credentials (worked until restart)"
echo "4. Pod restarts triggered (deployment update/node events)"
echo "5. New pods attempted connection with expired credentials"
echo "6. Database rejected authentication"
echo "7. Connection retry logic exhausted connection pool"
echo "8. Result: CrashLoopBackOff and API downtime"

echo -e "\n${YELLOW}=== Detection Signals ===${NC}"
echo "✓ Database connection errors in application logs"
echo "✓ 502 Bad Gateway responses from API"
echo "✓ Failed CronJob executions"
echo "✓ Secret annotation showing 'EXPIRED' status"
echo "✓ Increased pod restart count"
echo "✓ Authentication errors: 'Credentials rejected by database'"

echo -e "\n${YELLOW}=== Remediation Steps ===${NC}"
echo "To fix this issue:"
echo ""
echo "1. Check secret rotation job status:"
echo "   kubectl get cronjobs -n api-app"
echo "   kubectl logs -n api-app job/rotate-db-secret-<job-id>"
echo ""
echo "2. Fix RBAC permissions for secret rotation (if needed)"
echo ""
echo "3. Manually rotate the secret with valid credentials:"
echo "   kubectl create secret generic db-credentials -n api-app \\"
echo "     --from-literal=username=dbuser \\"
echo "     --from-literal=password=validpassword123 \\"
echo "     --dry-run=client -o yaml | kubectl apply -f -"
echo ""
echo "4. Restart API pods to pick up new credentials:"
echo "   kubectl rollout restart deployment/api-app -n api-app"
echo ""
echo "5. Verify pods are healthy:"
echo "   kubectl get pods -n api-app"
echo "   kubectl logs -n api-app -l app=api-app --tail=20"
echo ""
echo "6. Set up monitoring for:"
echo "   - Secret expiration dates"
echo "   - CronJob execution success/failure"
echo "   - Database connection errors"

echo -e "\n${YELLOW}=== Prevention Measures ===${NC}"
echo "• Ensure CronJob has proper RBAC permissions"
echo "• Monitor CronJob execution status and alert on failures"
echo "• Implement secret rotation alerts before expiration"
echo "• Use external secret management (Vault, AWS Secrets Manager, etc.)"
echo "• Set up pre-expiration warnings (e.g., 24 hours before)"
echo "• Test secret rotation in staging environment"
echo "• Implement gradual rollout for pods after secret rotation"
echo "• Add connection pool health metrics to monitoring"

echo -e "\n${GREEN}=== Scenario 2 Complete ===${NC}"
echo "This demonstrates: Expired Secret Rotation → Database Auth Failures → API Downtime"
echo ""
echo -e "${YELLOW}Cluster Information:${NC}"
if [ "$SKIP_SETUP" = false ]; then
    echo "Cluster name: kind-${CLUSTER_NAME}"
    echo "To delete: kind delete cluster --name ${CLUSTER_NAME}"
else
    echo "Using existing cluster: ${CLUSTER_NAME:-default}"
fi
