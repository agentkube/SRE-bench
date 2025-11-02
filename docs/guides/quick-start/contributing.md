# Contributing to SRE-bench

Thank you for your interest in contributing to SRE-bench! This guide will help you create and submit new scenarios to the benchmark.

## Why Contribute?

- **Share Knowledge** - Help others learn from real-world incidents you've experienced
- **Improve Agent Testing** - Add diverse scenarios to make agent benchmarks more comprehensive
- **Build Community** - Collaborate with SRE and AI practitioners
- **Test Your Own Agents** - Create scenarios that reflect your specific use cases

## What Makes a Good Scenario?

A good SRE-bench scenario should be:

1. **Realistic** - Based on actual production incidents or common failure patterns
2. **Reproducible** - Runs consistently across different environments
3. **Educational** - Teaches something valuable about Kubernetes or SRE practices
4. **Observable** - Has clear detection signals and symptoms
5. **Cascading** - Shows how a single issue can propagate through the system
6. **Remediable** - Has a clear path to resolution

## Scenario Template

Each scenario needs four components:

1. **Kubernetes Manifests** - Resources that reproduce the failure
2. **Executable Script** - Bash script that orchestrates the scenario
3. **Documentation** - Detailed description in the scenario README
4. **Testing** - Verification that it works in both new and existing clusters

## Step-by-Step Guide

### Step 1: Choose Your Scenario

Think about:
- What real-world incidents have you experienced?
- What failure modes are commonly misunderstood?
- What agent capabilities do you want to test?

**Example Scenarios:**
- PersistentVolume storage exhaustion causing pod evictions
- Ingress misconfiguration causing routing loops
- Service mesh mTLS cert expiration causing connection failures
- etcd performance degradation causing API server slowness

### Step 2: Create Manifest Directory

```bash
# Create directory for your scenario
mkdir -p manifests/scenario-N/

# Where N is the next available scenario number
# Check existing scenarios first:
ls manifests/
```

### Step 3: Write Kubernetes Manifests

Create the resources needed to reproduce the failure:

```yaml
# manifests/scenario-N/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: your-scenario-namespace
  labels:
    scenario: "N"
```

```yaml
# manifests/scenario-N/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: your-app
  namespace: your-scenario-namespace
spec:
  replicas: 3
  selector:
    matchLabels:
      app: your-app
  template:
    metadata:
      labels:
        app: your-app
    spec:
      containers:
      - name: app
        image: busybox:latest
        command: ["/bin/sh", "-c"]
        args:
          - |
            # Your application logic here
            # Include the failure condition
            echo "Application starting..."
            while true; do
              # Simulate work
              sleep 5
            done
```

**Key Principles:**
- Use lightweight images (busybox, alpine) for faster startup
- Include comments explaining the intentional misconfiguration
- Add logging to demonstrate the failure
- Use realistic resource requests/limits
- Include health checks (readiness/liveness probes)

### Step 4: Create Scenario Script

Copy an existing script as a template:

```bash
# Use scenario 1 as a template
cp scripts/1_scenerio.sh scripts/N_scenerio.sh

# Make it executable
chmod +x scripts/N_scenerio.sh
```

**Script Structure:**

```bash
#!/bin/bash

###############################################################################
# Scenario N: [Brief Title]
#
# This scenario demonstrates:
# 1. [Key point 1]
# 2. [Key point 2]
# 3. [Key point 3]
#
# Primary Trigger: [What initiates the failure]
# Propagation: [How it cascades]
# Impact: [Service disruption]
###############################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CLUSTER_NAME="scenario-N-cluster"
NAMESPACE="your-scenario-namespace"
GIT_REPO="https://github.com/siddhantprateek/SRE-bench"
GIT_BRANCH="main"
MANIFEST_PATH="manifests/scenario-N"

# Parse command line arguments
USE_EXISTING_CLUSTER=false
KUBECONFIG_PATH=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster)
      USE_EXISTING_CLUSTER=true
      shift
      ;;
    --kubeconfig)
      KUBECONFIG_PATH="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--cluster] [--kubeconfig PATH]"
      exit 1
      ;;
  esac
done

if [ -n "$KUBECONFIG_PATH" ]; then
  export KUBECONFIG="$KUBECONFIG_PATH"
fi

# Utility functions
print_header() {
  echo -e "\n${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}\n"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

# Main functions
check_prerequisites() {
  print_header "Checking Prerequisites"
  # Check for required tools
  print_success "All prerequisites satisfied"
}

create_cluster() {
  if $USE_EXISTING_CLUSTER; then
    print_header "Using Existing Cluster"
    kubectl cluster-info
    return
  fi

  print_header "Creating Kind Cluster"
  # Create Kind cluster
  print_success "Cluster created successfully"
}

deploy_initial_state() {
  print_header "Deploying Initial State"
  # Deploy application in healthy state
  print_success "Initial deployment complete"
}

trigger_failure() {
  print_header "Triggering Failure Condition"
  # Apply misconfiguration or inject fault
  print_error "Failure condition triggered"
}

observe_impact() {
  print_header "Observing Impact"
  # Show logs, pod status, metrics
  print_error "Demonstrating cascading failure"
}

show_impact() {
  print_header "Impact Summary"
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${RED}         PRODUCTION INCIDENT          ${NC}"
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  # Incident details, timeline, prevention tips
}

cleanup() {
  print_header "Cleanup"
  # Offer to delete cluster or namespace
}

main() {
  print_header "Scenario N: [Your Scenario Title]"

  check_prerequisites
  create_cluster
  deploy_initial_state

  echo ""
  read -p "Press Enter to trigger failure condition..."
  echo ""

  trigger_failure
  observe_impact
  show_impact
  cleanup

  print_header "Scenario Complete"
}

main
```

**Important Considerations:**
- Support both `--cluster` and `--kubeconfig` flags
- Use color-coded output for readability
- Include interactive pauses at key moments
- Show clear detection signals
- Provide actionable remediation steps
- Offer cleanup options

### Step 5: Document the Scenario

Add your scenario to [scenerio/README.md](../../../scenerio/README.md):

```markdown
## N. [Scenario Title]

### Primary Trigger
[What initiates the failure - be specific]

### Propagation Path
1. **[Step 1]**: [Description]
2. **[Step 2]**: [Description]
3. **[Step 3]**: [Description]
4. **[Final Impact]**: [Description]

### Impact
- [Impact 1]
- [Impact 2]
- [Impact 3]

### Detection Signals
- [Signal 1]
- [Signal 2]
- [Signal 3]

### Mitigation Steps
1. [Step 1]
2. [Step 2]
3. [Step 3]

### Prevention
- [Best practice 1]
- [Best practice 2]
- [Best practice 3]

### Related Scenarios
- Scenario X: [Related scenario]

### Real-World Examples
- [Optional: Link to postmortem or incident report]
```

### Step 6: Test Your Scenario

Test thoroughly in multiple modes:

```bash
# Test with new Kind cluster
./scripts/N_scenerio.sh

# Test with existing cluster
kind create cluster --name test-cluster
./scripts/N_scenerio.sh --cluster
kind delete cluster --name test-cluster

# Test with custom kubeconfig
./scripts/N_scenerio.sh --cluster --kubeconfig ~/.kube/config
```

**Checklist:**
- [ ] Script runs without errors
- [ ] Failure condition is clearly demonstrated
- [ ] Detection signals are observable
- [ ] Cleanup works properly
- [ ] Works in both new and existing clusters
- [ ] All required components are installed
- [ ] Logs are informative and color-coded
- [ ] Interactive pauses make sense
- [ ] Impact summary is comprehensive

### Step 7: Submit Pull Request

```bash
# Create a new branch
git checkout -b scenario-N-your-scenario-name

# Add your files
git add manifests/scenario-N/
git add scripts/N_scenerio.sh
git add scenerio/README.md

# Commit with descriptive message
git commit -m "Add Scenario N: [Your Scenario Title]

- Demonstrates [key failure mode]
- Includes [components used]
- Tests [agent capability]
"

# Push to your fork
git push origin scenario-N-your-scenario-name

# Open PR on GitHub
```

**PR Description Template:**
```markdown
## Scenario N: [Your Scenario Title]

### Description
[Brief description of the scenario and what it demonstrates]

### Failure Mode
- **Trigger**: [What causes it]
- **Impact**: [Service disruption]
- **Components**: [ArgoCD, HPA, etc.]

### Testing
- [x] Tested in new Kind cluster
- [x] Tested in existing cluster
- [x] Tested with custom kubeconfig
- [x] Documentation complete
- [x] Script follows conventions

### Related Issues
Closes #[issue-number] (if applicable)

### Screenshots/Logs
[Optional: Include example output]
```

## Scenario Design Patterns

### Pattern 1: GitOps Drift Scenario

**Use Case:** Configuration or deployment issues

```bash
# Deploy via ArgoCD
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: your-app
  namespace: argocd
spec:
  source:
    repoURL: ${GIT_REPO}
    targetRevision: ${GIT_BRANCH}
    path: ${MANIFEST_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
EOF
```

**When to Use:**
- Deployment strategy issues
- Configuration drift
- Image update problems
- Rollout failures

### Pattern 2: Runtime Failure Scenario

**Use Case:** Operational or infrastructure issues

```bash
# Direct kubectl apply
kubectl apply -f manifests/scenario-N/

# Trigger runtime failure
kubectl scale deployment app --replicas=0 -n ${NAMESPACE}
```

**When to Use:**
- Connection pool issues
- Resource pressure
- Monitoring failures
- Network problems

### Pattern 3: Resource Pressure Scenario

**Use Case:** Scaling or resource issues

```bash
# Install metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Create HPA with misconfiguration
kubectl apply -f manifests/scenario-N/hpa.yaml
```

**When to Use:**
- HPA misconfiguration
- Node pressure
- OOMKilled pods
- Cluster autoscaler issues

## Best Practices

### Manifest Design

1. **Use Comments**: Clearly mark intentional misconfigurations
2. **Realistic Resources**: Use production-like resource requests/limits
3. **Health Checks**: Include probes that will fail during the incident
4. **Logging**: Add verbose logging to show the failure progression
5. **Labels**: Use consistent labels for easier querying

### Script Design

1. **Prerequisites**: Check for all required tools
2. **Error Handling**: Use `set -e` and handle failures gracefully
3. **Progress Indicators**: Show what's happening at each step
4. **Timeouts**: Use reasonable timeouts for kubectl wait commands
5. **Cleanup**: Always offer cleanup options

### Documentation

1. **Clear Title**: Describe the failure mode concisely
2. **Propagation Path**: Show how the failure cascades
3. **Detection Signals**: List observable symptoms
4. **Prevention**: Include actionable best practices
5. **Related Scenarios**: Link to similar scenarios

## Getting Help

- **Questions**: Open a GitHub Discussion
- **Bugs**: Open a GitHub Issue
- **Ideas**: Start with a GitHub Discussion before implementing
- **Review**: Tag maintainers in your PR for review

## Code of Conduct

Please be:
- **Respectful** - Be kind to other contributors
- **Constructive** - Provide helpful feedback
- **Collaborative** - Work together to improve scenarios
- **Patient** - Reviews take time

## Recognition

Contributors will be:
- Listed in the repository contributors
- Credited in the scenario documentation
- Mentioned in release notes

Thank you for contributing to SRE-bench!
