#!/usr/bin/env bash
set -euo pipefail

server_dir=chronicle-server
since=
migrations=src/main/resources/db/migration
fail() { printf 'FAIL setup: %s\n' "$*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --server-dir|--since)
      if (($# < 2)) || [[ -z "$2" ]]; then fail "$1 requires a value"; fi
      if [[ "$1" == --server-dir ]]; then server_dir=$2; else since=$2; fi
      shift 2 ;;
    -h|--help)
      printf 'Usage: %s [--server-dir chronicle-server] [--since <git ref>]\n' "$0"
      exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
cd "$server_dir" || fail "cannot open server directory: $server_dir"
[[ -d "$migrations" ]] || fail "missing $migrations"
if [[ -z "$since" ]]; then
  tags=$(git tag --list 'published-*' --sort=-creatordate) || fail 'cannot list tags'
  since=${tags%%$'\n'*}
  if [[ -z "$since" ]]; then
    roots=$(git rev-list --max-parents=0 HEAD) || fail 'cannot find root commit'
    since=${roots%%$'\n'*}
  fi
fi
base=$(git rev-parse --verify --end-of-options "${since}^{commit}") || fail "invalid baseline: $since"
# Disable rename detection so a renamed published file always appears as a deletion.
changes=$(git -c core.quotePath=false diff --no-ext-diff --no-renames --name-status "$base" -- "$migrations") || fail 'cannot diff migrations'
untracked=$(git -c core.quotePath=false ls-files --others --exclude-standard -- "$migrations") || fail 'cannot list new migrations'
published=$(git ls-tree -r --name-only "$base" -- "$migrations") || fail 'cannot list published migrations'
added=()
immutable=PASS
while IFS=$'\t' read -r status file; do
  [[ -n "$status" ]] || continue
  if [[ "$status" == A ]]; then
    added+=("$file")
  else
    immutable=FAIL
    printf 'FAIL immutability: %s %s\n' "$status" "$file"
  fi
done <<< "$changes"
while IFS= read -r file; do
  [[ -n "$file" ]] && added+=("$file")
done <<< "$untracked"
printf '%s immutability (a): baseline %s\n' "$immutable" "$since"

additive=PASS
numbering=PASS
# Two added migrations sharing a version both beat the published maximum, so check them against each other too.
duplicates=$(for file in "${added[@]}"; do
  name=${file##*/}
  [[ "$name" == V*__*.sql ]] || continue
  version=${name#V}; version=${version%%__*}
  awk -v v="$version" 'BEGIN { n=split(v,p,/[._]/); out=""
    for (i=1; i<=n; i++) { sub(/^0+/, "", p[i]); out = out (i>1 ? "." : "") (p[i] == "" ? "0" : p[i]) }
    print out }'
done | sort | uniq -d)
if [[ -n "$duplicates" ]]; then
  numbering=FAIL
  while IFS= read -r version; do
    printf 'FAIL numbering: duplicate version V%s among added migrations\n' "$version"
  done <<< "$duplicates"
fi
for file in "${added[@]}"; do
  [[ "$file" == *.sql ]] || continue
  if [[ ! -f "$file" || -L "$file" ]]; then
    printf 'FAIL additive-only: %s:1: migration must be a regular SQL file\n' "$file"
    additive=FAIL
    continue
  fi
  if ! awk '
    function hit(line, reason) {
      printf "%s additive-only: %s:%d: %s%s\n", approved ? "PASS" : "FAIL", FILENAME, line, reason, approved ? " (approved: " approval ")" : ""
      if (!approved) failed = 1
    }
    function statement(words,lines,n,   i,j,reason,has_where,depth) {
      for (i=1; i<=n; i++) {
        reason = ""
        if (words[i] == "DROP" && words[i+1] ~ /^(TABLE|COLUMN)$/)
          reason = "DROP " words[i+1]
        else if (words[i] == "TRUNCATE") reason = "TRUNCATE"
        else if (words[i] == "RENAME" && words[i+1] ~ /^(TO|COLUMN)$/)
          reason = "RENAME " words[i+1]
        else if (words[i] == "ALTER" && words[i+1] == "TABLE") {
          for (j=i+2; j<=n; j++)
            if (words[j] == "DROP" && words[j+1] !~ /^(TABLE|COLUMN)$/) hit(lines[j], "ALTER TABLE ... DROP")
        } else if (words[i] == "ALTER" && words[i+1] == "COLUMN") {
          for (j=i+2; j<=n && words[j] != ","; j++)
            if (words[j] == "TYPE") { reason = "ALTER COLUMN ... TYPE"; break }
        } else if (words[i] == "DELETE" && words[i+1] == "FROM") {
          has_where = 0; depth = 0
          for (j=i+2; j<=n; j++) {
            if (words[j] == "(") depth++
            if (words[j] == ")") { if (!depth) break; depth-- }
            if (words[j] == "WHERE" && !depth) has_where = 1
          }
          if (!has_where) reason = "DELETE FROM without WHERE"
        }
        if (reason != "") hit(lines[i], reason)
      }
      delete words; delete lines
    }
    # Conservatively check SQL text in string literals too (e.g. EXECUTE SQL).
    # Keep its WHERE tokens separate from the containing statement.
    function literal_sql(text,line,   tokens,locations,count,c,t) {
      while (length(text)) {
        c=substr(text,1,1)
        if (c == "\n") line++
        if (match(text, /^[A-Za-z_0-9]+/)) {
          t=substr(text,1,RLENGTH); text=substr(text,RLENGTH+1)
          tokens[++count]=toupper(t); locations[count]=line
          continue
        }
        if (c == ";") { statement(tokens,locations,count); count=0 }
        else if (c !~ /[[:space:]]/) { tokens[++count]=c; locations[count]=line }
        text=substr(text,2)
      }
      statement(tokens,locations,count)
    }
    function token() {
      if (word != "") { words[++n] = toupper(word); lines[n] = wordline; word = "" }
    }
    BEGIN { header = 1; quote = sprintf("%c", 39) }
    {
      # Only a real leading line comment, before SQL, can record approval.
      if (header && !block && !quoted && $0 ~ /^[[:space:]]*-- chronicle:destructive-approved[[:space:]]+[^[:space:]]/) {
        approved = 1; approval = $0
        sub(/^[[:space:]]*-- chronicle:destructive-approved[[:space:]]+/, "", approval)
      }
      for (p=1; p<=length($0); p++) {
        c = substr($0,p,1); pair = substr($0,p,2)
        if (block) {
          if (pair == "/*") { block++; p++ }
          else if (pair == "*/") { block--; p++ }
          continue
        }
        if (quoted) {
          if (c == quoted) {
            if (substr($0,p+1,1) == quoted) { literal = literal c; p++ }
            else {
              if (quoted == quote) literal_sql(literal,literal_line)
              quoted = ""
            }
          } else literal = literal c
          continue
        }
        if (pair == "--") { token(); break }
        if (pair == "/*") { token(); block++; p++; continue }
        if (c ~ /[[:space:]]/) { token(); continue }
        header = 0
        if (c == quote || c == "\"") {
          token(); quoted = c; literal = ""; literal_line = NR
          words[++n] = "<quoted>"; lines[n] = NR; continue
        }
        # Dollar-quoted function bodies are scanned as SQL, including their statements.
        if (c == "$" && match(substr($0,p), /^\$([A-Za-z_][A-Za-z_0-9]*)?\$/)) {
          token(); p += RLENGTH-1; continue
        }
        if (c ~ /[A-Za-z_0-9]/) {
          if (word == "") wordline = NR
          word = word c
        } else {
          token()
          if (c == ";") { statement(words,lines,n); n=0 }
          else { words[++n] = c; lines[n] = NR }
        }
      }
      token()
      if (quoted) literal = literal "\n"
    }
    END {
      statement(words,lines,n)
      if (block || quoted) {
        printf "FAIL additive-only: %s:%d: unterminated SQL comment or quote\n", FILENAME, NR
        failed = 1
      }
      exit failed
    }
  ' "$file"; then additive=FAIL; fi

  if ! awk -v candidate="${file##*/}" -v path="$file" '
    function version(name) { sub(/^.*\//, "", name); sub(/^V/, "", name); sub(/__.*/, "", name); return name }
    function greater(a,b,   x,y,n,m,i) {
      n=split(a,x,/[._]/); m=split(b,y,/[._]/)
      for (i=1; i<=n || i<=m; i++) {
        sub(/^0+/, "", x[i]); sub(/^0+/, "", y[i])
        if (length(x[i]) != length(y[i])) return length(x[i]) > length(y[i])
        if ("x" x[i] != "x" y[i]) return "x" x[i] > "x" y[i]
      }
      return 0
    }
    /\/V[0-9]+([._][0-9]+)*__.*\.sql$/ {
      v=version($0); if (maximum == "" || greater(v,maximum)) maximum=v
    }
    END {
      if (candidate !~ /^V[0-9]+([._][0-9]+)*__.+\.sql$/) {
        printf "FAIL numbering: %s: invalid versioned migration name\n", path; exit 1
      }
      if (maximum != "" && !greater(version(candidate),maximum)) {
        printf "FAIL numbering: %s: version must exceed published V%s\n", path, maximum; exit 1
      }
    }
  ' <<< "$published"; then numbering=FAIL; fi
done
printf '%s additive-only (b)\n' "$additive"
printf '%s numbering (c)\n' "$numbering"
[[ "$immutable" == PASS && "$additive" == PASS && "$numbering" == PASS ]]
