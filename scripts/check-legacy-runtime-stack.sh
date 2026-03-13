#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$ROOT_DIR/chronicle-web/src"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "check-legacy-runtime-stack: target directory not found: $TARGET_DIR"
  exit 1
fi

declare -a TARGET_PATHS=(
  "containers/study"
  "containers/survey"
  "containers/tud"
  "containers/participant"
  "containers/questionnaire"
  "containers/questionnaires"
)

declare -a PATTERNS=(
  "from ['\\\"]lattice-ui-kit['\\\"]"
  "from ['\\\"]@material-ui"
  "from ['\\\"]styled-components"
  "from ['\\\"]styled-components/"
  "from ['\\\"]redux-reqseq['\\\"]"
  "import \\{ .*RequestStates"
  "import .* from 'immutable'"
  "import .* from \"immutable\""
  "from 'redux-immutable'"
  "from \"redux-immutable\""
)

declare -A FOUND=()
HAS_ISSUES=0

for path in "${TARGET_PATHS[@]}"; do
  for pattern in "${PATTERNS[@]}"; do
    matches="$(cd "$TARGET_DIR" && rg -n --multiline -g '*.js' -g '*.jsx' -g '*.ts' -g '*.tsx' "$pattern" "$path" || true)"
    if [[ -n "$matches" ]]; then
      # Exclude commented lines only.
      active_matches="$(printf "%s\n" "$matches" | rg -v '^\s*//')"
      if [[ -n "$active_matches" ]]; then
        echo
        echo "==> $path has legacy runtime dependency markers"
        echo "$active_matches"
        HAS_ISSUES=1
      fi
    fi
  done
done

if [[ "$HAS_ISSUES" -ne 0 ]]; then
  echo
  echo "check-legacy-runtime-stack: legacy runtime stack markers found in targeted families."
  echo "Use this as an active migration list for route modernization."
  exit 1
fi

echo "check-legacy-runtime-stack: no active lattice-ui-kit/material-ui/styled-components/redux-reqseq/immutable imports in targeted families."
