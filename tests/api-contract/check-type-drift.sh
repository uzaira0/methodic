#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# API Contract Drift Detection
#
# Compares TypeScript type definitions in the frontend against the OpenAPI
# spec to detect field-level drift. This is a LOCAL-ONLY tool — not used
# in CI.
#
# Usage:  ./check-type-drift.sh [--verbose]
# ---------------------------------------------------------------------------
set -euo pipefail

SPEC_FILE="/opt/chronicle/chronicle-api/chronicle.yaml"
TYPES_FILE="/opt/chronicle/chronicle-web/src/modern/state/study-operations-api.ts"
VERBOSE="${1:-}"
DRIFT_COUNT=0

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if [ ! -f "$SPEC_FILE" ]; then
  yellow "OpenAPI spec not found at $SPEC_FILE — skipping drift check."
  exit 0
fi
if [ ! -f "$TYPES_FILE" ]; then
  yellow "TypeScript types file not found at $TYPES_FILE — skipping drift check."
  exit 0
fi

bold "=== API Contract Drift Detection ==="
echo ""
echo "OpenAPI spec : $SPEC_FILE"
echo "TS types     : $TYPES_FILE"
echo ""

# ---------------------------------------------------------------------------
# Extract OpenAPI schema names
# ---------------------------------------------------------------------------
bold "--- OpenAPI component schemas ---"
SPEC_SCHEMAS=$(awk '/^  schemas:/,0 { if (/^    [A-Za-z]/ && !/properties|type|description|format|enum|items|additionalProperties|required|discriminator|nullable/) print }' "$SPEC_FILE" \
  | sed 's/://g' | awk '{print $1}' | sort -u)
echo "$SPEC_SCHEMAS" | while read -r name; do echo "  $name"; done
echo ""

# ---------------------------------------------------------------------------
# Extract TypeScript exported types
# ---------------------------------------------------------------------------
bold "--- Frontend TypeScript types ---"
TS_TYPES=$(grep -E '^export type [A-Z]' "$TYPES_FILE" | sed 's/export type //' | sed 's/ =.*//' | sort -u)
echo "$TS_TYPES" | while read -r name; do echo "  $name"; done
echo ""

# ---------------------------------------------------------------------------
# Helper: extract fields from OpenAPI schema block
# ---------------------------------------------------------------------------
extract_spec_fields() {
  local schema_name="$1"
  awk -v name="    ${schema_name}:" '
    $0 ~ name { found=1; next }
    found && /^      properties:/ { props=1; next }
    found && props && /^        [a-zA-Z]/ { gsub(/:.*/, ""); gsub(/^ +/, ""); print }
    found && props && /^    [a-zA-Z]/ { exit }
    found && props && /^  [a-zA-Z]/ { exit }
  ' "$SPEC_FILE" | sort -u
}

# ---------------------------------------------------------------------------
# Helper: extract fields from TypeScript type block
# ---------------------------------------------------------------------------
extract_ts_fields() {
  local type_name="$1"
  awk -v name="export type ${type_name} " '
    $0 ~ name { found=1; next }
    found && /^};/ { exit }
    found && /^  [a-zA-Z]/ { gsub(/[?:].*/,""); gsub(/^ +/,""); print }
  ' "$TYPES_FILE" | sort -u
}

# ---------------------------------------------------------------------------
# Compare fields for matched model pairs
# ---------------------------------------------------------------------------
bold "--- Field-level drift analysis ---"
echo ""

# Define model pairs: OpenAPI name -> TypeScript name
declare -A MODEL_MAP=(
  ["Study"]="StudySummary"
  ["StudyUpdate"]="StudyUpdatePayload"
  ["Candidate"]="Candidate"
  ["Participant"]="Participant"
  ["ParticipantStats"]="ParticipantStats"
  ["Questionnaire"]="QuestionnaireRecord"
  ["AndroidDeviceSensorAvailability"]="AndroidDeviceSensorAvailability"
)

for spec_name in $(echo "${!MODEL_MAP[@]}" | tr ' ' '\n' | sort); do
  ts_name="${MODEL_MAP[$spec_name]}"
  bold "  $spec_name (spec) <-> $ts_name (TypeScript)"

  spec_fields=$(extract_spec_fields "$spec_name")
  ts_fields=$(extract_ts_fields "$ts_name")

  if [ -z "$spec_fields" ]; then
    yellow "    Could not extract fields from OpenAPI spec for '$spec_name'"
    echo ""
    continue
  fi
  if [ -z "$ts_fields" ]; then
    yellow "    Could not extract fields from TypeScript for '$ts_name'"
    echo ""
    continue
  fi

  # Fields in spec but not in TypeScript
  spec_only=$(comm -23 <(echo "$spec_fields") <(echo "$ts_fields") 2>/dev/null || true)
  # Fields in TypeScript but not in spec
  ts_only=$(comm -13 <(echo "$spec_fields") <(echo "$ts_fields") 2>/dev/null || true)
  # Fields in both
  common=$(comm -12 <(echo "$spec_fields") <(echo "$ts_fields") 2>/dev/null || true)

  if [ -n "$spec_only" ]; then
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    red "    DRIFT: Fields in OpenAPI spec but missing from TypeScript:"
    echo "$spec_only" | while read -r f; do echo "      - $f"; done
  fi

  if [ -n "$ts_only" ]; then
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    yellow "    DRIFT: Fields in TypeScript but missing from OpenAPI spec:"
    echo "$ts_only" | while read -r f; do echo "      + $f"; done
  fi

  if [ -z "$spec_only" ] && [ -z "$ts_only" ]; then
    green "    OK — fields match"
  fi

  if [ "$VERBOSE" = "--verbose" ] && [ -n "$common" ]; then
    echo "    Common fields:"
    echo "$common" | while read -r f; do echo "      = $f"; done
  fi

  echo ""
done

# ---------------------------------------------------------------------------
# Check ParticipationStatus enum values
# ---------------------------------------------------------------------------
bold "--- Enum drift: ParticipationStatus ---"

spec_statuses=$(sed -n '/^    ParticipationStatus:/,/^    [A-Z]/p' "$SPEC_FILE" \
  | grep 'enum:' | sed 's/.*\[//;s/\].*//;s/,/\n/g' | tr -d ' ' | sort -u || true)
ts_statuses=$(grep "ParticipationStatus = " "$TYPES_FILE" \
  | sed "s/.*= //;s/'//g;s/|/\n/g;s/;//" | tr -d ' ' | sort -u || true)

spec_enum_only=$(comm -23 <(echo "$spec_statuses") <(echo "$ts_statuses") 2>/dev/null || true)
ts_enum_only=$(comm -13 <(echo "$spec_statuses") <(echo "$ts_statuses") 2>/dev/null || true)

if [ -n "$spec_enum_only" ]; then
  DRIFT_COUNT=$((DRIFT_COUNT + 1))
  red "  DRIFT: Statuses in spec but not TypeScript:"
  echo "$spec_enum_only" | while read -r s; do echo "    - $s"; done
fi
if [ -n "$ts_enum_only" ]; then
  DRIFT_COUNT=$((DRIFT_COUNT + 1))
  yellow "  DRIFT: Statuses in TypeScript but not spec:"
  echo "$ts_enum_only" | while read -r s; do echo "    + $s"; done
fi
if [ -z "$spec_enum_only" ] && [ -z "$ts_enum_only" ]; then
  green "  OK — enum values match"
fi
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
bold "=== Summary ==="
if [ "$DRIFT_COUNT" -gt 0 ]; then
  yellow "Found $DRIFT_COUNT drift issue(s). Review the differences above."
  yellow "Not all drift is a bug — the frontend may intentionally reshape API data."
  exit 0
else
  green "No drift detected between OpenAPI spec and TypeScript types."
fi
