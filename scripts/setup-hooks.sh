#!/usr/bin/env bash
# Setup lefthook git hooks for the Chronicle monorepo.
# Usage: ./scripts/setup-hooks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

LEFTHOOK_VERSION="1.11.13"

# ── Check for lefthook ──────────────────────────────────────────────
if command -v lefthook &>/dev/null; then
  echo "lefthook found: $(lefthook version)"
else
  echo "lefthook not found. Installing v${LEFTHOOK_VERSION}..."

  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  ARCH="x86_64" ;;
    aarch64) ARCH="arm64"   ;;
    arm64)   ARCH="arm64"   ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
  esac

  INSTALL_DIR="${HOME}/.local/bin"
  mkdir -p "$INSTALL_DIR"

  URL="https://github.com/evilmartians/lefthook/releases/download/v${LEFTHOOK_VERSION}/lefthook_${LEFTHOOK_VERSION}_${OS}_${ARCH}"
  echo "Downloading from: $URL"
  curl -fsSL "$URL" -o "${INSTALL_DIR}/lefthook"
  chmod +x "${INSTALL_DIR}/lefthook"

  if ! command -v lefthook &>/dev/null; then
    echo ""
    echo "Installed to ${INSTALL_DIR}/lefthook"
    echo "Add ${INSTALL_DIR} to your PATH, then re-run this script."
    exit 1
  fi

  echo "lefthook $(lefthook version) installed."
fi

# ── Check for gitleaks ──────────────────────────────────────────────
if ! command -v gitleaks &>/dev/null; then
  echo ""
  echo "WARNING: gitleaks is not installed."
  echo "  Install: https://github.com/gitleaks/gitleaks#installing"
  echo "  The gitleaks pre-commit hook will fail until it is available."
  echo ""
fi

# ── Install hooks ───────────────────────────────────────────────────
echo "Installing lefthook hooks..."
lefthook install
echo ""
echo "Done. Git hooks are active."
echo ""
echo "Hooks configured:"
echo "  pre-commit:"
echo "    - biome check (staged .ts/.tsx/.js/.jsx in chronicle-web)"
echo "    - gitleaks secret detection"
echo "    - TypeScript typecheck [optional]"
echo "  pre-push:"
echo "    - bun run check (full lint + typecheck for chronicle-web)"
echo ""
echo "To skip hooks in an emergency: git commit --no-verify"
echo "To run manually:               lefthook run pre-commit"
