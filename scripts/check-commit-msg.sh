#!/usr/bin/env bash
# Conventional Commits gate for commit messages (lefthook commit-msg hook).
#
#   <type>(<scope>)!: <subject>          e.g.  fix(web): keep the language switcher off the diary
#
# type    feat fix refactor perf docs test build ci chore revert style
# scope   optional, lowercase (web, android, ios, server, api, models, selfhost, docs, ...)
# subject imperative, lowercase first letter, no trailing period, whole line <= 72 chars
# body    optional; blank line after the subject; lines <= 72 unless they are a URL/path
#
# Exempt: merge commits, fixup!/squash! (they are squashed before push),
# and git's own revert messages.
set -euo pipefail
file="${1:?commit message file}"
subject="$(grep -v '^#' "$file" | sed -n '1p')"
types='feat|fix|refactor|perf|docs|test|build|ci|chore|revert|style'
case "$subject" in
  "Merge "*|"fixup! "*|"squash! "*|"Revert \""*) exit 0 ;;
esac
err() { printf 'commit-msg: %s\n  subject: %s\n  format:  <type>(<scope>)!: <imperative, lowercase subject>   types: %s\n' "$1" "$subject" "${types//|/ }" >&2; exit 1; }
[[ "$subject" =~ ^($types)(\([a-z0-9._/-]+\))?!?:\ [a-z0-9] ]] || err "subject must start with a Conventional Commits type"
[[ ${#subject} -le 72 ]] || err "subject is ${#subject} characters (max 72)"
[[ "$subject" != *. ]] || err "subject must not end with a period"
second="$(grep -v '^#' "$file" | sed -n '2p')"
[[ -z "$second" ]] || err "leave a blank line between the subject and the body"
{ grep -v '^#' "$file" | sed '1,2d' | grep -vE 'https?://|^[[:space:]]*[A-Za-z0-9_./-]+$' || true; } \
  | awk 'length > 72 { bad=1 } END { exit bad }' || err "wrap body lines at 72 characters"
