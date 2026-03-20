# Security Scanning — Pipeline Steps Reference

This document describes every security scanning step in the KT CI/CD pipelines and what each one does.

---

## Deploy Pipeline (`deploy.yml` — Security Scan Job)

The security scan job runs on every push to `main` and on `workflow_dispatch` **before** any infrastructure changes are applied. All steps must pass (or soft-fail where configured) before the multi-stage deployment (DEV → TEST → QA → PROD) can proceed.

### 1. Terraform Format Check

```
terraform fmt -check -recursive
```

**What it does**: Verifies that all `.tf` files follow the canonical Terraform formatting standard (indentation, alignment, spacing). Fails the pipeline if any file is not properly formatted.

**Why it matters**: Enforces consistent code style across the team. Formatting differences create noisy diffs and merge conflicts. Running `terraform fmt` locally before committing prevents this.

**Fail behavior**: Hard fail — the pipeline stops.

---

### 2. tfsec — Terraform Security Scanner

```
tfsec terraform --format sarif --out tfsec-results.sarif --soft-fail
```

**What it does**: Static analysis tool purpose-built for Terraform. Scans all `.tf` files for security misconfigurations against a library of 300+ rules covering Azure, AWS, and GCP. Examples of issues it catches:
- Storage accounts with public access enabled
- Databases without encryption at rest
- Network security groups with overly permissive rules
- Key Vaults without purge protection
- Resources missing diagnostic settings

**Output**: Results are uploaded as SARIF to the GitHub **Security → Code scanning** tab, making findings visible alongside code.

**Fail behavior**: Soft fail — findings are reported but don't block the pipeline. Review findings in the Security tab.

---

### 3. TFLint — Terraform Linter

```
tflint --format compact --force
```

**What it does**: Lints Terraform code for:
- **Deprecated syntax** — flags old HCL patterns
- **Invalid references** — catches typos in variable/resource names
- **Provider-specific rules** — validates that Azure resource attributes are valid (e.g., correct VM sizes, valid SKU names)
- **Best practices** — unused variables, missing descriptions

**Why it matters**: Catches errors that `terraform validate` misses, particularly provider-specific issues like invalid SKUs or attributes that don't exist for a given API version.

**Fail behavior**: Uses `--force` to report all issues. Non-blocking.

---

### 4. Checkov — IaC Policy Scanner

```
checkov --directory terraform --framework terraform --config-file terraform/.checkov.yaml
```

**What it does**: Broad infrastructure-as-code policy scanner from Bridgecrew/Palo Alto. Checks Terraform against 1,000+ policies based on:
- **CIS Benchmarks** — Center for Internet Security best practices
- **NIST 800-53** — Federal security controls
- **Azure-specific checks** — encryption, networking, identity, logging

Unlike tfsec (which focuses on security misconfigurations), Checkov covers compliance and governance policies.

**Skip configuration**: Some checks are skipped via `terraform/.checkov.yaml` because they require ACR Premium SKU or customer-managed key (CMK) infrastructure not in scope:

| Skipped Check | Reason |
|---------------|--------|
| CKV_AZURE_117 | AKS disk encryption set — requires CMK |
| CKV_AZURE_233 | ACR zone redundancy — Premium SKU |
| CKV_AZURE_167 | ACR retention policy — Premium SKU |
| CKV_AZURE_164 | ACR content trust — Premium SKU |
| CKV_AZURE_166 | ACR quarantine — Premium SKU (preview) |
| CKV_AZURE_139 | ACR private networking — Premium SKU |
| CKV_AZURE_165 | ACR geo-replication — Premium SKU |
| CKV_AZURE_237 | ACR dedicated data endpoints — Premium SKU |

**Output**: SARIF results uploaded to GitHub **Security → Code scanning** tab.

**Fail behavior**: Soft fail — findings are reported but don't block.

---

### 5. TruffleHog — Secret Detection

```
trufflehog --only-verified --results=verified
```

**What it does**: Scans the entire Git history and working tree for committed secrets, API keys, passwords, and credentials. Unlike pattern-based scanners, TruffleHog **verifies** found credentials against the actual service (e.g., tries to authenticate with a found Azure key) to reduce false positives.

**What it catches**:
- Azure client secrets and storage account keys
- Database connection strings
- GitHub tokens and PATs
- SSH private keys
- Any high-entropy strings that match known credential patterns

**Why it matters**: Even if a secret was committed and then removed in a later commit, it remains in Git history. TruffleHog finds these.

**Fail behavior**: Hard fail if verified secrets are found.

---

### 6. Trivy — Container Vulnerability Scan

```
trivy image --exit-code 1 --severity HIGH,CRITICAL --format table "scan-<app>:latest"
```

**What it does**: Builds each Dockerfile in the repository into a container image, then scans the image for known vulnerabilities (CVEs) in:
- **OS packages** — apt, apk, yum packages in the base image
- **Language libraries** — pip, npm, Go modules bundled in the image
- **Configuration** — Dockerfile misconfigurations (running as root, etc.)

Only **HIGH** and **CRITICAL** severity vulnerabilities trigger a failure.

**When it runs**: Only if Dockerfiles are found in the repository. Scans all Dockerfiles automatically.

**Fail behavior**: Hard fail on HIGH/CRITICAL CVEs — forces base image updates before deployment.

---

## PR Checks Pipeline (`pr-checks.yml`)

These checks run automatically on every pull request to `main`. All must pass before the PR can be merged.

### 7. CodeQL — Static Application Security Testing (SAST)

```yaml
uses: github/codeql-action/analyze@v4
```

**What it does**: GitHub's semantic code analysis engine. Builds a database of the application code's data flow and control flow, then runs security queries to find vulnerabilities such as:
- **SQL injection** — user input flowing into database queries
- **Cross-site scripting (XSS)** — untrusted data rendered in HTML
- **Command injection** — user input passed to shell commands
- **Path traversal** — file access with user-controlled paths
- **Insecure deserialization** — untrusted data deserialized unsafely
- **Hardcoded credentials** — passwords or keys in source code

Currently configured for **Python** (the Hello Korea Flask apps). Languages can be added to the matrix as the project grows.

**Output**: Results appear in the GitHub **Security → Code scanning** tab and as PR annotations.

**Fail behavior**: Hard fail — blocks the PR merge.

---

### 8. Dependency Review — Software Composition Analysis (SCA)

```yaml
uses: actions/dependency-review-action@v4
```

**What it does**: Analyzes the dependency diff introduced by a PR. For every new or updated dependency (pip packages, npm modules, etc.), it checks:
- **Known vulnerabilities** — CVEs in the National Vulnerability Database
- **License compliance** — flags licenses that may be incompatible
- **Malicious packages** — known supply-chain attack packages

Only reviews **changes** in the PR, not the entire dependency tree (that's Dependabot's job).

**Why it matters**: Prevents introducing vulnerable dependencies via PRs. Complements Dependabot, which handles existing dependencies on a schedule.

**Fail behavior**: Hard fail if vulnerable dependencies are introduced.

---

### 9. Terraform Validation (PR)

Runs the same checks as the deploy pipeline's scan for Terraform code:
- `terraform fmt -check -recursive`
- `terraform init -backend=false` + `terraform validate`
- TFLint
- tfsec with SARIF upload

This ensures Terraform changes in PRs are validated before merge, without needing Azure credentials (no backend needed for validation).

---

### 10. Container Scan (PR)

Same Trivy scan as the deploy pipeline — builds Dockerfiles and scans for HIGH/CRITICAL CVEs. Ensures container security issues are caught at PR time, not at deploy time.

---

## Dependency Management

### Dependabot (`.github/dependabot.yml`)

**What it does**: Automatically opens PRs to update outdated dependencies on a weekly schedule. Covers:

| Ecosystem | Directory | What it updates |
|-----------|-----------|-----------------|
| `github-actions` | `/` | Action versions in workflow files |
| `pip` | `/apps/hello-korea-aks` | Python packages |
| `pip` | `/apps/hello-korea-aca` | Python packages |
| `terraform` | `/terraform` | Terraform provider versions |

**Why it matters**: Outdated dependencies are a top attack vector (OWASP A06). Dependabot keeps the supply chain current without manual effort. Each Dependabot PR triggers the PR checks pipeline, so updates are validated before merge.

---

## Summary: When Each Scanner Runs

| Scanner | Deploy Pipeline | PR Pipeline | Blocks Deploy | Blocks PR Merge |
|---------|:-:|:-:|:-:|:-:|
| terraform fmt | ✅ | ✅ | ✅ | ✅ |
| tfsec | ✅ | ✅ | ❌ (soft) | ❌ (soft) |
| TFLint | ✅ | ✅ | ❌ | ❌ |
| Checkov | ✅ | ❌ | ❌ (soft) | — |
| TruffleHog | ✅ | ❌ | ✅ | — |
| Trivy | ✅ | ✅ | ✅ | ✅ |
| CodeQL | ❌ | ✅ | — | ✅ |
| Dependency Review | ❌ | ✅ | — | ✅ |
| Dependabot | scheduled | triggers PR | — | via PR checks |

> **Note**: In the deploy pipeline, security scanning runs once at the start. If it passes, the pipeline proceeds through all four environment stages (DEV → TEST → QA → PROD) with human approval gates at QA and PROD.
