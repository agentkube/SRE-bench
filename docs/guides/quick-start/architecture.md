# Architecture Overview

This document explains the structure and organization of the SRE-bench codebase.

## Project Structure

```
SRE-bench/
├── docs/                    # Documentation (you are here)
│   ├── guides/             # User guides
│   ├── images/             # Documentation images
│   └── scalar.config.json  # Scalar docs configuration
│
├── manifests/              # Kubernetes manifests for scenarios
│   ├── scenario-1/         # ConfigMap Drift scenario
│   ├── scenario-3/         # Node Pressure + HPA scenario
│   ├── scenario-4/         # NetworkPolicy scenario
│   ├── scenario-5/         # Autoscaler cost spike scenario
│   ├── scenario-6/         # Image updater wrong tag scenario
│   ├── scenario-7/         # Redis failover scenario
│   ├── scenario-8/         # Argo Rollout canary scenario
│   └── scenario-10/        # API rate limit scenario
│
├── scenerio/               # Scenario documentation
│   └── README.md           # Detailed scenario descriptions
│
└── scripts/                # Executable scenario scripts
    ├── 1_scenerio.sh       # Scenario 1 script
    ├── 2_scenerio.sh       # Scenario 2 script
    ├── 3_scenerio.sh       # Scenario 3 script
    ├── ...                 # Scenarios 4-10
    ├── kind.yaml           # Kind cluster configuration
    └── setup.sh            # Initial setup script
```

## Core Components

### 1. Scenario Scripts (`scripts/`)

Each scenario has an executable bash script that:
- Creates a Kind cluster (or uses an existing cluster with `--cluster` flag)
- Installs required components (ArgoCD, metrics-server, Argo Rollouts, etc.)
- Deploys the initial stable state
- Triggers the failure condition
- Demonstrates the cascading failure
- Shows detection signals and mitigation steps
- Provides cleanup options

**Key Features:**
- **Flexible Execution**: Run in new Kind cluster or existing Kubernetes cluster
- **Kubeconfig Support**: Use `--kubeconfig` flag to target specific clusters
- **Interactive Mode**: Scripts pause at key moments to let you observe the failure
- **Color-Coded Output**: Easy to follow success/error/warning messages

**Example:**
```bash
# Create new Kind cluster and run scenario
./scripts/1_scenerio.sh

# Use existing cluster
./scripts/1_scenerio.sh --cluster

# Use specific kubeconfig
./scripts/1_scenerio.sh --cluster --kubeconfig ~/.kube/config
```

### 2. Kubernetes Manifests (`manifests/`)

Each scenario directory contains the Kubernetes resources needed to reproduce the failure:

- **namespace.yaml** - Namespace definitions
- **deployment.yaml** - Application deployments
- **service.yaml** - Service definitions
- **configmap.yaml** - Configuration data
- **hpa.yaml** - Horizontal Pod Autoscaler configs
- **networkpolicy.yaml** - Network policies
- **rollout.yaml** - Argo Rollout definitions
- **analysis-template.yaml** - Canary analysis templates

**GitOps Integration:**
Scenarios that involve deployment/configuration issues use ArgoCD Applications that point to these manifests in the Git repository, demonstrating real GitOps workflows.

### 3. Scenario Documentation (`scenerio/`)

The [scenario README](../../../scenerio/README.md) contains detailed descriptions of all 10 scenarios including:

- **Primary Trigger** - What initiates the failure
- **Propagation Path** - How the failure cascades
- **Impact** - Service disruption and business impact
- **Detection Signals** - What alerts and symptoms appear
- **Mitigation Steps** - How to resolve the incident
- **Prevention** - Best practices to avoid the issue

## Scenario Categories

Scenarios are categorized by their nature:

### GitOps/Deployment Scenarios (Use ArgoCD)

These scenarios involve configuration drift, deployment issues, or GitOps workflows:

- **Scenario 1**: Stale ConfigMap → ArgoCD Drift → CrashLoopBackOff
- **Scenario 3**: Node Pressure + HPA → Evictions → Argo Rollback
- **Scenario 4**: NetworkPolicy Change → Service Mesh Timeout
- **Scenario 5**: Misconfigured Autoscaler → Cost Spike
- **Scenario 6**: ArgoCD Image Updater → Wrong Tag Match
- **Scenario 8**: Argo Rollout Canary + Wrong Weighting → Full Outage

**Pattern**: These scenarios create ArgoCD Applications that sync from the Git repository.

### Runtime/Infrastructure Scenarios (Direct kubectl)

These scenarios involve runtime failures, infrastructure issues, or monitoring problems:

- **Scenario 2**: Expired Secret Rotation → Database Auth Failures
- **Scenario 7**: Redis Failover → Connection Leaks → Resource Pressure
- **Scenario 10**: Throttled API Limits → Prometheus Scrape Failures → HPA Misfires

**Pattern**: These scenarios use direct `kubectl apply` as they demonstrate operational issues, not deployment/configuration drift.

## Component Dependencies

Different scenarios require different Kubernetes components:

| Component | Scenarios | Purpose |
|-----------|-----------|---------|
| **ArgoCD** | 1, 3, 4, 5, 6, 8 | GitOps continuous delivery |
| **Argo Rollouts** | 8 | Advanced deployment strategies (canary, blue-green) |
| **Metrics Server** | 3, 5, 10 | Resource metrics for HPA |
| **NetworkPolicy** | 4 | Network isolation and security |
| **HPA** | 3, 5, 10 | Horizontal pod autoscaling |

Scripts automatically install required components if not present.

## Execution Flow

Each scenario follows this general flow:

```
1. Prerequisites Check
   ├─> kubectl installed?
   ├─> kind installed? (if creating cluster)
   └─> Other tools as needed

2. Cluster Setup
   ├─> Create Kind cluster (or use existing)
   └─> Verify cluster connectivity

3. Component Installation
   ├─> Install ArgoCD (if needed)
   ├─> Install Argo Rollouts (if needed)
   ├─> Install Metrics Server (if needed)
   └─> Wait for components to be ready

4. Initial Deployment
   ├─> Create namespace
   ├─> Deploy stable version
   ├─> Create ArgoCD Application (if applicable)
   └─> Verify healthy state

5. Failure Trigger
   ├─> Apply misconfiguration
   ├─> Trigger drift
   ├─> Inject failure
   └─> Start monitoring

6. Observation Phase
   ├─> Show logs
   ├─> Display pod status
   ├─> Demonstrate cascading failures
   └─> Highlight detection signals

7. Impact Summary
   ├─> Show incident timeline
   ├─> List detection signals
   ├─> Explain root cause
   └─> Provide prevention tips

8. Cleanup (Optional)
   ├─> Delete namespace (existing cluster)
   └─> Delete cluster (Kind)
```

## Configuration Files

### Kind Configuration (`scripts/kind.yaml`)

Defines the Kind cluster topology:
- Control plane node
- Multiple worker nodes
- Port mappings for services

### Scalar Configuration (`docs/scalar.config.json`)

Configures the documentation website:
- Subdomain and custom domain
- Sidebar navigation structure
- Theme and branding
- Guide organization

## Extending the Benchmark

To add a new scenario:

1. **Create manifest directory**: `manifests/scenario-N/`
2. **Add Kubernetes manifests**: Define resources that reproduce the failure
3. **Write scenario script**: `scripts/N_scenerio.sh` following the established pattern
4. **Document the scenario**: Add detailed description to `scenerio/README.md`
5. **Test thoroughly**: Verify scenario runs in both new and existing clusters

See the [Contributing Guide](contributing.md) for detailed instructions.

## Design Principles

1. **Reproducibility** - Scenarios run consistently across environments
2. **Isolation** - Each scenario is self-contained
3. **Flexibility** - Support both new Kind clusters and existing clusters
4. **Realism** - Scenarios reflect real-world production failures
5. **Observability** - Clear detection signals and symptoms
6. **Educational** - Include explanations and best practices
7. **Automation-Friendly** - Scripts can be used for automated agent testing
