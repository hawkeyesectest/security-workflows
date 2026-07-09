# Centralized Security Pipeline

A reusable GitHub Actions security pipeline that provides secrets scanning, SAST, dependency auditing, SBOM generation, and supply-chain risk analysis across all repositories in the org.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  your-org/.github  (org-level defaults)                         │
│  └── workflow-templates/security-scan.yml  (starter template)   │
└──────────────────────────┬──────────────────────────────────────┘
                           │ provides template
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  any-repo/.github/workflows/ci.yml  (3-line callsite)           │
│  └── uses: your-org/security-workflows/...@main                 │
└──────────────────────────┬──────────────────────────────────────┘
                           │ calls
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  your-org/security-workflows  (this repo)                       │
│  ├── .github/workflows/security-scan.yml  ← reusable workflow   │
│  ├── .semgrep/rules.yml                   ← org-wide rules      │
│  ├── .gitleaks.toml                       ← secrets config       │
│  └── scripts/run-security-checks.sh       ← local pre-push      │
└─────────────────────────────────────────────────────────────────┘
```

## What runs

All jobs execute **in parallel**. A final Security Gate job aggregates results.

| Job | Tool | What it does |
|-----|------|-------------|
| Secrets: Gitleaks | [Gitleaks](https://github.com/gitleaks/gitleaks) | Regex + entropy scan of full git history for leaked credentials |
| Secrets: TruffleHog | [TruffleHog](https://github.com/trufflesecurity/trufflehog) | Finds secrets and **verifies** they're actually live |
| SAST: Semgrep | [Semgrep](https://semgrep.dev) | AST-based pattern matching for security anti-patterns |
| Deps: pip-audit | [pip-audit](https://github.com/pypa/pip-audit) | Checks Python packages against the OSV vulnerability database |
| Deps: Trivy | [Trivy](https://github.com/aquasecurity/trivy) | Filesystem scan for CRITICAL/HIGH CVEs across all package types |
| Supply Chain: Socket.dev | [Socket](https://socket.dev) | Behavioral analysis detecting typosquatting and supply-chain attacks |
| SBOM: Syft + Grype | [Syft](https://github.com/anchore/syft) / [Grype](https://github.com/anchore/grype) | Generates SPDX SBOM, then scans it for known vulnerabilities |

## Onboarding a new repo

### Step 1: Add the workflow callsite

Create `.github/workflows/ci.yml` in your repo:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  security:
    uses: your-org/security-workflows/.github/workflows/security-scan.yml@main
    secrets: inherit
```

That's it. Three lines in the `jobs:` block.

### Step 2 (optional): Customize inputs

```yaml
jobs:
  security:
    uses: your-org/security-workflows/.github/workflows/security-scan.yml@main
    with:
      python-version: "3.11"
      requirements-file: "requirements/prod.txt"
      semgrep-rules: "p/python p/django p/security-audit"
      severity-threshold: "HIGH"
    secrets: inherit
```

### Step 3: Set up branch protection

Go to **Settings > Branches > Branch protection rules** for `main`:

1. Enable **Require status checks to pass before merging**
2. Add **Security Gate** as a required check
3. Enable **Require review from Code Owners**

## Adding repo-specific rules

Org-wide rules live in this repo's `.semgrep/rules.yml`. Individual repos can add rules that layer on top:

```
your-app/
├── .semgrep/
│   └── repo-rules.yml    ← your repo-specific rules
└── .github/
    └── workflows/
        └── ci.yml
```

The reusable workflow scans `--config .semgrep/` which picks up any YAML files in the calling repo's `.semgrep/` directory automatically.

## Suppressing false positives

Every suppression must be documented. No silent `# nosemgrep` comments.

### Semgrep

Add an inline comment with justification:

```python
# nosemgrep: requests-verify-disabled
# Justification: Internal CA-signed cert, custom CA bundle loaded via REQUESTS_CA_BUNDLE env var
response = requests.get(internal_url, verify=False)
```

### Gitleaks

Add the finding to `.gitleaksignore` (one finding fingerprint per line):

```
# Fingerprint from gitleaks output
# Justification: Test fixture with fake AWS key, not a real credential
abc123def456:tests/fixtures/aws_config.py:aws_access_key_id:3
```

### Trivy

Create `.trivyignore` in the repo root:

```
# CVE-2023-XXXXX
# Justification: Not exploitable in our usage — we don't use the affected XML parser
# Reviewed by: @security-team on 2024-01-15
# Expires: 2024-07-15
CVE-2023-XXXXX
```

### pip-audit

Pin to a known-safe version in `requirements.txt` and document in a comment:

```
# Pinned: CVE-2023-XXXXX affects <2.1.0 but we use the fixed method introduced in 2.0.5
# Reviewed by: @security-team on 2024-01-15
some-package==2.0.5
```

## Severity thresholds

| Severity | Pipeline behavior | Developer action |
|----------|------------------|-----------------|
| **CRITICAL** | Blocks merge (Security Gate fails) | Must fix before merging |
| **HIGH** | Blocks merge by default | Fix or get security team exception |
| **MEDIUM** | Informational (appears in Security tab) | Fix in next sprint |
| **LOW** | Informational only | Address at discretion |

To change the threshold per repo, set `severity-threshold` in the callsite inputs.

## Running locally

Install the tools once:

```bash
brew install gitleaks trivy
pip install semgrep pip-audit
```

Then run:

```bash
./scripts/run-security-checks.sh          # full scan
./scripts/run-security-checks.sh --quick   # secrets + SAST only (faster)
```

## Required GitHub Secrets

Set these at the **org level** (Settings > Secrets and variables > Actions):

| Secret | Required | Purpose |
|--------|----------|---------|
| `SEMGREP_APP_TOKEN` | Optional | Enables Semgrep Cloud findings dashboard |
| `SOCKET_SECURITY_API_KEY` | Optional | Enables Socket.dev supply-chain analysis |

The pipeline works without these secrets — the corresponding jobs will be skipped or use free-tier defaults.
