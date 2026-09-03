#!/bin/bash
# Chronicle Key Recovery Script
# Reconstructs TDE principal key or backup encryption key from Shamir shares.
#
# Usage:
#   ./key-recovery.sh --type <tde|backup> --shares <share1> <share2> <share3> [...]
#   ./key-recovery.sh --type tde --shares share-1.txt share-3.txt share-5.txt
#   ./key-recovery.sh --type tde --shares share-1.txt share-3.txt share-5.txt --write-keyring
#   ./key-recovery.sh --type backup --shares share-1.txt share-2.txt share-4.txt --write-key-file
#
# Requires: ssss-combine (from ssss package) OR Python 3
#
# HIPAA §164.312(a)(2)(iv) — Encryption key management

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
KEY_TYPE=""
SHARE_FILES=()
WRITE_KEYRING=false
WRITE_KEY_FILE=false
FINGERPRINT=""
SHARES_THRESHOLD=3

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()      { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
log_ok()   { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}OK${NC} $*"; }
log_err()  { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}ERROR${NC} $*" >&2; }
log_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}WARN${NC} $*"; }

usage() {
    echo "Usage: $0 --type <tde|backup> --shares <file1> <file2> <file3> [options]"
    echo ""
    echo "Options:"
    echo "  --type <tde|backup>     Which key to recover"
    echo "  --shares <files...>     At least ${SHARES_THRESHOLD} share files"
    echo "  --fingerprint <sha256>  Expected key fingerprint for validation"
    echo "  --write-keyring         Write recovered TDE key to the TDE keyring (type=tde only)"
    echo "  --write-key-file        Write recovered backup key to /etc/chronicle/backup-encryption-key"
    exit 1
}

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)
            KEY_TYPE="$2"; shift 2 ;;
        --shares)
            shift
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                SHARE_FILES+=("$1"); shift
            done
            ;;
        --fingerprint)
            FINGERPRINT="$2"; shift 2 ;;
        --write-keyring)
            WRITE_KEYRING=true; shift ;;
        --write-key-file)
            WRITE_KEY_FILE=true; shift ;;
        --help|-h)
            usage ;;
        *)
            log_err "Unknown option: $1"; usage ;;
    esac
done

# ── Validate inputs ──────────────────────────────────────────────────────────
if [ -z "$KEY_TYPE" ]; then
    log_err "--type is required (tde or backup)"
    usage
fi

if [ "$KEY_TYPE" != "tde" ] && [ "$KEY_TYPE" != "backup" ]; then
    log_err "Invalid key type: $KEY_TYPE (must be 'tde' or 'backup')"
    usage
fi

if [ "${#SHARE_FILES[@]}" -lt "$SHARES_THRESHOLD" ]; then
    log_err "At least ${SHARES_THRESHOLD} share files are required (got ${#SHARE_FILES[@]})"
    usage
fi

for f in "${SHARE_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        log_err "Share file not found: $f"
        exit 1
    fi
done

# ── Detect Shamir tool ────────────────────────────────────────────────────────
SHAMIR_TOOL=""
if command -v ssss-combine >/dev/null 2>&1; then
    SHAMIR_TOOL="ssss"
    log "Using ssss-combine for Shamir secret sharing"
elif command -v python3 >/dev/null 2>&1; then
    SHAMIR_TOOL="python"
    log "Using Python 3 for Shamir secret sharing"
else
    log_err "Neither ssss-combine nor python3 found."
    exit 1
fi

# ── Python-based Shamir combine (GF(256)) ────────────────────────────────────
python_combine() {
    local threshold="$1"
    shift
    local share_files=("$@")

    local shares_data=""
    for f in "${share_files[@]}"; do
        shares_data+="$(cat "$f")"$'\n'
    done

    python3 <<PYEOF
import sys

threshold = ${threshold}

shares_raw = """${shares_data}""".strip().split('\n')

# Parse shares: index-hex
parsed = []
for s in shares_raw:
    if not s.strip():
        continue
    idx_str, hex_data = s.strip().split('-', 1)
    parsed.append((int(idx_str), bytes.fromhex(hex_data)))

def gf256_add(a, b):
    return a ^ b

def gf256_mul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = (a << 1) & 0xFF
        if hi:
            a ^= 0x1B
        b >>= 1
    return p

def gf256_inv(a):
    if a == 0:
        raise ValueError("Cannot invert 0")
    result = a
    for _ in range(6):
        result = gf256_mul(result, result)
        result = gf256_mul(result, a)
    return result

def lagrange_interpolate(shares_for_byte, t):
    secret = 0
    xs = [s[0] for s in shares_for_byte]
    ys = [s[1] for s in shares_for_byte]
    for i in range(t):
        num = ys[i]
        for j in range(t):
            if i == j:
                continue
            num = gf256_mul(num, xs[j])
            denom = gf256_add(xs[i], xs[j])
            num = gf256_mul(num, gf256_inv(denom))
        secret = gf256_add(secret, num)
    return secret

byte_len = len(parsed[0][1])
result = bytearray()
for pos in range(byte_len):
    shares_for_byte = [(x, data[pos]) for x, data in parsed[:threshold]]
    result.append(lagrange_interpolate(shares_for_byte, threshold))

print(result.hex())
PYEOF
}

# ── Reconstruct key ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== Reconstructing ${KEY_TYPE^^} Key from ${#SHARE_FILES[@]} shares ===${NC}"

RECOVERED_KEY=""

if [ "$SHAMIR_TOOL" = "ssss" ]; then
    # ssss-combine reads shares from stdin
    SHARES_INPUT=""
    for f in "${SHARE_FILES[@]}"; do
        SHARES_INPUT+="$(cat "$f")"$'\n'
    done
    RECOVERED_KEY=$(echo "$SHARES_INPUT" | head -n "$SHARES_THRESHOLD" | ssss-combine -t "$SHARES_THRESHOLD" -x -Q 2>/dev/null)
else
    # Use only threshold number of shares
    SELECTED_FILES=("${SHARE_FILES[@]:0:$SHARES_THRESHOLD}")
    RECOVERED_KEY=$(python_combine "$SHARES_THRESHOLD" "${SELECTED_FILES[@]}")
fi

if [ -z "$RECOVERED_KEY" ]; then
    log_err "Failed to reconstruct key"
    exit 1
fi

log_ok "Key reconstructed successfully"

# ── Validate fingerprint ─────────────────────────────────────────────────────
RECOVERED_FINGERPRINT=$(echo -n "$RECOVERED_KEY" | sha256sum | awk '{print $1}')
log "Recovered key fingerprint: ${RECOVERED_FINGERPRINT}"

if [ -n "$FINGERPRINT" ]; then
    if [ "$RECOVERED_FINGERPRINT" = "$FINGERPRINT" ]; then
        log_ok "Fingerprint matches expected value"
    else
        log_err "Fingerprint MISMATCH!"
        log_err "  Expected: $FINGERPRINT"
        log_err "  Got:      $RECOVERED_FINGERPRINT"
        log_err "The shares may be corrupted or from different key ceremonies"
        exit 1
    fi
else
    log_warn "No --fingerprint provided; cannot validate key correctness"
    log_warn "Compare this fingerprint against your ceremony-record.json"
fi

# ── Write key to destination ──────────────────────────────────────────────────
if [ "$KEY_TYPE" = "tde" ] && [ "$WRITE_KEYRING" = true ]; then
    echo ""
    log "Writing TDE key to keyring..."

    CONTAINER="chronicle-postgres"
    if ! docker inspect "$CONTAINER" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
        log_err "PostgreSQL container '$CONTAINER' is not running"
        log_err "Start PostgreSQL first, then re-run with --write-keyring"
        exit 1
    fi

    # Write the key hex to a temp file, copy into container keyring directory
    TMP_KEY=$(mktemp)
    echo -n "$RECOVERED_KEY" > "$TMP_KEY"
    docker cp "$TMP_KEY" "${CONTAINER}:/var/lib/postgresql/tde-keyring/recovered-principal-key"
    docker exec -u root "$CONTAINER" chown postgres:postgres /var/lib/postgresql/tde-keyring/recovered-principal-key
    docker exec -u root "$CONTAINER" chmod 600 /var/lib/postgresql/tde-keyring/recovered-principal-key
    rm -f "$TMP_KEY"

    log_ok "TDE key written to container keyring"
    log_warn "You may need to restart PostgreSQL and re-initialize the TDE provider"
fi

if [ "$KEY_TYPE" = "backup" ] && [ "$WRITE_KEY_FILE" = true ]; then
    echo ""
    log "Writing backup encryption key..."

    KEY_FILE="/etc/chronicle/backup-encryption-key"
    sudo mkdir -p /etc/chronicle

    # Convert hex back to the base64 format used by the backup script
    TMP_KEY=$(mktemp)
    echo "$RECOVERED_KEY" | xxd -r -p | base64 > "$TMP_KEY"
    sudo cp "$TMP_KEY" "$KEY_FILE"
    sudo chmod 600 "$KEY_FILE"
    sudo chown root:root "$KEY_FILE"
    rm -f "$TMP_KEY"

    log_ok "Backup encryption key written to $KEY_FILE"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== Recovery Summary ===${NC}"
echo "  Key type:    ${KEY_TYPE}"
echo "  Shares used: ${#SHARE_FILES[@]}"
echo "  Fingerprint: ${RECOVERED_FINGERPRINT}"
if [ "$WRITE_KEYRING" = true ] || [ "$WRITE_KEY_FILE" = true ]; then
    echo "  Key written to destination: YES"
else
    echo "  Key written to destination: NO (use --write-keyring or --write-key-file)"
fi
echo ""
echo -e "${YELLOW}SECURITY:${NC} The recovered key is in memory only (unless --write-* was used)."
echo "Do NOT log, copy, or store the key in plaintext beyond its intended destination."
echo ""
