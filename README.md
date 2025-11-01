# SRE-bench
We are building an SRE agent benchmark inspired by [SWE-bench](https://github.com/SWE-bench/SWE-bench) - an open and reproducible framework designed to evaluate agents on Kubernetes tasks: incident response, infra changes, observability triage, and reliability improvements. The repo will host modular scenarios (fault injectors, manifests, observability specs), an evaluation harness, and baseline agents. 

The goal is to measure practical agent capabilities like time-to-diagnose, safe remediation rate, MTTR, and explainability.

## Purpose

This repository also serves as:
- **Benchmarking platform** for evaluating SRE agent performance
- **Agentkube POC** environment for testing autonomous Kubernetes agents
- **Community-driven scenario library** - users can contribute diverse scenarios to test their own agents

See [scenario documentation](scenerio/README.md) for available test cases and contribution guidelines.
