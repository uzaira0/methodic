#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Chronicle Secret Detection ==="
echo "Scanning for leaked secrets with gitleaks..."

scan_log="$(mktemp)"
scan_source="$(mktemp -d)"
trap 'rm -rf "$scan_source"; rm -f "$scan_log"' EXIT

# Scan the current contents of every tracked or non-ignored source file while
# excluding ignored runtime material (private keys, generated WAF credentials,
# build outputs). Root gitlinks are copied separately so tar cannot recurse into
# ignored files inside submodules.
copy_worktree_files() {
  local repo="$1"
  local destination="$2"
  local skip_gitlinks="$3"
  local file_list
  file_list="$(mktemp)"
  mkdir -p "$destination"

  while IFS= read -r -d '' path; do
    if [[ "$skip_gitlinks" == "1" && -e "$repo/$path/.git" ]]; then
      continue
    fi
    printf '%s\0' "$path" >> "$file_list"
  done < <(git -C "$repo" ls-files --cached --others --exclude-standard -z)

  if [[ -s "$file_list" ]]; then
    tar -C "$repo" --null --files-from "$file_list" -cf - | tar -C "$destination" -xf -
  fi
  rm -f "$file_list"
}

copy_worktree_files "$ROOT_DIR" "$scan_source" 1
while read -r _ submodule_path; do
  if git -C "$ROOT_DIR/$submodule_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    copy_worktree_files "$ROOT_DIR/$submodule_path" "$scan_source/$submodule_path" 0
  fi
done < <(git -C "$ROOT_DIR" config -f .gitmodules --get-regexp '^submodule\..*\.path$')

gitleaks detect \
  --source "$scan_source" \
  --config "$SCRIPT_DIR/gitleaks.toml" \
  --verbose \
  --no-color \
  --no-git 2>&1 | tee "$scan_log"

if grep -Fq 'failed scan directory' "$scan_log"; then
  echo "ERROR: gitleaks could not read part of the source tree; refusing a partial success." >&2
  exit 1
fi

echo "No secrets detected"
