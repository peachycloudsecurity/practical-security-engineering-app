# Practical Security Engineering — Training Labs

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL%203.0-blue.svg)](LICENSE)
[![Maintained by peachycloudsecurity](https://img.shields.io/badge/maintained%20by-peachycloudsecurity-orange)](https://peachycloudsecurity.com)
[![Step Security](https://img.shields.io/badge/includes-GitHub%20Actions%20Goat%20(StepSecurity)-blueviolet)](https://github.com/step-security/github-actions-goat)

Deliberately vulnerable applications and CI/CD environments for **hands-on security engineering training**. Used in the [Practical Security Engineering for Tech Teams](https://peachycloudsecurity.com) instructor-led course.

> **FOR EDUCATIONAL USE ONLY.** Do not deploy in production. See [Disclaimer](#️-disclaimer) below.

---

## Repository Overview

This repository combines two codebases for training purposes:

| Component | Source | Purpose |
|---|---|---|
| `vulnerable-python-app/` | [peachycloudsecurity](https://github.com/peachycloudsecurity/vulnerable-demo-app) | Python app with command injection, K8s escape scenarios |
| `labs/github-actions-devsecops/` | peachycloudsecurity | Six-layer DevSecOps pipeline lab (GitHub Actions) |
| `.github/workflows/` (goat workflows) | [step-security/github-actions-goat](https://github.com/step-security/github-actions-goat) | Deliberately vulnerable CI/CD attack simulations |
| `src/` | [step-security/github-actions-goat](https://github.com/step-security/github-actions-goat) | Backdoor and exfiltration demos for CI/CD labs |

---

## Labs

### Lab 1 — Vulnerable Python App (OWASP / K8s)

Python web app with intentional vulnerabilities for OWASP Top 10 and Kubernetes security labs.

**Run with Docker:**
```bash
docker pull peachycloudsecurity/vulnerable-python-app:latest
docker run -p 8081:8080 peachycloudsecurity/vulnerable-python-app:latest
```

**Deploy on Kubernetes:**
```bash
kubectl apply -f vulnerable-python-app/manifests/deployment.yaml
```

**Vulnerabilities included:**

| # | Type | Endpoint | Example |
|---|---|---|---|
| 1 | Command Injection | `POST /ping` | Input: `127.0.0.1; whoami; id` |
| 2 | Path Traversal + Host Escape | `/mnt/host/` | Via `vulnerable-exploit-pod` mounted at `/mnt/host` |
| 3 | K8s Privilege Escalation | Privileged pod | HostPath mount → read host files |

---

### Lab 2 — Six-Layer DevSecOps Pipeline (GitHub Actions)

Located in `labs/github-actions-devsecops/`. Intentionally vulnerable project used to build and trigger a full DevSecOps pipeline in GitHub Actions covering six security layers.

**Lab files:**
```
labs/github-actions-devsecops/
├── app.py                  # Hardcoded AWS key + SQL injection
├── requirements.txt        # Vulnerable deps: flask 0.12.2, requests 2.20.0
├── Dockerfile              # Runs as root, python:3.9-slim
└── infrastructure/sg.tf   # SSH open to 0.0.0.0/0
```

**Pipeline layers (workflow_dispatch — triggered manually):**

| Layer | Tool | What it catches |
|---|---|---|
| Secrets | Gitleaks | Hardcoded AWS key in `app.py` (pattern match) |
| Secrets | TruffleHog | Verified live credentials (fake lab key passes) |
| SAST | bandit | Python insecure patterns — `shell=True`, hardcoded secrets |
| SAST | OpenGrep | SQL injection, OWASP Top 10 patterns |
| SAST | CodeQL | Semantic/dataflow analysis — multi-hop taint tracking |
| Dependencies | pip-audit | CVEs in `flask==0.12.2`, `requests==2.20.0` via PyPI advisory DB |
| Dependencies | Trivy FS | OS + Python package CVEs, secrets in files |
| Dependencies | Grype | SBOM-aware CVE scan — catches transitive deps |
| Container | Trivy Image | Root user, OS CVEs in `python:3.9-slim` |
| IaC | Checkov | Security group open to `0.0.0.0/0` |
| Licenses | pip-licenses | GPL license policy enforcement |

> Tools overlap intentionally — no single scanner catches everything. Compare findings across tools.

SARIF results from all jobs upload to **Security → Code scanning** tab. Summary table writes to Actions job summary.

To run: go to **Actions → Full DevSecOps Pipeline — Lab → Run workflow**.

---

### Lab 3 — GitHub Actions Goat (CI/CD Attack Simulations)

Sourced from [step-security/github-actions-goat](https://github.com/step-security/github-actions-goat) and integrated here for CI/CD security training. Simulates real-world attacks that occurred in SolarWinds, Codecov, and ua-parser-js incidents.

**Attack scenarios included:**

| Workflow | Simulates |
|---|---|
| `arc-solarwinds-simulation.yml` | SolarWinds-style build tampering |
| `arc-codecov-simulation.yml` | Codecov-style secret exfiltration |
| `secret-in-build-log.yml` | Secret leaked in CI log output |
| `anomalous-outbound-calls.yaml` | Unexpected outbound network calls |
| `tj-actions-changed-files-incident.yaml` | tj-actions supply chain incident |
| `PRTargetWorkflow.yml` | `pull_request_target` privilege escalation |

Reference: [CISA/NSA Defending CI/CD Environments](https://media.defense.gov/2023/Jun/28/2003249466/-1/-1/0/CSI_DEFENDING_CI_CD_ENVIRONMENTS.PDF)

---

## ⚠️ Disclaimer

1. **Vulnerable by design.** This repository is intentionally insecure. **DO NOT** deploy in production or any network with sensitive data.
2. **Authorized use only.** Use exclusively in controlled lab environments with explicit permission. Using against systems without permission is illegal.
3. **No warranty.** Provided "as is" without warranty of any kind.
4. **No liability.** The authors, maintainers (peachycloudsecurity.com), and any past/present employers are not liable for any direct, indirect, or consequential damages from use or misuse.

---

## Attribution

- **Vulnerable Python app:** Originally from [peachycloudsecurity/vulnerable-demo-app](https://github.com/peachycloudsecurity/vulnerable-demo-app)
- **GitHub Actions Goat:** From [step-security/github-actions-goat](https://github.com/step-security/github-actions-goat) by [StepSecurity](https://stepsecurity.io) — Apache 2.0 License
- **DevSecOps pipeline lab:** Built by peachycloudsecurity for instructor-led training

---

## About peachycloudsecurity

Hands-on multi-cloud and cloud-native security education by **The Shukla Duo (Anjali & Divyanshu)**.

[YouTube](https://www.youtube.com/@peachycloudsecurity) · [Website](https://peachycloudsecurity.com) · [Consultations](https://topmate.io/peachycloudsecurity) · [Sponsor](https://github.com/sponsors/peachycloudsecurity)

---

## License

- peachycloudsecurity code: **GPL-3.0** — see `LICENSE`
- GitHub Actions Goat code (`src/`, goat workflows): **Apache 2.0** — see original repo
