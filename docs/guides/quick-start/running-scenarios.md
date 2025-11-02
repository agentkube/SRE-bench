# Running Scenarios

This guide explains how to execute SRE-bench scenarios and what to expect during each run.

## Prerequisites

Before running scenarios, ensure you have:

- **kubectl** - Kubernetes command-line tool
- **kind** - Kubernetes in Docker (for creating test clusters)
- **Docker** - Container runtime (required by Kind)
- **Git** - For cloning the repository

### Installing Prerequisites

**macOS:**
```bash
# Install Homebrew if not already installed
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install tools
brew install kubectl kind
```

**Linux:**
```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# kind
curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
```

**Windows (PowerShell):**
```powershell
# Using Chocolatey
choco install kubernetes-cli kind

# Or using Scoop
scoop install kubectl kind
```

## Quick Start

The simplest way to run a scenario:

```bash
# Clone the repository
git clone https://github.com/siddhantprateek/SRE-bench.git
cd SRE-bench

# Make script executable (if needed)
chmod +x scripts/1_scenerio.sh

# Run scenario 1
./scripts/1_scenerio.sh
```

This will:
1. Create a new Kind cluster named `scenario-1-cluster`
2. Install ArgoCD
3. Deploy the application
4. Trigger the ConfigMap drift failure
5. Show you the cascading failure
6. Offer to clean up the cluster

## Execution Modes

Each scenario script supports multiple execution modes:

### Mode 1: New Kind Cluster (Default)

Creates a fresh Kind cluster for the scenario:

```bash
./scripts/1_scenerio.sh
```

**When to use:**
- First time running the scenario
- Want complete isolation
- Testing from scratch
- Developing/debugging scenarios

**Cleanup:**
The script will offer to delete the cluster at the end.

### Mode 2: Existing Cluster

Use your existing Kubernetes cluster:

```bash
./scripts/1_scenerio.sh --cluster
```

**When to use:**
- Testing on existing infrastructure
- Running multiple scenarios sequentially
- Using managed Kubernetes (EKS, GKE, AKS)
- Want to preserve the cluster for investigation

**Cleanup:**
The script will offer to delete only the namespace.

### Mode 3: Custom Kubeconfig

Target a specific cluster with custom kubeconfig:

```bash
./scripts/1_scenerio.sh --cluster --kubeconfig ~/.kube/my-cluster-config
```

**When to use:**
- Multiple kubeconfig files
- Testing on remote clusters
- CI/CD environments
- Multi-cluster setups

## Available Scenarios

Here's a quick reference of all scenarios:

| Script | Scenario | Components | Duration |
|--------|----------|------------|----------|
| `1_scenerio.sh` | ConfigMap Drift → CrashLoopBackOff | ArgoCD | ~5 min |
| `2_scenerio.sh` | Secret Rotation → Database Auth Failure | None | ~4 min |
| `3_scenerio.sh` | Node Pressure + HPA → Evictions | ArgoCD, Metrics Server | ~8 min |
| `4_scenerio.sh` | NetworkPolicy → Service Mesh Timeout | ArgoCD | ~6 min |
| `5_scenerio.sh` | Autoscaler Cost Spike | ArgoCD, Metrics Server | ~7 min |
| `6_scenerio.sh` | Image Updater Wrong Tag | ArgoCD | ~5 min |
| `7_scenerio.sh` | Redis Failover → Connection Leaks | None | ~6 min |
| `8_scenerio.sh` | Argo Rollout Canary Misconfiguration | ArgoCD, Argo Rollouts | ~8 min |
| `10_scenerio.sh` | API Rate Limit → HPA Misfire | Metrics Server | ~6 min |

## Step-by-Step Walkthrough

Let's walk through running Scenario 1 in detail:

### Step 1: Start the Scenario

```bash
./scripts/1_scenerio.sh
```

You'll see:
```
========================================
Scenario 1: ConfigMap Drift
========================================

========================================
Checking Prerequisites
========================================

✓ All prerequisites satisfied
```

### Step 2: Cluster Creation

The script creates a Kind cluster:

```
========================================
Creating Kind Cluster
========================================

Creating cluster "scenario-1-cluster" ...
 ✓ Ensuring node image (kindest/node:v1.27.3)
 ✓ Preparing nodes
 ✓ Writing configuration
 ✓ Starting control-plane
 ✓ Installing CNI
 ✓ Installing StorageClass
✓ Cluster created successfully
```

### Step 3: Component Installation

ArgoCD is installed automatically:

```
========================================
Installing ArgoCD
========================================

ℹ Waiting for ArgoCD to be ready...
deployment.apps/argocd-server condition met
✓ ArgoCD installed successfully
```

### Step 4: Initial Deployment

The stable application is deployed:

```
========================================
Deploying Application via ArgoCD
========================================

application.argoproj.io/demo-app created
ℹ Waiting for ArgoCD to sync...
✓ Application deployed via ArgoCD
```

### Step 5: Observe Stable State

The script shows the working application:

```
========================================
Observing Initial State
========================================

ℹ Application Status:
NAME      SYNC STATUS   HEALTH STATUS
demo-app  Synced        Healthy

ℹ Pod Status:
NAME                        READY   STATUS    RESTARTS   AGE
demo-app-7d4b8c9f5d-abcde   1/1     Running   0          30s
demo-app-7d4b8c9f5d-fghij   1/1     Running   0          30s
```

### Step 6: Interactive Pause

```
Press Enter to apply hotfix (this will create drift)...
```

Press Enter to continue and trigger the failure.

### Step 7: Failure Demonstration

The script shows the cascading failure:

```
========================================
Demonstrating Drift and Rollback
========================================

⚠ Hotfix applied directly to cluster (bypassing GitOps)
✓ ConfigMap updated with new.feature key

ℹ ArgoCD detecting drift in 30 seconds...
⚠ DRIFT DETECTED
⚠ ArgoCD will auto-sync and remove the hotfix!

ℹ Watching pod status during rollback...
NAME                        READY   STATUS                  RESTARTS   AGE
demo-app-7d4b8c9f5d-abcde   0/1     CreateContainerConfigError   0          2m
demo-app-7d4b8c9f5d-fghij   0/1     CrashLoopBackOff        1          2m

✗ Pods are now crashing!
✗ Missing required environment variable: new.feature
```

### Step 8: Impact Summary

The script shows the incident details:

```
========================================
Impact Summary
========================================

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         PRODUCTION INCIDENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Severity: P1 - Service Degradation
Error Rate: 100% (all pods failing)
Root Cause: ConfigMap drift - manual hotfix reverted by ArgoCD
Trigger: Engineer applied config change bypassing GitOps

Timeline:
  T+0s:   Manual hotfix applied to ConfigMap
  T+30s:  Pods start using new configuration
  T+60s:  ArgoCD detects drift
  T+90s:  ArgoCD auto-sync reverts ConfigMap
  T+120s: Pods restart and fail (missing new.feature)

Detection Signals:
  • CrashLoopBackOff pod status
  • ArgoCD drift warnings
  • Application health checks failing
  • Missing environment variable errors in logs

Prevention:
  1. Always commit changes to Git first
  2. Use ArgoCD self-heal carefully
  3. Set up drift alerts
  4. Document emergency hotfix procedures
  5. Use ConfigMap validation
```

### Step 9: Cleanup

```
========================================
Cleanup
========================================

Delete cluster scenario-1-cluster? (y/N)
```

Type `y` to delete the cluster or `N` to keep it for investigation.

## Observing Scenarios

While scenarios run, you can open additional terminals to observe:

### Watch Pods

```bash
# In another terminal
export KUBECONFIG="$(kind get kubeconfig --name scenario-1-cluster)"
watch kubectl get pods -A
```

### View Logs

```bash
# Watch application logs
kubectl logs -n demo-app -l app=demo-app -f

# Watch ArgoCD application status
kubectl get applications -n argocd -w
```

### Check ArgoCD UI

```bash
# Port-forward ArgoCD server
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d

# Open browser to https://localhost:8080
# Username: admin
# Password: (from command above)
```

## Troubleshooting

### Scenario Fails to Start

**Issue:** `kind: command not found`

**Solution:**
```bash
# Install Kind
brew install kind  # macOS
# or follow installation instructions for your OS
```

**Issue:** `Docker daemon not running`

**Solution:**
```bash
# Start Docker Desktop (macOS/Windows)
# or start Docker daemon (Linux)
sudo systemctl start docker
```

### Cluster Creation Hangs

**Issue:** Cluster creation stuck at "Preparing nodes"

**Solution:**
```bash
# Delete and retry
kind delete cluster --name scenario-1-cluster
./scripts/1_scenerio.sh
```

### ArgoCD Installation Times Out

**Issue:** `waiting for ArgoCD to be ready... timeout`

**Solution:**
```bash
# Check pod status
kubectl get pods -n argocd

# If pods are pending, check node resources
kubectl describe nodes

# Restart the scenario with more resources
kind delete cluster --name scenario-1-cluster
# Edit scripts/kind.yaml to increase resources if needed
./scripts/1_scenerio.sh
```

### Port Conflicts

**Issue:** `port is already allocated`

**Solution:**
```bash
# Find and kill process using the port
lsof -ti:8080 | xargs kill -9

# Or use a different port
kubectl port-forward svc/argocd-server -n argocd 8888:443
```

## Running Multiple Scenarios

You can run scenarios sequentially on the same cluster:

```bash
# Create a persistent cluster
kind create cluster --name sre-bench-cluster

# Run scenarios using the existing cluster
./scripts/1_scenerio.sh --cluster
./scripts/3_scenerio.sh --cluster
./scripts/4_scenerio.sh --cluster

# Each scenario will:
# - Use the existing cluster
# - Install any missing components
# - Create its own namespace
# - Clean up its namespace when done

# Delete the cluster when finished
kind delete cluster --name sre-bench-cluster
```

## CI/CD Integration

Scenarios can be used in automated testing:

```yaml
# .github/workflows/test-scenarios.yml
name: Test SRE Scenarios

on: [push, pull_request]

jobs:
  test-scenarios:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Install Kind
        run: |
          curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
          chmod +x ./kind
          sudo mv ./kind /usr/local/bin/kind

      - name: Run Scenario 1
        run: ./scripts/1_scenerio.sh

      - name: Run Scenario 7
        run: ./scripts/7_scenerio.sh
```

## Agent Testing

To test an autonomous agent against scenarios:

```bash
# Start scenario but don't trigger failure yet
# (modify script to pause before failure injection)

# Let your agent diagnose and remediate
your-agent diagnose --namespace demo-app

# Compare agent actions against expected remediation
```

## Next Steps

- **[Architecture Overview](architecture.md)** - Understand how scenarios are structured
- **[Contributing](contributing.md)** - Create your own scenarios
- **[Scenario Details](../../../scenerio/README.md)** - Deep dive into each scenario
