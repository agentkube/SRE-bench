# Kubernetes Manifests

This directory contains Kubernetes manifests for each SRE scenario, managed by ArgoCD.

## Structure

```
manifests/
├── scenario-1/          # Stale ConfigMap → Argo CD Drift → Application CrashLoopBackOff
│   ├── namespace.yaml
│   ├── configmap.yaml   # Intentionally missing 'new.feature' key
│   └── deployment.yaml
├── scenario-2/          # (To be added)
├── scenario-3/          # Node Pressure + HPA Misconfiguration → Evictions → Argo Rollback
│   ├── namespace.yaml
│   ├── deployment.yaml  # v1 - stable version
│   ├── service.yaml
│   └── hpa.yaml         # Intentionally misconfigured (minReplicas=5, CPU=20%)
├── scenario-4/          # NetworkPolicy Change → Service Mesh Timeout → API Chain Failure
│   ├── frontend/
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── backend/
│   │   ├── namespace.yaml
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   └── networkpolicy-allow.yaml  # Allows frontend → backend (initial state)
├── scenario-5/          # Misconfigured Autoscaler → Cost Spike → Emergency Shutdown
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── hpa.yaml         # DANGEROUSLY misconfigured (CPU=10%, maxReplicas=200)
└── scenario-6/          # ArgoCD Image Updater → Wrong Tag Match → Rollout Regression
    ├── namespace.yaml
    ├── configmap.yaml   # Config for v1.2.1-hotfix (includes new.feature.flag)
    ├── deployment.yaml  # Should be v1.2.1-hotfix
    └── service.yaml
```

## Scenario 1: Stale ConfigMap

The ConfigMap in this directory represents the **Git source of truth** for ArgoCD.

**Key Point:** The `configmap.yaml` is intentionally missing the `new.feature` key that the application requires. This simulates a stale configuration in Git that hasn't been updated after a code change.

### ArgoCD Application

The scenario script creates an ArgoCD Application that:
- Points to: `https://github.com/agentkube/SRE-bench.git`
- Path: `manifests/scenario-1`
- Branch: `main` (or `dev`)

### Scenario Flow

1. **Initial Deploy:** ArgoCD deploys from Git → Pods crash (missing `new.feature`)
2. **Manual Hotfix:** Engineer patches ConfigMap in cluster → Pods work
3. **ArgoCD Drift:** ArgoCD detects drift between Git and cluster
4. **Rollback:** ArgoCD syncs back to Git state → Pods crash again

### How to Fix

Update `configmap.yaml` to include:

```yaml
data:
  new.feature: "enabled"
```

Commit, push, and sync ArgoCD.

---

## Scenario 3: Node Pressure + HPA Misconfiguration

The manifests in this directory represent the **stable v1 application** in Git.

**Key Points:**
- The `hpa.yaml` is intentionally misconfigured:
  - `minReplicas: 5` (too high - should be 2-3)
  - `averageUtilization: 20%` CPU (too low - should be 70-80%)
- This causes aggressive scaling that consumes excessive resources

### ArgoCD Application

The scenario script creates an ArgoCD Application that:
- Points to: `https://github.com/agentkube/SRE-bench.git`
- Path: `manifests/scenario-3`
- Branch: `main` (or `dev`)

### Scenario Flow

1. **Initial Deploy:** ArgoCD deploys v1 from Git → HPA aggressively scales to 5 replicas
2. **Manual v2 Deploy:** Engineer deploys v2 with memory leak (bypassing GitOps) → OOMKilled pods
3. **Node Pressure:** High replica count + memory leak → Node memory pressure
4. **ArgoCD Rollback:** ArgoCD detects failures → Syncs back to Git v1
5. **Degraded State:** v1 has deprecated dependency issue → Partial functionality

### How to Fix

Update `hpa.yaml` to proper values:

```yaml
spec:
  minReplicas: 2  # Change from 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70  # Change from 20
```

Commit, push, and sync ArgoCD.

---

## Scenario 4: NetworkPolicy Change → Service Mesh Timeout → API Chain Failure

The manifests represent a **microservices architecture** with frontend and backend in separate namespaces.

**Key Points:**
- Frontend service in `frontend` namespace needs to call backend `auth-service` in `backend` namespace
- `networkpolicy-allow.yaml` allows this communication (initial state in Git)
- Script simulates a security engineer applying a **restrictive NetworkPolicy** that blocks all traffic

### ArgoCD Applications

The scenario script creates TWO ArgoCD Applications:
1. **web-frontend**: Points to `manifests/scenario-4/frontend`
2. **auth-backend**: Points to `manifests/scenario-4/backend`

### Scenario Flow

1. **Initial Deploy:** ArgoCD deploys frontend + backend → Services communicate successfully
2. **NetworkPolicy Applied:** Initial policy from Git allows frontend → backend traffic
3. **Security Update:** Script applies restrictive policy (deny-all-ingress) → Blocks communication
4. **Connection Failures:** Frontend cannot reach backend → 504 Gateway Timeout errors
5. **Retry Storms:** Frontend retry logic causes cascading load
6. **API Chain Failure:** Service dependency broken → Complete outage

### How to Fix

**Option 1: Delete restrictive policy**
```bash
kubectl delete networkpolicy deny-all-ingress -n backend
```

**Option 2: Update to allow required traffic (GitOps way)**
```bash
kubectl apply -f manifests/scenario-4/networkpolicy-allow.yaml
```

**Option 3: Test connectivity**
```bash
kubectl exec -it -n frontend <pod-name> -- nc -zv auth-service.backend.svc.cluster.local 8080
```

---

## Scenario 5: Misconfigured Autoscaler → Cost Spike → Emergency Shutdown

The manifests in this directory demonstrate a **catastrophically misconfigured HPA** that causes runaway scaling.

**Key Points:**
- The `hpa.yaml` has DANGEROUS settings:
  - `averageUtilization: 10%` CPU (way too low - should be 70-80%)
  - `maxReplicas: 200` (no reasonable limit)
  - `stabilizationWindowSeconds: 0` (instant scaling, no smoothing)
  - `scaleUp: 100% every 15 seconds` (doubles pods rapidly)
- Even minimal CPU usage will exceed 10% threshold
- HPA will aggressively scale: 3 → 6 → 12 → 24 → 48 → 96...

### ArgoCD Application

The scenario script creates an ArgoCD Application that:
- Points to: `https://github.com/agentkube/SRE-bench.git`
- Path: `manifests/scenario-5`
- Branch: `main` (or `dev`)

### Scenario Flow

1. **Initial Deploy:** ArgoCD deploys from Git with misconfigured HPA → 3 replicas
2. **Normal Operation:** Application runs with minimal CPU usage (10-15%)
3. **Aggressive Scaling:** HPA sees usage > 10% target → Starts scaling up rapidly
4. **Runaway Growth:** Replica count: 3 → 6 → 12 → 24 → 48 → 96+
5. **Cost Spike:** In cloud, would trigger 50-100+ new nodes → $$$
6. **Budget Alert:** Cost monitoring detects anomaly
7. **Emergency Shutdown:** Budget policy forces scale-down to 5 replicas
8. **Service Disruption:** Abrupt scale-down causes pod terminations

### Cost Impact (Simulated)

**Before:**
- 3 replicas
- 1 node
- ~$100/month

**After Misconfiguration:**
- 50-100+ replicas (trending to 200)
- 30-60 nodes needed
- ~$5,000/month (50x increase!)
- Incident cost: $50-100 for 15-30 minutes

### How to Fix

Update `hpa.yaml` to proper values:

```yaml
spec:
  minReplicas: 3
  maxReplicas: 10  # Reasonable limit
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70  # Realistic threshold
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60  # Add stabilization
      policies:
      - type: Percent
        value: 50  # More conservative
        periodSeconds: 60
```

Commit, push, and sync ArgoCD.

---

## Scenario 6: ArgoCD Image Updater → Wrong Tag Match → Rollout Regression

The manifests represent an **API service running v1.2.1-hotfix** with configuration that matches this version.

**Key Points:**
- Deployment should use image tag `v1.2.1-hotfix` (hotfix for critical bug in v1.2)
- ConfigMap includes `new.feature.flag` required by v1.2.1-hotfix
- ArgoCD Image Updater has **misconfigured regex pattern**
- Pattern incorrectly matches `v1.2` instead of `v1.2.1-hotfix`
- v1.2 contains the bug that v1.2.1-hotfix fixed!

### ArgoCD Application

The scenario script creates an ArgoCD Application that:
- Points to: `https://github.com/agentkube/SRE-bench.git`
- Path: `manifests/scenario-6`
- Branch: `main` (or `dev`)
- Includes Image Updater annotations (simulated)

### Scenario Flow

1. **Initial State:** ArgoCD deploys v1.2.1-hotfix from Git → Application healthy
2. **Image Updater Runs:** Checks for new image tags with semver pattern
3. **Wrong Tag Selected:** Regex matches v1.2 instead of v1.2.1-hotfix (older version!)
4. **Auto-Sync:** ArgoCD updates deployment to v1.2
5. **Regression:** v1.2 has critical bug that was fixed in v1.2.1-hotfix
6. **Pods Fail:** New pods fail readiness probes due to bug
7. **Rollout Stuck:** Half pods running v1.2.1-hotfix (old), half failing on v1.2 (new/wrong)
8. **Degraded Service:** Partial outage with inconsistent state

### Image Tag Problem

**Available tags:**
- `v1.2.1-hotfix` ✓ (current, correct - has bug fix)
- `v1.2` ✗ (older - has critical bug)
- `v1.1` (even older)

**Image Updater Regex:**
- Configured: `^v1.2.*` (too broad!)
- Matches: `v1.2` (wrong!)
- Should match: `v1.2.1-hotfix` (correct!)

**Better regex patterns:**
```
^v1\.2\.1-hotfix$           # Exact match
^v1\.2\.[0-9]+-.*$          # Semver with suffix
^v1\.2\.[0-9]+(-[a-z]+)?$   # Optional suffix
```

### How to Fix

**Option 1: Rollback to correct image**
```bash
kubectl set image deployment/api-service api=nginx:1.21 -n app-prod
```

**Option 2: Fix Image Updater pattern**
1. Update ArgoCD Image Updater configuration
2. Use strict pattern: `^v1\.2\.1-hotfix$`
3. Test against available tags
4. Re-sync ArgoCD

**Option 3: Disable Image Updater**
```bash
kubectl annotate deployment api-service -n app-prod \
  argocd-image-updater.argoproj.io/image-list-
```

### Prevention

- Use strict semantic versioning patterns
- Test regex against all possible tag formats
- Require manual approval for production
- Use immutable tags or SHA digests
- Implement canary deployments
- Set up alerts for unexpected image changes

---

## Usage with ArgoCD

```bash
# View application status
kubectl get applications -n argocd

# Check sync status
kubectl describe application demo-app -n argocd

# Trigger manual sync
kubectl patch application demo-app -n argocd --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'
```
