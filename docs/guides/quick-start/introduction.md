# SRE-bench: Kubernetes SRE Agent Benchmark

Welcome to SRE-bench, an open and reproducible framework designed to evaluate autonomous agents on real-world Kubernetes Site Reliability Engineering (SRE) tasks.

## What is SRE-bench?

SRE-bench is inspired by [SWE-bench](https://github.com/SWE-bench/SWE-bench) and provides a comprehensive testing ground for evaluating AI agents on:

- **Incident Response** - How quickly can agents diagnose and resolve production incidents?
- **Infrastructure Changes** - Can agents safely apply configuration updates and deployments?
- **Observability Triage** - How effectively do agents analyze metrics, logs, and traces?
- **Reliability Improvements** - Can agents identify and remediate reliability issues proactively?

## Key Features

- **10 Real-World Scenarios** - Production-grade failure scenarios covering GitOps drift, resource pressure, networking issues, and more
- **Reproducible Environments** - Each scenario can run in isolated Kind clusters or existing Kubernetes environments
- **GitOps Integration** - Scenarios use ArgoCD for realistic deployment workflows where applicable
- **Practical Metrics** - Measure time-to-diagnose, safe remediation rate, MTTR, and explainability
- **Community-Driven** - Open for contributions of new scenarios and agent implementations

## Who is this for?

- **SRE Teams** - Training ground for understanding complex Kubernetes failure modes
- **AI/Agent Developers** - Benchmark platform for evaluating autonomous agent capabilities
- **Platform Engineers** - Test environment for validating infrastructure changes
- **Security Teams** - Safe sandbox for chaos engineering and failure injection

## Quick Navigation

<scalar-steps>

:::scalar-step{title="Understand the Architecture" interactivity="none"}
:scalar-icon{src="stack"} Learn how the codebase is organized.
::scalar-page-link{filepath="docs/guides/quick-start/architecture.md" title="Architecture Overview" description="Explore the project structure and components."}
:::

:::scalar-step{title="Run Scenarios" interactivity="none"}
:scalar-icon{src="play"} Execute failure scenarios and observe incidents.
::scalar-page-link{filepath="docs/guides/quick-start/running-scenarios.md" title="Running Scenarios" description="Step-by-step guide to running SRE scenarios."}
:::

:::scalar-step{title="Contribute" interactivity="none"}
:scalar-icon{src="git-branch"} Add your own scenarios to the benchmark.
::scalar-page-link{filepath="docs/guides/quick-start/contributing.md" title="Contributing Guide" description="Learn how to contribute new scenarios."}
:::

</scalar-steps>

## Project Purpose

This repository serves multiple purposes:

1. **Benchmarking Platform** - Evaluate SRE agent performance against standardized scenarios
2. **Agentkube POC** - Testing environment for autonomous Kubernetes agents
3. **Community Scenario Library** - Users can contribute diverse scenarios to test their own agents
4. **SRE Training** - Hands-on learning environment for understanding Kubernetes failure modes

## Getting Started

The fastest way to get started is to run a scenario:

```bash
# Clone the repository
git clone https://github.com/siddhantprateek/SRE-bench.git
cd SRE-bench

# Run scenario 1: ConfigMap Drift
./scripts/1_scenerio.sh
```

Each scenario is self-contained and will:
1. Create a Kind cluster (or use your existing cluster with `--cluster` flag)
2. Install necessary components (ArgoCD, metrics-server, etc.)
3. Deploy the initial stable state
4. Trigger the failure condition
5. Demonstrate the cascading failure
6. Show detection signals and mitigation steps

## What's Next?

- **[Architecture Overview](docs/guides/quick-start/architecture.md)** - Understand the codebase structure
- **[Running Scenarios](docs/guides/quick-start/running-scenarios.md)** - Learn how to execute scenarios
- **[Contributing](docs/guides/quick-start/contributing.md)** - Add your own scenarios

## Support

For questions, issues, or contributions:
- **GitHub Issues**: [github.com/siddhantprateek/SRE-bench/issues](https://github.com/siddhantprateek/SRE-bench/issues)
- **Documentation**: You're reading it!
- **Scenario Details**: See [scenario README](../../../scenerio/README.md) for detailed descriptions of all 10 scenarios
