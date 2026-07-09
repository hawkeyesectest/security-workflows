#!/usr/bin/env bash
#
# run-security-checks.sh
#
# Runs the same security checks locally that CI runs remotely.
# Engineers run this before pushing so they catch issues early
# instead of waiting 5+ minutes for CI feedback.
#
# Usage:
#   ./scripts/run-security-checks.sh              # scan everything
#   ./scripts/run-security-checks.sh --quick       # secrets + SAST only
#   ./scripts/run-security-checks.sh --fix         # auto-fix where possible
#
# Prerequisites (install once):
#   brew install gitleaks semgrep trivy
#   pip install pip-audit

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

QUICK_MODE=false
FIX_MODE=false
FAILED_CHECKS=()
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-requirements.txt}"

for arg in "$@"; do
    case "$arg" in
        --quick) QUICK_MODE=true ;;
        --fix)   FIX_MODE=true ;;
        --help|-h)
            echo "Usage: $0 [--quick] [--fix]"
            echo "  --quick  Run only secrets + SAST (skip dependency scans)"
            echo "  --fix    Apply auto-fixes where supported"
            exit 0
            ;;
    esac
done

header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

pass() { echo -e "  ${GREEN}✓ $1${NC}"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; FAILED_CHECKS+=("$1"); }
warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }
skip() { echo -e "  ${YELLOW}⊘ $1 (skipped)${NC}"; }

check_tool() {
    if ! command -v "$1" &> /dev/null; then
        warn "$1 not installed — install with: $2"
        return 1
    fi
    return 0
}

# ── PREREQUISITES ─────────────────────────────

header "Checking prerequisites"

HAVE_GITLEAKS=false
HAVE_SEMGREP=false
HAVE_PIP_AUDIT=false
HAVE_TRIVY=false

check_tool gitleaks "brew install gitleaks"     && HAVE_GITLEAKS=true
check_tool semgrep  "pip install semgrep"        && HAVE_SEMGREP=true
check_tool pip-audit "pip install pip-audit"     && HAVE_PIP_AUDIT=true
check_tool trivy    "brew install trivy"         && HAVE_TRIVY=true

# ── SECRETS SCANNING ─────────────────────────

header "Secrets Scanning (Gitleaks)"

if $HAVE_GITLEAKS; then
    GITLEAKS_ARGS=(detect --source . --verbose)

    if [ -f ".gitleaks.toml" ]; then
        GITLEAKS_ARGS+=(--config .gitleaks.toml)
    fi

    if gitleaks "${GITLEAKS_ARGS[@]}"; then
        pass "No secrets found in git history"
    else
        fail "Gitleaks found potential secrets"
    fi
else
    skip "Gitleaks"
fi

# ── SAST (SEMGREP) ───────────────────────────

header "Static Analysis (Semgrep)"

if $HAVE_SEMGREP; then
    SEMGREP_ARGS=(scan --config p/python --config p/security-audit --config p/owasp-top-ten)

    if [ -d ".semgrep" ]; then
        SEMGREP_ARGS+=(--config .semgrep/)
    fi

    if $FIX_MODE; then
        SEMGREP_ARGS+=(--autofix)
    fi

    SEMGREP_ARGS+=(--error --quiet)

    if semgrep "${SEMGREP_ARGS[@]}"; then
        pass "No SAST findings"
    else
        fail "Semgrep found security issues"
        echo ""
        echo "  Run with verbose output to see details:"
        echo "    semgrep scan --config p/python --config p/security-audit --config .semgrep/"
    fi
else
    skip "Semgrep"
fi

# Skip dependency scans in quick mode
if $QUICK_MODE; then
    header "Quick mode — skipping dependency scans"
else

    # ── DEPENDENCY AUDIT ──────────────────────

    header "Dependency Audit (pip-audit)"

    if $HAVE_PIP_AUDIT; then
        if [ ! -f "$REQUIREMENTS_FILE" ]; then
            warn "No $REQUIREMENTS_FILE found — skipping pip-audit"
        else
            if pip-audit --requirement "$REQUIREMENTS_FILE" --desc 2>/dev/null; then
                pass "No known vulnerabilities in dependencies"
            else
                fail "pip-audit found vulnerable dependencies"
            fi
        fi
    else
        skip "pip-audit"
    fi

    # ── FILESYSTEM SCAN (TRIVY) ──────────────

    header "Filesystem Scan (Trivy)"

    if $HAVE_TRIVY; then
        if trivy fs --severity CRITICAL,HIGH --exit-code 1 --quiet .; then
            pass "No CRITICAL/HIGH vulnerabilities found"
        else
            fail "Trivy found CRITICAL or HIGH vulnerabilities"
            echo ""
            echo "  Run with full output to see details:"
            echo "    trivy fs --severity CRITICAL,HIGH ."
        fi
    else
        skip "Trivy"
    fi

fi

# ── SUMMARY ──────────────────────────────────

header "Summary"

if [ ${#FAILED_CHECKS[@]} -eq 0 ]; then
    echo -e "${GREEN}"
    echo "  All checks passed. Safe to push."
    echo -e "${NC}"
    exit 0
else
    echo -e "${RED}"
    echo "  ${#FAILED_CHECKS[@]} check(s) failed:"
    for check in "${FAILED_CHECKS[@]}"; do
        echo "    • $check"
    done
    echo ""
    echo "  Fix these issues before pushing."
    echo -e "${NC}"
    exit 1
fi
