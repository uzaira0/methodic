#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$ROOT_DIR/scripts/check-migrations-safe.sh"
mkdir -p "$HOME/tmp"
FIXTURE=$(mktemp -d -p "$HOME/tmp" migration-safety.XXXXXX)
trap 'rm -rf -- "$FIXTURE"' EXIT
REPO="$FIXTURE/server"
MIGRATIONS="$REPO/src/main/resources/db/migration"
mkdir -p "$MIGRATIONS"
git init -q "$REPO"
git -C "$REPO" config user.name 'Migration safety fixture'
git -C "$REPO" config user.email 'migration-fixture@example.invalid'
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" config tag.gpgsign false
git -C "$REPO" config core.hooksPath /dev/null
for version in 1 2 10; do
  printf 'CREATE TABLE fixture_%s (id INTEGER);\n' "$version" > "$MIGRATIONS/V${version}__fixture.sql"
done
git -C "$REPO" add src
git -C "$REPO" commit -qm 'Published fixture migrations'
git -C "$REPO" tag published-test

assert_gate() {
  local expected=$1 label=$2 pattern=$3 result=0
  shift 3
  bash "$GATE" --server-dir "$REPO" "$@" > "$FIXTURE/output" 2>&1 || result=$?
  if { [[ "$expected" == pass ]] && ((result != 0)); } ||
     { [[ "$expected" == fail ]] && ((result == 0)); } ||
     ! grep -Eq "$pattern" "$FIXTURE/output"; then
    printf 'FAIL fixture: %s (exit %s)\n' "$label" "$result" >&2
    cat "$FIXTURE/output" >&2
    exit 1
  fi
  printf 'PASS fixture: %s\n' "$label"
}

NEW="$MIGRATIONS/V11__additive.sql"
cat > "$NEW" <<'SQL'
-- DROP TABLE fixture_1;
/* DROP COLUMN id;
   /* nested comment */ TRUNCATE fixture_2; */
ALTER TABLE fixture_1
    ADD COLUMN note TEXT;
DELETE FROM fixture_1
    WHERE id = 1;
SQL
assert_gate pass 'untracked additive SQL and comments' '^PASS additive-only \(b\)$'
git -C "$REPO" add src
assert_gate pass 'staged additive migration' '^PASS numbering \(c\)$'
git -C "$REPO" commit -qm 'Additive migration'
assert_gate pass 'committed additive migration' '^PASS immutability \(a\): baseline published-test$'

printf '\n-- edited after publication\n' >> "$MIGRATIONS/V1__fixture.sql"
assert_gate fail 'published edit (a)' '^FAIL immutability: M .*V1__fixture.sql$'
git -C "$REPO" show published-test:src/main/resources/db/migration/V1__fixture.sql > "$MIGRATIONS/V1__fixture.sql"
mv "$MIGRATIONS/V2__fixture.sql" "$MIGRATIONS/V12__renamed.sql"
assert_gate fail 'published rename/delete (a)' '^FAIL immutability: D .*V2__fixture.sql$'
mv "$MIGRATIONS/V12__renamed.sql" "$MIGRATIONS/V2__fixture.sql"

DANGEROUS="$MIGRATIONS/V12__destructive.sql"
printf 'ALTER TABLE fixture_1\n  DROP COLUMN note;\n' > "$DANGEROUS"
assert_gate fail 'DROP COLUMN with exact line (b)' '^FAIL additive-only: .*V12__destructive.sql:2: DROP COLUMN$'
printf '%s\n' '-- chronicle:destructive-approved Remove obsolete note after the prior release migrated consumers.' \
  'ALTER TABLE fixture_1 DROP COLUMN note;' > "$DANGEROUS"
assert_gate pass 'recorded destructive approval (b)' '^PASS additive-only: .*approved: Remove obsolete note'
printf '%s\n' '-- chronicle:destructive-approved   ' 'DROP TABLE fixture_1;' > "$DANGEROUS"
assert_gate fail 'empty approval rejected' '^FAIL additive-only \(b\)$'
printf '%s\n' 'SELECT 1;' '-- chronicle:destructive-approved Too late' 'DROP TABLE fixture_1;' > "$DANGEROUS"
assert_gate fail 'approval after SQL rejected' '^FAIL additive-only \(b\)$'
printf '%s\n' '/*' '-- chronicle:destructive-approved Hidden in a block' '*/' 'DROP TABLE fixture_1;' > "$DANGEROUS"
assert_gate fail 'marker inside block comment rejected' '^FAIL additive-only \(b\)$'

for sql in \
  'dRoP /* comment */ TaBlE fixture_1;' \
  'ALTER TABLE fixture_1 DROP CONSTRAINT old_constraint;' \
  'ALTER TABLE fixture_1 ALTER COLUMN id TYPE BIGINT;' \
  'ALTER TABLE fixture_1 RENAME TO renamed;' \
  'ALTER TABLE fixture_1 RENAME COLUMN id TO renamed;' \
  'TRUNCATE fixture_1;' \
  'DELETE FROM fixture_1; SELECT 1 WHERE true;' \
  'DELETE FROM fixture_1 /* WHERE id = 1 */;' \
  'DELETE FROM fixture_1 USING (SELECT 1 WHERE true) AS ignored;' \
  'DO $$ BEGIN DELETE FROM fixture_1; END $$;' \
  "DO \$\$ BEGIN EXECUTE 'DROP TABLE fixture_1'; END \$\$;" \
  "DELETE FROM fixture_1 RETURNING 'WHERE';"; do
  printf '%s\n' "$sql" > "$DANGEROUS"
  assert_gate fail "$sql" '^FAIL additive-only \(b\)$'
done
printf '%s\n' "DELETE FROM fixture_1 WHERE note = '-- /* text */';" > "$DANGEROUS"
assert_gate pass 'comment syntax inside SQL string' '^PASS additive-only \(b\)$'
rm "$DANGEROUS"

printf 'CREATE TABLE backfill (id INTEGER);\n' > "$MIGRATIONS/V3__backfill.sql"
assert_gate fail 'numeric backfill (c)' '^FAIL numbering: .*V3__backfill.sql: version must exceed published V10$'
rm "$MIGRATIONS/V3__backfill.sql"
printf 'CREATE TABLE duplicate (id INTEGER);\n' > "$MIGRATIONS/V10__duplicate.sql"
assert_gate fail 'equal version (c)' '^FAIL numbering: .*V10__duplicate.sql:'
rm "$MIGRATIONS/V10__duplicate.sql"
assert_gate pass 'explicit baseline' '^PASS numbering \(c\)$' --since published-test
assert_gate fail 'invalid baseline fails closed' '^FAIL setup: invalid baseline:' --since missing-ref
git -C "$REPO" tag -d published-test > /dev/null
assert_gate pass 'root commit fallback' '^PASS immutability \(a\): baseline [0-9a-f]+$'
