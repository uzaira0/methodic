#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SLSA / Image Signing and SBOM Verification Script
# Verifies build provenance, generates SBOMs, and checks vulnerabilities
# for Chronicle Docker images.
#
# Usage: ./verify-image-provenance.sh [--sign|--verify] [--image IMAGE]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_DIR="$SCRIPT_DIR/reports"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
PASS=0
FAIL=0
SKIP=0

# Defaults
MODE="verify"
IMAGES=("chronicle-backend" "chronicle-frontend")

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

log_pass() {
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}[PASS]${NC} $1"
}

log_fail() {
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}[FAIL]${NC} $1"
}

log_skip() {
    SKIP=$((SKIP + 1))
    echo -e "  ${YELLOW}[SKIP]${NC} $1"
}

log_info() {
    echo -e "  ${BLUE}[INFO]${NC} $1"
}

section() {
    echo ""
    echo -e "${BOLD}=== $1 ===${NC}"
}

usage() {
    echo "Usage: $(basename "$0") [--sign|--verify] [--image IMAGE]"
    echo ""
    echo "Options:"
    echo "  --sign       Sign images and attach SBOMs (requires private key)"
    echo "  --verify     Verify image signatures (default)"
    echo "  --image IMG  Operate on a specific image instead of all defaults"
    echo "  --help       Show this help message"
    echo ""
    echo "Default images: chronicle-backend, chronicle-frontend"
    echo "Report directory: $REPORT_DIR"
    exit 0
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign)
            MODE="sign"
            shift
            ;;
        --verify)
            MODE="verify"
            shift
            ;;
        --image)
            IMAGES=("$2")
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

echo -e "${BOLD}Chronicle Image Provenance Verification${NC}"
echo "Mode: $MODE"
echo "Images: ${IMAGES[*]}"
echo "Report dir: $REPORT_DIR"

mkdir -p "$REPORT_DIR"

# =============================================================================
# Section 1: Tool Check
# =============================================================================

section "Tool Check"

HAS_COSIGN=false
HAS_TRIVY=false

if command -v cosign &>/dev/null; then
    log_pass "cosign found: $(cosign version 2>&1 | head -1)"
    HAS_COSIGN=true
else
    log_skip "cosign not installed"
    echo -e "    ${YELLOW}Install: https://docs.sigstore.dev/cosign/system_config/installation/${NC}"
    echo -e "    ${YELLOW}  brew install cosign${NC}"
    echo -e "    ${YELLOW}  go install github.com/sigstore/cosign/v2/cmd/cosign@latest${NC}"
fi

if command -v trivy &>/dev/null; then
    log_pass "trivy found: $(trivy --version 2>&1 | head -1)"
    HAS_TRIVY=true
else
    log_skip "trivy not installed"
    echo -e "    ${YELLOW}Install: https://aquasecurity.github.io/trivy/latest/getting-started/installation/${NC}"
    echo -e "    ${YELLOW}  brew install trivy${NC}"
    echo -e "    ${YELLOW}  curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh${NC}"
fi

if [[ "$HAS_COSIGN" == false && "$HAS_TRIVY" == false ]]; then
    echo ""
    log_fail "No verification tools available. Install cosign and/or trivy to proceed."
    echo ""
    echo -e "${BOLD}Summary: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}, ${YELLOW}$SKIP skipped${NC}"
    exit 1
fi

# =============================================================================
# Section 2: Image Signing / Verification (cosign)
# =============================================================================

section "Image Signing & Verification"

if [[ "$HAS_COSIGN" == false ]]; then
    log_skip "Skipping image signing/verification (cosign not installed)"
else
    if [[ "$MODE" == "sign" ]]; then
        # Resolve private key
        COSIGN_KEY_FILE=""
        if [[ -n "${COSIGN_KEY:-}" ]]; then
            COSIGN_KEY_FILE="$COSIGN_KEY"
            log_info "Using key from COSIGN_KEY env var: $COSIGN_KEY_FILE"
        elif [[ -f "$PROJECT_ROOT/cosign.key" ]]; then
            COSIGN_KEY_FILE="$PROJECT_ROOT/cosign.key"
            log_info "Using key from project root: $COSIGN_KEY_FILE"
        else
            log_fail "No signing key found. Set COSIGN_KEY env var or place cosign.key in project root."
        fi

        if [[ -n "$COSIGN_KEY_FILE" ]]; then
            for image in "${IMAGES[@]}"; do
                log_info "Signing ${image}:latest ..."
                if cosign sign --key "$COSIGN_KEY_FILE" "${image}:latest" 2>"$REPORT_DIR/cosign-sign-${image}.log"; then
                    log_pass "Signed ${image}:latest"
                else
                    log_fail "Failed to sign ${image}:latest (see $REPORT_DIR/cosign-sign-${image}.log)"
                fi
            done
        fi

    else
        # Verify mode (default)
        COSIGN_PUB_FILE=""
        if [[ -n "${COSIGN_PUB:-}" ]]; then
            COSIGN_PUB_FILE="$COSIGN_PUB"
            log_info "Using public key from COSIGN_PUB env var: $COSIGN_PUB_FILE"
        elif [[ -f "$PROJECT_ROOT/cosign.pub" ]]; then
            COSIGN_PUB_FILE="$PROJECT_ROOT/cosign.pub"
            log_info "Using public key from project root: $COSIGN_PUB_FILE"
        else
            log_fail "No public key found. Set COSIGN_PUB env var or place cosign.pub in project root."
        fi

        if [[ -n "$COSIGN_PUB_FILE" ]]; then
            for image in "${IMAGES[@]}"; do
                log_info "Verifying ${image}:latest ..."
                if cosign verify --key "$COSIGN_PUB_FILE" "${image}:latest" >"$REPORT_DIR/cosign-verify-${image}.json" 2>"$REPORT_DIR/cosign-verify-${image}.log"; then
                    log_pass "Signature verified for ${image}:latest"
                else
                    log_fail "Signature verification failed for ${image}:latest (see $REPORT_DIR/cosign-verify-${image}.log)"
                fi
            done
        fi
    fi
fi

# =============================================================================
# Section 3: SBOM Generation (trivy)
# =============================================================================

section "SBOM Generation"

if [[ "$HAS_TRIVY" == false ]]; then
    log_skip "Skipping SBOM generation (trivy not installed)"
else
    for image in "${IMAGES[@]}"; do
        sbom_file="$REPORT_DIR/sbom-${image}.spdx.json"
        log_info "Generating SPDX SBOM for ${image}:latest ..."

        if trivy image --format spdx-json -o "$sbom_file" "${image}:latest" 2>"$REPORT_DIR/sbom-${image}.log"; then
            log_pass "SBOM generated: $sbom_file"

            # Attach SBOM if signing mode and cosign available
            if [[ "$MODE" == "sign" && "$HAS_COSIGN" == true ]]; then
                log_info "Attaching SBOM to ${image}:latest ..."
                if cosign attach sbom --sbom "$sbom_file" "${image}:latest" 2>"$REPORT_DIR/sbom-attach-${image}.log"; then
                    log_pass "SBOM attached to ${image}:latest"
                else
                    log_fail "Failed to attach SBOM to ${image}:latest (see $REPORT_DIR/sbom-attach-${image}.log)"
                fi
            fi
        else
            log_fail "SBOM generation failed for ${image}:latest (see $REPORT_DIR/sbom-${image}.log)"
        fi
    done
fi

# =============================================================================
# Section 4: Vulnerability Summary
# =============================================================================

section "Vulnerability Summary"

if [[ "$HAS_TRIVY" == false ]]; then
    log_skip "Skipping vulnerability scan (trivy not installed)"
else
    for image in "${IMAGES[@]}"; do
        vuln_file="$REPORT_DIR/vulns-${image}.json"
        log_info "Scanning ${image}:latest for CRITICAL/HIGH vulnerabilities ..."

        if trivy image --severity CRITICAL,HIGH --format json -o "$vuln_file" "${image}:latest" 2>"$REPORT_DIR/vulns-${image}.log"; then
            # Extract vulnerability counts from trivy JSON output
            if command -v jq &>/dev/null; then
                critical_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "$vuln_file" 2>/dev/null || echo "0")
                high_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' "$vuln_file" 2>/dev/null || echo "0")
            else
                # Fallback: rough count via grep
                critical_count=$(grep -c '"CRITICAL"' "$vuln_file" 2>/dev/null || echo "0")
                high_count=$(grep -c '"HIGH"' "$vuln_file" 2>/dev/null || echo "0")
            fi

            if [[ "$critical_count" -gt 0 ]]; then
                log_fail "${image}: ${critical_count} CRITICAL, ${high_count} HIGH vulnerabilities"
            elif [[ "$high_count" -gt 0 ]]; then
                log_fail "${image}: ${critical_count} CRITICAL, ${high_count} HIGH vulnerabilities"
            else
                log_pass "${image}: 0 CRITICAL, 0 HIGH vulnerabilities"
            fi
            log_info "Full report: $vuln_file"
        else
            log_fail "Vulnerability scan failed for ${image}:latest (see $REPORT_DIR/vulns-${image}.log)"
        fi
    done
fi

# =============================================================================
# Section 5: License Check
# =============================================================================

section "License Check"

# Strong copyleft: GPL, AGPL, SSPL — these require releasing derivative source code
STRONG_COPYLEFT_PATTERNS="^GPL-|^AGPL-|^SSPL|^CC-BY-SA|^OSL"
# Weak copyleft: LGPL, MPL, EPL, EUPL — allow linking without viral effect (normal for Java projects)
WEAK_COPYLEFT_PATTERNS="^LGPL|^MPL|^EPL|^EUPL"

if [[ "$HAS_TRIVY" == false ]]; then
    log_skip "Skipping license scan (trivy not installed)"
else
    for image in "${IMAGES[@]}"; do
        license_file="$REPORT_DIR/licenses-${image}.json"
        log_info "Scanning ${image}:latest for licenses ..."

        if trivy image --scanners license --format json -o "$license_file" "${image}:latest" 2>"$REPORT_DIR/licenses-${image}.log"; then
            # Check for strong copyleft licenses (FAIL)
            strong_copyleft=""
            weak_copyleft=""
            if command -v jq &>/dev/null; then
                strong_copyleft=$(jq -r '
                    [.Results[]?.Licenses[]? | select(.Name | test("'"$STRONG_COPYLEFT_PATTERNS"'"; "i"))]
                    | if length > 0 then
                        map("\(.PkgName // "unknown"): \(.Name)")
                        | join("\n")
                      else
                        ""
                      end
                ' "$license_file" 2>/dev/null || echo "")
                weak_copyleft=$(jq -r '
                    [.Results[]?.Licenses[]? | select(.Name | test("'"$WEAK_COPYLEFT_PATTERNS"'"; "i"))]
                    | if length > 0 then
                        map("\(.PkgName // "unknown"): \(.Name)")
                        | join("\n")
                      else
                        ""
                      end
                ' "$license_file" 2>/dev/null || echo "")
            else
                strong_copyleft=$(grep -iE "$STRONG_COPYLEFT_PATTERNS" "$license_file" 2>/dev/null || echo "")
                weak_copyleft=$(grep -iE "$WEAK_COPYLEFT_PATTERNS" "$license_file" 2>/dev/null || echo "")
            fi

            if [[ -n "$strong_copyleft" ]]; then
                log_fail "${image}: Strong copyleft licenses detected (GPL/AGPL/SSPL):"
                while IFS= read -r line; do
                    [[ -n "$line" ]] && echo -e "    ${RED}-${NC} $line"
                done <<< "$strong_copyleft"
            elif [[ -n "$weak_copyleft" ]]; then
                # Weak copyleft (LGPL, MPL, EPL) is normal for Java projects — WARN, not FAIL
                log_pass "${image}: Only weak copyleft licenses found (LGPL/MPL/EPL — safe for linking)"
                echo -e "    ${YELLOW}[WARN]${NC} Weak copyleft licenses (no action required for linked dependencies):"
                while IFS= read -r line; do
                    [[ -n "$line" ]] && echo -e "    ${YELLOW}-${NC} $line"
                done <<< "$weak_copyleft"
            else
                log_pass "${image}: No copyleft licenses found"
            fi
            log_info "Full license report: $license_file"
        else
            log_fail "License scan failed for ${image}:latest (see $REPORT_DIR/licenses-${image}.log)"
        fi
    done
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}Summary${NC}"
echo -e "${BOLD}============================================${NC}"
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"
echo -e "  ${YELLOW}SKIP: $SKIP${NC}"
echo -e "  Reports: $REPORT_DIR/"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo -e "${RED}${BOLD}Image provenance verification completed with failures.${NC}"
    exit 1
else
    echo -e "${GREEN}${BOLD}Image provenance verification completed successfully.${NC}"
    exit 0
fi
