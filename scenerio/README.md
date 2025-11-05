# SRE Failure Scenarios

This document contains 16 real-world SRE incident scenarios designed for training, testing, and RCA (Root Cause Analysis) practice. Each scenario simulates cascading failures common in Kubernetes, GitOps, and cloud-native environments.

---

## Table of Contents

1. [Stale ConfigMap -> Argo CD Drift -> Application CrashLoopBackOff](#1-stale-configmap--argo-cd-drift--application-crashloopbackoff)
2. [Expired Secret Rotation -> Database Auth Failures -> API Downtime](#2-expired-secret-rotation--database-auth-failures--api-downtime)
3. [Node Pressure + HPA Misconfiguration -> Evictions -> Argo Rollback](#3-node-pressure--hpa-misconfiguration--evictions--argo-rollback)
4. [NetworkPolicy Change -> Service Mesh Timeout -> API Chain Failure](#4-networkpolicy-change--service-mesh-timeout--api-chain-failure)
5. [Misconfigured Autoscaler -> Cost Spike -> Cluster Autoscaler Backoff](#5-misconfigured-autoscaler--cost-spike--cluster-autoscaler-backoff)
6. [ArgoCD Image Updater -> Wrong Tag Match -> Rollout Regression](#6-argocd-image-updater--wrong-tag-match--rollout-regression)
7. [Redis Failover -> Connection Leaks -> Node Resource Pressure](#7-redis-failover--connection-leaks--node-resource-pressure)
8. [Argo Rollout Canary + Wrong Weighting -> Full Outage](#8-argo-rollout-canary--wrong-weighting--full-outage)
9. [Cloud DNS TTL + Config Drift -> Multi-Cluster Routing Blackhole](#9-cloud-dns-ttl--config-drift--multi-cluster-routing-blackhole)
10. [Throttled API Rate Limits -> Prometheus Scrape Failures -> HPA Misfires](#10-throttled-api-rate-limits--prometheus-scrape-failures--hpa-misfires)
11. [ArgoCD Drift -> Secret Mismatch -> DB Connection Leak -> Node Pressure -> Prometheus Throttle -> Alert Delays](#11-argocd-drift--secret-mismatch--db-connection-leak--node-pressure--prometheus-throttle--alert-delays)
12. [Misconfigured HPA -> Cost Spike -> Cluster Autoscaler -> Throttled API -> ArgoCD Sync Failure -> Alertmanager Storm](#12-misconfigured-hpa--cost-spike--cluster-autoscaler--throttled-api--argocd-sync-failure--alertmanager-storm)
13. [NetworkPolicy Restriction -> Service Mesh Retry Storm -> DB Saturation -> Prometheus Lag -> Alert Suppression -> Partial Outage](#13-networkpolicy-restriction--service-mesh-retry-storm--db-saturation--prometheus-lag--alert-suppression--partial-outage)
14. [Postgres Schema Drift -> ORM Migration Failure -> API Crash -> Prometheus Missing Series -> Alert Flap -> Argo Rollback Loop](#14-postgres-schema-drift--orm-migration-failure--api-crash--prometheus-missing-series--alert-flap--argo-rollback-loop)
15. [Prometheus High Cardinality -> TSDB Corruption -> Metrics Drop -> Alert Delay -> Argo Rollout Overshoot -> DB Overload](#15-prometheus-high-cardinality--tsdb-corruption--metrics-drop--alert-delay--argo-rollout-overshoot--db-overload)
16. [Kube-API Slowdown -> Prometheus Scrape Failures -> Alert Silencing -> Cost Anomaly -> Cluster Node Eviction -> App Downtime](#16-kube-api-slowdown--prometheus-scrape-failures--alert-silencing--cost-anomaly--cluster-node-eviction--app-downtime)
17. [Combined Multi-Layer Scenarios](#bonus-combined-multi-layer-scenarios)

---

## 1. Stale ConfigMap -> Argo CD Drift -> Application CrashLoopBackOff

### Primary Trigger
A ConfigMap updated manually in the cluster but not synced in ArgoCD.

### Propagation Path
1. **Manual Hotfix**: DevOps engineer hotfixes app config directly in the cluster (bypassing GitOps)
2. **Drift Detection**: ArgoCD detects drift but auto-sync is disabled
3. **Forced Reconciliation**: Deployment rolls back due to ArgoCD's re-sync on next reconciliation
4. **Configuration Mismatch**: App now uses stale config missing new environment variable -> fails on startup

### Impact
- Pod crash loops
- Health checks fail
- SLO violations
- Application unavailability

### Detection Signals
- `CrashLoopBackOff` pod status
- ArgoCD drift warnings
- Application logs showing missing configuration
- Increased restart count in pods

### Mitigation Steps
1. Review ArgoCD drift reports
2. Identify the missing configuration in Git
3. Update the Git repository with the correct configuration
4. Sync ArgoCD application
5. Verify pod health and application functionality

### Prevention
- Enforce GitOps workflows with admission controllers
- Enable ArgoCD auto-sync with caution
- Implement configuration validation in CI/CD
- Use policy engines (OPA/Kyverno) to prevent manual changes

---

## 2. Expired Secret Rotation -> Database Auth Failures -> API Downtime

### Primary Trigger
Database credentials in a Kubernetes Secret expired.

### Propagation Path
1. **Silent Failure**: Secret auto-rotation job failed silently (CronJob misconfigured)
2. **Cached Credentials**: Apps kept using old secret cached by kubelet
3. **Connection Rejection**: Database rejects new connections
4. **Pool Exhaustion**: Connection pool exhaustion -> API pods crash -> 502s on ingress

### Impact
- Complete API outage
- Elevated latency
- Multiple alert cascades
- Customer-facing service disruption

### Detection Signals
- Database connection errors in application logs
- 502 Bad Gateway responses
- Connection pool exhaustion metrics
- Failed CronJob executions
- Authentication errors in database audit logs

### Mitigation Steps
1. Identify the expired credentials
2. Manually rotate secrets if automation failed
3. Restart affected pods to pick up new secrets
4. Verify database connectivity
5. Clear connection pools if necessary

### Prevention
- Monitor CronJob execution status
- Implement secret rotation alerts
- Use external secret management (Vault, AWS Secrets Manager)
- Set up pre-expiration warnings
- Test secret rotation in staging environments

---

## 3. Node Pressure + HPA Misconfiguration -> Evictions -> Argo Rollback

### Primary Trigger
Memory leak + wrong HPA thresholds.

### Propagation Path
1. **Memory Leak**: App starts leaking memory
2. **Scale-Up Block**: HPA scale-up blocked (minReplicas misconfigured)
3. **Node Pressure**: Node pressure causes Kubernetes to evict pods
4. **Auto-Rollback**: ArgoCD auto-rolls back last working version due to failing health checks
5. **Broken Rollback**: The rollback image had a deprecated dependency -> app becomes partially broken

### Impact
- Availability degraded
- Stability issues
- Recovery delayed due to Argo rollback loop
- Inconsistent application state

### Detection Signals
- Node memory pressure warnings
- Pod eviction events
- HPA unable to scale warnings
- ArgoCD rollback events
- OOMKilled containers

### Mitigation Steps
1. Identify memory leak source
2. Correct HPA configuration (minReplicas, maxReplicas, target utilization)
3. Add or scale nodes to relieve pressure
4. Fix the memory leak in application code
5. Deploy patched version through proper GitOps workflow

### Prevention
- Set proper resource requests and limits
- Configure HPA with realistic thresholds
- Implement memory profiling and leak detection
- Use Vertical Pod Autoscaler (VPA) for recommendations
- Test autoscaling behavior under load

---

## 4. NetworkPolicy Change -> Service Mesh Timeout -> API Chain Failure

### Primary Trigger
Updated NetworkPolicy restricts inter-namespace communication.

### Propagation Path
1. **Policy Update**: Security engineer tightens network policy to isolate staging from prod namespaces
2. **Connection Timeout**: Service mesh (Istio/Linkerd) sidecars timeout on cross-namespace calls
3. **Service Isolation**: Frontend services can't reach backend auth microservice
4. **Retry Storm**: Retry storms cause cascading latency and load on ingress

### Impact
- Partial outage with high error rates
- Customers see random 504 Gateway Timeout errors
- Service dependency failures
- Increased ingress load

### Detection Signals
- 504 Gateway Timeout errors
- Service mesh timeout metrics
- NetworkPolicy applied events
- Increased retry attempts in logs
- Distributed tracing showing broken service chains

### Mitigation Steps
1. Review recent NetworkPolicy changes
2. Identify blocked communication paths
3. Update NetworkPolicy to allow required traffic
4. Verify service mesh configuration
5. Test inter-service connectivity

### Prevention
- Test NetworkPolicy changes in staging
- Use network policy visualization tools
- Implement gradual rollout of security policies
- Document service dependencies and communication patterns
- Use service mesh observability for impact analysis

---

## 5. Misconfigured Autoscaler -> Cost Spike -> Cluster Autoscaler Backoff

### Primary Trigger
Wrong HPA target CPU utilization set to 10%.

### Propagation Path
1. **Aggressive Scaling**: Autoscaler aggressively scales replicas from 3 -> 200
2. **Node Explosion**: Cluster Autoscaler spins up >100 nodes in AWS/GCP
3. **Quota Exhaustion**: Cost monitoring tool throttles API due to quota exhaustion
4. **Emergency Shutdown**: Budget alert triggers emergency shutdown policy -> cluster scaled down abruptly

### Impact
- Production instability
- Massive billing spike
- Delayed reconciliation
- Potential quota limits hit
- Service disruption from emergency shutdown

### Detection Signals
- Abnormal replica count increase
- Node count spike
- Cloud provider quota warnings
- Cost anomaly alerts
- API throttling errors

### Mitigation Steps
1. Immediately correct HPA target thresholds
2. Manually scale down excess replicas
3. Drain and remove unnecessary nodes
4. Review and adjust budget policies
5. Implement gradual scale-down to avoid disruption

### Prevention
- Set realistic HPA metrics and thresholds (typically 70-80% CPU)
- Configure maxReplicas limits
- Implement cost guardrails and alerts
- Use cluster autoscaler limits (min/max nodes)
- Regular autoscaling configuration reviews

---

## 6. ArgoCD Image Updater -> Wrong Tag Match -> Rollout Regression

### Primary Trigger
Automated image updater matches wrong semantic tag.

### Propagation Path
1. **Wrong Tag Selection**: Image updater regex picks v1.2 instead of v1.2.1-hotfix
2. **Auto-Sync**: ArgoCD syncs and deploys the wrong container version
3. **Missing Configuration**: Newly deployed image lacks environment variable introduced in configmap
4. **Readiness Failure**: Application fails readiness probe, rollouts paused

### Impact
- Half of pods stuck in Pending/CrashLoopBackOff
- Inconsistent application state
- Degraded service availability
- Potential data inconsistency

### Detection Signals
- ArgoCD sync events with unexpected image tags
- Failed readiness probes
- Pod status showing CrashLoopBackOff
- Image tag mismatch in deployment vs expected version

### Mitigation Steps
1. Identify incorrect image tag
2. Update ArgoCD application to use correct image
3. Fix image updater regex pattern
4. Sync to correct version
5. Verify all pods are healthy

### Prevention
- Use strict semantic versioning patterns
- Implement image tag validation
- Require manual approval for production deployments
- Use immutable tags or SHA digests
- Test image updater patterns in staging

---

## 7. Redis Failover -> Connection Leaks -> Node Resource Pressure

### Primary Trigger
Redis master node restarted due to zone failure.

### Propagation Path
1. **Redis Failover**: Clients failover to replica but connection pool not reinitialized properly
2. **Connection Leak**: Old connections keep retrying -> file descriptor leak
3. **Resource Pressure**: Node memory + FD pressure increases
4. **Evictions**: Kubelet OOMKills non-critical pods -> observability stack degraded

### Impact
- Partial observability loss
- Rising latency
- Delayed RCA visibility
- Node instability
- Potential cascade to other services

### Detection Signals
- Redis connection errors
- File descriptor exhaustion warnings
- Node resource pressure events
- OOMKilled containers
- Missing metrics/logs from observability stack

### Mitigation Steps
1. Restart affected application pods to reset connection pools
2. Fix connection pool initialization logic
3. Scale observability stack back up
4. Add or scale nodes if needed
5. Review Redis client configuration

### Prevention
- Implement proper connection pool management
- Use Redis Sentinel or Redis Cluster for HA
- Monitor file descriptor usage
- Set connection pool limits and timeouts
- Test failover scenarios regularly

---

## 8. Argo Rollout Canary + Wrong Weighting -> Full Outage

### Primary Trigger
Canary weight misconfigured as 100% instead of 10%.

### Propagation Path
1. **Full Traffic Shift**: Argo Rollout shifts 100% of traffic to canary
2. **Schema Incompatibility**: Canary connects to new DB schema incompatible with production traffic
3. **Validation Failures**: All API calls fail schema validation
4. **Slow Rollback**: Rollback takes minutes due to controller stuck waiting for metrics provider (Prometheus) sync

### Impact
- Complete outage
- Severe customer impact
- Delayed metrics collection
- Extended recovery time
- Data validation errors

### Detection Signals
- 100% error rate spike
- Schema validation errors in logs
- Argo Rollout events showing unexpected weights
- Prometheus metrics showing full canary deployment
- Database schema mismatch errors

### Mitigation Steps
1. Immediately abort rollout
2. Manually shift traffic back to stable version
3. Rollback canary deployment
4. Fix canary weight configuration
5. Verify database schema compatibility

### Prevention
- Validate rollout configurations before applying
- Use progressive delivery with small initial weights (5-10%)
- Implement automated rollback based on error rates
- Test canary deployments in staging with production-like schemas
- Use analysis templates with short intervals

---

## 9. Cloud DNS TTL + Config Drift -> Multi-Cluster Routing Blackhole

### Primary Trigger
Ingress IP change in cluster A not propagated to cluster B.

### Propagation Path
1. **IP Change**: Multi-cluster setup with GSLB or ExternalDNS
2. **DNS Update Failure**: DNS record TTL 10m; update fails due to expired cloud provider credentials
3. **Stale Routing**: Clients route to old IP (nonexistent nodepool)
4. **No Failover**: Failover policy not triggered due to missing health checks

### Impact
- Random region unavailability
- Partial outage with difficult traceability
- Intermittent connectivity issues
- Customer experience degradation

### Detection Signals
- DNS resolution to incorrect IPs
- Connection timeout to specific regions
- ExternalDNS errors in logs
- Cloud provider authentication failures
- Health check failures not triggering failover

### Mitigation Steps
1. Update cloud provider credentials
2. Manually update DNS records
3. Verify health check configuration
4. Lower DNS TTL temporarily for faster propagation
5. Test failover mechanisms

### Prevention
- Monitor ExternalDNS operation status
- Use shorter DNS TTLs (1-5 minutes)
- Implement credential rotation automation
- Configure proper health checks for GSLB
- Test multi-cluster failover regularly

---

## 10. Throttled API Rate Limits -> Prometheus Scrape Failures -> HPA Misfires

### Primary Trigger
Prometheus scraping throttled by kube-apiserver rate limits.

### Propagation Path
1. **Rate Limiting**: API rate limit exceeded due to surge in metric queries
2. **Missed Scrapes**: Prometheus misses several scrape intervals
3. **Missing Metrics**: HPA based on those metrics sees no load -> scales down pods incorrectly
4. **Cascading Failure**: Underprovisioned app starts dropping requests; latency alerts trigger too late

### Impact
- Latency spike
- Error rate increase
- Incorrect scaling decisions
- Missing metrics for monitoring
- Delayed incident detection

### Detection Signals
- Prometheus scrape failure errors
- Kube-apiserver throttling logs
- HPA showing stale/missing metrics
- Unexpected scale-down events
- 429 Too Many Requests errors from API server

### Mitigation Steps
1. Increase kube-apiserver rate limits
2. Reduce Prometheus scrape frequency or cardinality
3. Manually scale up affected workloads
4. Add Prometheus federation or sharding
5. Review metric collection efficiency

### Prevention
- Monitor API server request rates
- Optimize Prometheus metric collection
- Use metric relabeling to reduce cardinality
- Implement Prometheus sharding for large clusters
- Set appropriate HPA evaluation intervals
- Use custom metrics from external sources

---

## 11. ArgoCD Drift -> Secret Mismatch -> DB Connection Leak -> Node Pressure -> Prometheus Throttle -> Alert Delays

### Primary Trigger
Manual patch to Deployment in the cluster bypassed ArgoCD sync.

### Propagation Path
1. **ArgoCD Drift**: Manual hotfix introduces a config mismatch (DB_PASSWORD changed in Secret)
2. **Secret Mismatch**: App restarts, can't connect to DB (stale connection credentials)
3. **DB Connection Leak**: Connection pool retries infinitely -> Postgres starts refusing new connections
4. **Node Pressure**: App pods consume CPU/memory on retry loop -> Kubelet starts OOM killing other pods
5. **Prometheus Scrapes Fail**: Kubelet metrics endpoint throttled; /metrics returns 500s
6. **Alertmanager Delay**: Alert thresholds missed; high latency alerts arrive 15 min late

### Impact
- Prometheus dashboards show stale data
- Delayed alerting and incident detection
- Database instability and connection exhaustion
- Application latency spike
- False sense of cluster health
- Node resource exhaustion affecting multiple workloads

### Detection Signals
- ArgoCD drift warnings
- Database connection pool exhaustion errors
- Application authentication failures
- OOMKilled containers
- Node resource pressure events
- Prometheus scrape failures
- Alert delivery delays in Alertmanager
- Kubelet /metrics endpoint errors

### Mitigation Steps
1. Identify and revert manual changes in cluster
2. Sync proper configuration through ArgoCD
3. Update Secret with correct database credentials
4. Restart affected application pods to reset connection pools
5. Scale up nodes if resource pressure persists
6. Verify Prometheus scrape health
7. Review and flush Alertmanager queue

### Prevention
- Enforce GitOps-only workflows with admission controllers (OPA/Kyverno)
- Enable ArgoCD drift detection with automated notifications
- Implement proper Secret rotation workflows
- Configure connection pool limits and timeouts
- Set appropriate resource requests/limits
- Monitor Prometheus scrape success rates
- Use PodDisruptionBudgets to protect critical workloads
- Implement chaos engineering to test cascading failure scenarios

---

## 12. Misconfigured HPA -> Cost Spike -> Cluster Autoscaler -> Throttled API -> ArgoCD Sync Failure -> Alertmanager Storm

### Primary Trigger
HPA target CPU utilization incorrectly set to 5%.

### Propagation Path
1. **HPA Misfires**: Pods scale from 3 -> 500 in 10 min due to low CPU threshold
2. **Cluster Autoscaler Expansion**: Adds 100+ nodes in AWS/GCP to accommodate pods
3. **Cloud Billing Surge**: Cost monitoring agent hits cloud API rate limit
4. **K8s API Throttled**: Controller-manager and ArgoCD syncs fail due to QPS throttling
5. **ArgoCD Drift Detected**: Sync status shows "Unknown," leading to partial rollouts
6. **Alertmanager Storm**: Every HPA, cost, and Argo alert fires simultaneously

### Impact
- Massive overnight billing spike ($10K+)
- Alertmanager overload and alert fatigue
- ArgoCD unable to maintain desired state
- API server performance degradation
- Engineers silencing alerts without identifying root cause
- Production instability from partial deployments
- Cloud provider quota exhaustion

### Detection Signals
- Abnormal replica count increase (3 -> 500+)
- Node count explosion (100+ nodes)
- Cloud API throttling errors (429 responses)
- Kube-apiserver high latency and QPS throttling
- ArgoCD sync failures and "Unknown" status
- Cost anomaly alerts
- Alert storm in Alertmanager (hundreds of firing alerts)
- HPA events showing aggressive scaling

### Mitigation Steps
1. Immediately correct HPA target threshold to realistic value (70-80%)
2. Manually scale down excess replicas
3. Drain and remove unnecessary nodes gradually
4. Increase kube-apiserver QPS limits temporarily
5. Pause ArgoCD auto-sync until API stability restored
6. Clear Alertmanager alert queue
7. Review and adjust cost monitoring thresholds
8. Implement emergency budget controls

### Prevention
- Set realistic HPA metrics (typically 70-80% CPU utilization)
- Configure maxReplicas limits on all HPAs
- Implement HPA configuration validation in CI/CD
- Use cluster autoscaler limits (min/max nodes per node group)
- Set up cost guardrails and budget alerts
- Monitor kube-apiserver request rates and QPS
- Implement rate limiting on cost monitoring tools
- Regular review of autoscaling configurations
- Test autoscaling behavior in staging environments
- Use policy engines to validate HPA configurations

---

## 13. NetworkPolicy Restriction -> Service Mesh Retry Storm -> DB Saturation -> Prometheus Lag -> Alert Suppression -> Partial Outage

### Primary Trigger
Security team tightened NetworkPolicy to block cross-namespace traffic.

### Propagation Path
1. **NetworkPolicy Restriction**: API gateway pods can't reach auth service in different namespace
2. **Istio Sidecars Retries**: Each failed call retries 5x, flooding service mesh with traffic
3. **DB Saturation**: Auth service database hit by redundant requests; connection pool full
4. **Prometheus Metrics Lag**: /metrics endpoint times out; scraping delayed 1-2m
5. **Alert Suppression**: Alertmanager rules rely on `for: 2m` thresholds -> no alert fired in time
6. **Partial Outage**: Users intermittently unable to log in, while monitoring appears "green"

### Impact
- High real-user impact with minimal alerting
- Intermittent authentication failures
- Database connection pool exhaustion
- Service mesh traffic explosion
- Observability blind spot
- Extended MTTR due to delayed detection
- Customer-facing login issues

### Detection Signals
- NetworkPolicy applied events
- Service mesh timeout errors
- Increased retry attempts in sidecar logs
- Database connection pool exhaustion
- Auth service elevated error rates
- Prometheus scrape timeout warnings
- Distributed tracing showing broken service chains
- User-reported login issues before alerts fire

### Mitigation Steps
1. Review recent NetworkPolicy changes
2. Identify blocked communication paths using service mesh observability
3. Update NetworkPolicy to allow required cross-namespace traffic
4. Restart affected sidecars to clear retry queues
5. Scale auth service and database if needed
6. Verify Prometheus scrape health recovery
7. Review and adjust alert timing thresholds

### Prevention
- Test NetworkPolicy changes in staging first
- Use network policy visualization tools (e.g., Cilium Hubble)
- Implement gradual rollout of security policies
- Document service dependencies and communication patterns
- Configure appropriate retry budgets in service mesh
- Set connection pool limits and circuit breakers
- Lower alert evaluation intervals for critical services
- Use synthetic monitoring to detect issues before users
- Implement real-user monitoring (RUM)
- Create NetworkPolicy templates validated by CI/CD

---

## 14. Postgres Schema Drift -> ORM Migration Failure -> API Crash -> Prometheus Missing Series -> Alert Flap -> Argo Rollback Loop

### Primary Trigger
Database schema manually altered (added nullable constraint outside migration control).

### Propagation Path
1. **Schema Drift**: DB table altered outside migration workflow
2. **ORM Migration Fails**: Next app deploy from ArgoCD fails startup migration check
3. **API Crash**: App enters CrashLoopBackOff; readiness probe fails
4. **Prometheus Missing Time-Series**: Metrics labels for API latency disappear from TSDB
5. **Alertmanager Flap**: Missing metrics cause alerts to resolve/fire intermittently
6. **ArgoCD Rollback Loop**: Argo repeatedly rolls back + redeploys same version due to failing probes

### Impact
- Endless rollout loop preventing recovery
- Alert flapping causing confusion
- API service unavailability
- No clear root cause in monitoring
- Development team blames CI/CD pipeline
- Database schema inconsistency
- Extended outage duration

### Detection Signals
- Database migration failure errors in application logs
- CrashLoopBackOff pod status
- ArgoCD sync/rollback events in rapid succession
- Missing Prometheus time-series (metrics disappearing)
- Alert state flapping (firing -> resolved -> firing)
- Readiness probe failures
- Schema validation errors
- Database audit logs showing manual schema changes

### Mitigation Steps
1. Identify schema drift in database
2. Manually revert unauthorized schema changes or apply proper migration
3. Pause ArgoCD auto-sync to break rollback loop
4. Fix application migration scripts to handle current schema state
5. Deploy corrected version manually
6. Verify Prometheus metrics recovery
7. Resume ArgoCD auto-sync after stability confirmed
8. Implement schema change detection

### Prevention
- Enforce database schema change controls
- Use migration tools exclusively (Flyway, Liquibase, Alembic)
- Implement database change approval workflows
- Enable database audit logging
- Test migrations in staging environments
- Use schema validation in CI/CD pipeline
- Configure migration failure alerts
- Implement database GitOps workflows
- Use read-only database users for application runtime
- Add pre-deployment schema compatibility checks
- Disable ArgoCD auto-rollback for database-dependent services

---

## 15. Prometheus High Cardinality -> TSDB Corruption -> Metrics Drop -> Alert Delay -> Argo Rollout Overshoot -> DB Overload

### Primary Trigger
Unbounded metric labels from dynamic pod names or user IDs.

### Propagation Path
1. **High-Cardinality Metric**: /metrics includes user_id label -> millions of time-series created
2. **Prometheus TSDB Corruption**: WAL write queue overflows, partial block compaction fails
3. **Metrics Drop**: CPU/memory metrics become stale; HPA scales incorrectly based on old data
4. **Alert Delay**: Alertmanager backlog increases; firing delayed by 10+ min
5. **Argo Rollout Overshoot**: Rollout controller reads outdated metrics, increases canary weight to 100%
6. **DB Overload**: New app version hits DB with schema bug; DB CPU pegged at 100%

### Impact
- Monitoring system silent during critical failure
- Massive query load on database
- Complete canary rollout of buggy version
- False positives after recovery
- TSDB storage exhaustion
- Incorrect autoscaling decisions
- Extended outage with delayed detection

### Detection Signals
- Prometheus TSDB corruption errors
- WAL write failures in Prometheus logs
- Metrics cardinality explosion (series count spike)
- Prometheus storage usage spike
- Stale metrics in queries
- HPA showing outdated metric values
- Argo Rollout events showing unexpected weight changes
- Database CPU saturation
- Alert delivery delays

### Mitigation Steps
1. Identify and remove high-cardinality metrics
2. Restart Prometheus to clear WAL corruption
3. Implement metric relabeling to drop problematic labels
4. Manually rollback Argo Rollout to stable version
5. Scale database to handle load
6. Fix application code generating high-cardinality metrics
7. Clear Alertmanager backlog
8. Verify metrics collection recovery

### Prevention
- Monitor Prometheus cardinality and series count
- Implement metric relabeling rules to limit cardinality
- Set cardinality limits in instrumentation libraries
- Use metric label allowlists
- Regular Prometheus performance reviews
- Implement TSDB storage monitoring and alerts
- Use metric naming conventions avoiding dynamic labels
- Configure Prometheus retention policies
- Implement progressive delivery safeguards (small initial canary weights)
- Add Argo Rollout analysis templates with strict thresholds
- Use database connection pooling and query timeouts
- Test new instrumentation in staging first

---

## 16. Kube-API Slowdown -> Prometheus Scrape Failures -> Alert Silencing -> Cost Anomaly -> Cluster Node Eviction -> App Downtime

### Primary Trigger
etcd I/O latency spike due to cloud disk throttling.

### Propagation Path
1. **etcd Latency**: API responses slow down; kube-apiserver call latency >2s
2. **Prometheus Scrape Failures**: Kube-state-metrics times out; missing pod/node metrics
3. **Alert Silencing**: Alertmanager silences triggered alerts since data incomplete
4. **Autoscaler Fails**: HPA sees "no metrics," scales pods down to minReplicas
5. **Cost Anomaly Detector**: Cost monitoring agent retries repeatedly -> hits cloud API quota
6. **Node Eviction Chaos**: Node pressure rises; pods evicted mid-transaction; service downtime

### Impact
- Incident triggered by infrastructure bottleneck
- Misdiagnosed as HPA regression
- Metrics and alerts unreliable throughout incident
- Inappropriate scale-down during high load
- Cloud API quota exhaustion
- Pod evictions causing data loss
- Service disruption with poor visibility

### Detection Signals
- etcd high latency warnings (fsync duration >100ms)
- Kube-apiserver slow request logs
- Prometheus scrape timeout errors
- Kube-state-metrics unavailability
- HPA showing "unable to fetch metrics"
- Alertmanager silence events
- Unexpected scale-down events
- Cloud API throttling (429 errors)
- Node pressure events
- Pod eviction events
- Disk I/O throttling metrics

### Mitigation Steps
1. Identify etcd disk I/O bottleneck
2. Increase etcd disk IOPS or migrate to faster storage
3. Reduce kube-apiserver load (throttle clients if needed)
4. Manually scale up underprovisioned workloads
5. Disable cost monitoring agent temporarily
6. Add or scale nodes to relieve pressure
7. Verify Prometheus scrape recovery
8. Review and restore alerts from silence
9. Implement etcd performance tuning

### Prevention
- Monitor etcd performance metrics (disk latency, fsync duration)
- Use high-performance storage for etcd (SSD, provisioned IOPS)
- Implement etcd disk I/O alerts
- Optimize kube-apiserver configuration and rate limits
- Use Prometheus federation or sharding to reduce API load
- Configure appropriate HPA evaluation intervals and fallback behavior
- Implement rate limiting on cost monitoring tools
- Set PodDisruptionBudgets to prevent excessive evictions
- Use node affinity to isolate critical workloads
- Regular etcd performance testing and capacity planning
- Monitor cloud resource quotas
- Implement graceful degradation for metrics unavailability

---

## Bonus: Combined Multi-Layer Scenarios

For advanced RCA training, combine multiple scenarios to simulate complex, cascading failures:

### Scenario A: ConfigMap Drift + NetworkPolicy + Autoscaler Misconfig

**Trigger Chain:**
1. Stale ConfigMap causes app instability
2. NetworkPolicy change blocks service communication during troubleshooting
3. Misconfigured HPA scales up aggressively trying to handle errors
4. Cost spike triggers emergency response while debugging

**Complexity:** Multiple teams involved (Dev, Security, Platform), competing priorities, cost pressure

---

### Scenario B: Secret Expiry + ArgoCD Sync Delay + DB Connection Exhaustion

**Trigger Chain:**
1. Database credentials expire silently
2. ArgoCD sync delayed due to configuration drift
3. Apps exhaust connection pools trying to reconnect
4. New deployments fail due to inability to verify DB connectivity

**Complexity:** Authentication layer, GitOps workflow, connection management, deployment pipeline

---

### Scenario C: DNS TTL + Prometheus Throttling + Canary Rollout Failure

**Trigger Chain:**
1. DNS propagation delay causes traffic routing issues
2. Prometheus throttled by API server, missing metrics
3. Canary rollout proceeds without proper metrics validation
4. Faulty canary deployed to 100% traffic before metrics appear

**Complexity:** Multi-cluster, observability gaps, progressive delivery, timing dependencies

---

## Using These Scenarios

### For Training
- Walk through each propagation path step-by-step
- Identify detection points and signals
- Practice incident response procedures
- Document lessons learned

### For Testing
- Implement chaos engineering experiments
- Test monitoring and alerting coverage
- Validate incident response playbooks
- Verify automated remediation

### For RCA Practice
- Present scenarios without showing propagation paths
- Practice hypothesis formation and testing
- Use distributed tracing and logging to piece together timeline
- Identify multiple contributing factors

### For Prevention
- Review scenarios against current architecture
- Identify gaps in observability and automation
- Implement guardrails and policy enforcement
- Regular game day exercises

---

## Contributing

To add new scenarios or improve existing ones:
1. Follow the established format (Trigger -> Propagation -> Impact -> Detection -> Mitigation -> Prevention)
2. Base scenarios on real incidents or realistic failure modes
3. Include specific tools and technologies
4. Provide actionable detection signals and mitigation steps

---

## Additional Resources

- [Kubernetes Troubleshooting Guide](https://kubernetes.io/docs/tasks/debug/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Prometheus Best Practices](https://prometheus.io/docs/practices/)
- [SRE Workbook - Google](https://sre.google/workbook/table-of-contents/)
- [Chaos Engineering Principles](https://principlesofchaos.org/)

---

**Last Updated:** 2025-11-05
**Maintainer:** SRE Team
**Version:** 1.1.0
