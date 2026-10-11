#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for cmd in git diff-cover python3; do
  command -v "$cmd" >/dev/null 2>&1 || { printf 'missing command: %s\n' "$cmd" >&2; exit 127; }
done
mkdir -p "$ROOT_DIR/build/quality-selftest"
TEST_DIR="$(mktemp -d "$ROOT_DIR/build/quality-selftest/diff-coverage.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$TEST_DIR"
git init --quiet
mkdir -p src coverage
printf 'export const value = 1;\n' > src/tiny.ts
git add src/tiny.ts
git -c user.name=QualitySelftest -c user.email=quality-selftest@example.invalid commit --quiet -m baseline
BASE="$(git rev-parse HEAD)"
printf 'export const value = 2;\n' > src/tiny.ts

report() {
  printf 'TN:\nSF:src/tiny.ts\nDA:1,%s\nLF:1\nLH:%s\nend_of_record\n' "$1" "$1" > coverage/lcov.info
}

expect_failure() {
  local label="$1" message="$2"
  if "$ROOT_DIR/scripts/diff-coverage.py" --base "$BASE" > result.log 2>&1; then
    printf 'FAIL: %s unexpectedly passed\n' "$label" >&2
    cat result.log >&2
    exit 1
  fi
  if ! rg -q -- "$message" result.log; then
    printf 'FAIL: %s failed for the wrong reason\n' "$label" >&2
    cat result.log >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}

command -v rg >/dev/null 2>&1 || { printf 'missing command: rg\n' >&2; exit 127; }
report 0
expect_failure 'uncovered changed line' 'Coverage: 0%|diff coverage is below|Failure'
report 1
"$ROOT_DIR/scripts/diff-coverage.py" --base "$BASE" > result.log 2>&1 || { cat result.log >&2; exit 1; }
printf 'PASS: covered changed line\n'
printf 'src/tiny.ts\n' > .diff-coverage-waivers
expect_failure 'waiver without reason' 'waiver requires a path glob and a reason'
rm .diff-coverage-waivers
rm coverage/lcov.info
expect_failure 'missing report' 'no coverage reports found.*bun test --coverage'

report 0
printf 'src/tiny.ts deliberate selftest exception\n' > .diff-coverage-waivers
"$ROOT_DIR/scripts/diff-coverage.py" --base "$BASE" > result.log 2>&1 || { cat result.log >&2; exit 1; }
printf 'PASS: reasoned waiver excludes the path\n'

mkdir -p build/reports/jacoco/test
printf '<report name="unrelated JVM"><package name="example"><sourcefile name="Other.kt"><line nr="1" mi="0" ci="1"/></sourcefile></package></report>\n' \
  > build/reports/jacoco/test/jacoco.xml
printf 'print("changed Python")\n' > src/operator.py
printf '#!/usr/bin/env bash\necho "changed Bash"\n' > src/operator.sh
printf '#!/usr/bin/env bash\necho "changed CLI"\n' > src/operator
expect_failure 'unrelated JaCoCo cannot cover Python or Bash' 'changed source src/operator(\.py|\.sh)? is absent'
for name in operator.py operator.sh operator; do
  rg -qF "changed source src/${name} is absent" result.log || \
    { cat result.log >&2; exit 1; }
done
mkdir -p build/coverage
cat > build/coverage/coverage.xml <<'XML'
<coverage><sources><source>.</source></sources><packages><package name="src"><classes>
<class name="operator.py" filename="src/operator.py"><lines><line number="1" hits="1"/></lines></class>
<class name="operator.sh" filename="src/operator.sh"><lines><line number="2" hits="1"/></lines></class>
<class name="operator" filename="src/operator"><lines><line number="2" hits="1"/></lines></class>
</classes></package></packages></coverage>
XML
"$ROOT_DIR/scripts/diff-coverage.py" --base "$BASE" > result.log 2>&1 || { cat result.log >&2; exit 1; }
printf 'PASS: measured Python and Bash sources pass with Cobertura\n'
