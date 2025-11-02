# SRE Failure Scenarios

This document contains 10 real-world SRE incident scenarios designed for training, testing, and RCA (Root Cause Analysis) practice. Each scenario simulates cascading failures common in Kubernetes, GitOps, and cloud-native environments.

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
11. [Combined Multi-Layer Scenarios](#bonus-combined-multi-layer-scenarios)

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

**Last Updated:** 2025-11-01
**Maintainer:** SRE Team
**Version:** 1.0.0
