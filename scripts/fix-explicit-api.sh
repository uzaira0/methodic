#!/usr/bin/env bash
# fix-explicit-api.sh — Automatically fix Kotlin explicitApi() visibility errors.
#
# For chronicle-api: everything becomes public (it's the client contract).
# For chronicle-server: classifies public vs internal based on Spring annotations,
# declaration type, and usage patterns.
#
# Usage:
#   ./scripts/fix-explicit-api.sh [api|server|all] [--dry-run] [--package PKG]
#
# Examples:
#   ./scripts/fix-explicit-api.sh api                   # Fix chronicle-api
#   ./scripts/fix-explicit-api.sh server --dry-run      # Preview server changes
#   ./scripts/fix-explicit-api.sh server --package com.openlattice.chronicle.controllers
#   ./scripts/fix-explicit-api.sh all                   # Fix both modules
#
# The script is idempotent: running it multiple times produces the same result.
# It will NOT modify declarations that already have an explicit visibility modifier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_FIXES=0
PUBLIC_COUNT=0
INTERNAL_COUNT=0
SKIPPED_COUNT=0

# Args
MODULE="${1:-}"
DRY_RUN=false
PACKAGE_FILTER=""

shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --package)
            PACKAGE_FILTER="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

if [[ -z "$MODULE" ]] || [[ "$MODULE" != "api" && "$MODULE" != "server" && "$MODULE" != "all" ]]; then
    echo "Usage: $0 [api|server|all] [--dry-run] [--package PKG]"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Enable explicitApi() temporarily to capture errors
# ---------------------------------------------------------------------------

enable_explicit_api() {
    local build_file="$1"
    local module_name="$2"

    # Check if explicitApi() is already enabled (not commented out)
    if grep -qP '^\s*explicitApi\(\)' "$build_file" 2>/dev/null; then
        echo -e "${BLUE}  explicitApi() already enabled in $module_name${NC}"
        return 0
    fi

    # Check if there's a kotlin { } block we can add to
    if grep -qP '^\s*kotlin\s*\{' "$build_file"; then
        # Add explicitApi() inside existing kotlin block
        sed -i '/^\s*kotlin\s*{/a\    explicitApi()' "$build_file"
    else
        # Need to check for the commented-out line and replace, or add a kotlin block
        if grep -q '// explicitApi() skipped' "$build_file"; then
            perl -i -pe 's|// explicitApi\(\) skipped.*|kotlin {\n    explicitApi()\n}|' "$build_file"
        else
            # Add kotlin block before tasks.withType(KotlinCompile)
            perl -i -pe 's|(tasks\.withType\(org\.jetbrains\.kotlin\.gradle\.tasks\.KotlinCompile\))|kotlin {\n    explicitApi()\n}\n\n$1|' "$build_file"
        fi
    fi
}

disable_explicit_api() {
    local build_file="$1"

    # Remove the kotlin { explicitApi() } block we added
    # or just the explicitApi() line if it was inside an existing block
    sed -i '/^\s*explicitApi()$/d' "$build_file"

    # Clean up empty kotlin { } blocks we may have created
    # Use perl for multi-line matching
    perl -0777 -i -pe 's/kotlin\s*\{\s*\n\s*\}\n?//g' "$build_file"
}

# ---------------------------------------------------------------------------
# Step 2: Compile and capture errors
# ---------------------------------------------------------------------------

capture_errors() {
    local module_name="$1"  # e.g., "chronicle-api" or "chronicle-server"
    local gradle_task=":${module_name}:compileKotlin"
    local _result_var="$2"  # name of variable to store result path

    echo -e "${BLUE}  Compiling $module_name to capture visibility errors...${NC}" >&2

    local _raw_err_file
    _raw_err_file=$(mktemp /tmp/explicit-api-errors-XXXXXX.txt)
    local _filt_file
    _filt_file=$(mktemp /tmp/explicit-api-filtered-XXXXXX.txt)

    cd "$PROJECT_ROOT"

    # Run gradle compile, capture stderr+stdout. We expect it to fail.
    # First resolve dependencies (update locks if needed), then compile.
    ./gradlew ":${module_name}:dependencies" --no-daemon --write-locks -q > /dev/null 2>&1 || true
    ./gradlew "$gradle_task" --no-daemon -q > "$_raw_err_file" 2>&1 || true

    # Filter for VISIBILITY errors only (not return type errors)
    # Error format: e: file:///path/File.kt:LINE:COL Visibility must be specified in explicit API mode.
    grep -E "e: file://.*Visibility must be specified" "$_raw_err_file" > "$_filt_file" 2>/dev/null || true

    local count
    count=$(wc -l < "$_filt_file")
    echo -e "${BLUE}  Found $count visibility violations in $module_name${NC}" >&2

    # Count return type errors separately for reporting
    local return_type_count
    return_type_count=$(grep "Return type must be specified" "$_raw_err_file" 2>/dev/null | wc -l)
    if [[ "$return_type_count" -gt 0 ]]; then
        echo -e "${YELLOW}  Also found $return_type_count 'return type must be specified' errors (not fixed by this script)${NC}" >&2
    fi

    rm -f "$_raw_err_file"

    # Return the filtered file path via the named variable
    eval "$_result_var='$_filt_file'"
}

# ---------------------------------------------------------------------------
# Step 3: Parse errors and classify visibility
# ---------------------------------------------------------------------------

# Determine if a declaration at a given line should be public or internal.
# For chronicle-api: always public.
# For chronicle-server: classify based on context.
classify_visibility() {
    local file="$1"
    local line_num="$2"
    local module="$3"

    # chronicle-api: everything is the public contract
    if [[ "$module" == "api" ]]; then
        echo "public"
        return
    fi

    # chronicle-server: classify based on context

    # Get the line itself
    local line_text
    line_text=$(sed -n "${line_num}p" "$file")

    # Check annotations on the line and preceding lines (up to 10 lines back)
    local start_line=$(( line_num > 10 ? line_num - 10 : 1 ))
    local context
    context=$(sed -n "${start_line},${line_num}p" "$file")

    # --- MUST be public ---

    # Spring component annotations
    if echo "$context" | grep -qP '@(RestController|Controller|Service|Component|Configuration|Bean|Aspect)'; then
        echo "public"
        return
    fi

    # Spring event/scheduled methods
    if echo "$context" | grep -qP '@(EventListener|Scheduled)'; then
        echo "public"
        return
    fi

    # @Validated annotation (Spring validation)
    if echo "$context" | grep -qP '@Validated'; then
        echo "public"
        return
    fi

    # Interfaces — generally public (contracts, SPIs)
    if echo "$line_text" | grep -qP '^\s*(abstract\s+)?interface\s+'; then
        echo "public"
        return
    fi

    # Enum classes — typically cross-module
    if echo "$line_text" | grep -qP '^\s*enum\s+class\s+'; then
        echo "public"
        return
    fi

    # Data classes — typically DTOs for API
    if echo "$line_text" | grep -qP '^\s*data\s+class\s+'; then
        echo "public"
        return
    fi

    # Exception classes
    if echo "$line_text" | grep -qP '^\s*(open\s+|abstract\s+|sealed\s+)*class\s+\w+.*Exception'; then
        echo "public"
        return
    fi

    # Classes that implement/extend something (likely fulfilling a contract)
    if echo "$line_text" | grep -qP '^\s*(open\s+|abstract\s+|sealed\s+)*class\s+\w+.*:\s*\w+'; then
        echo "public"
        return
    fi

    # Abstract/open/sealed classes — designed for inheritance
    if echo "$line_text" | grep -qP '^\s*(abstract|open|sealed)\s+class\s+'; then
        echo "public"
        return
    fi

    # Annotation classes
    if echo "$line_text" | grep -qP '^\s*annotation\s+class\s+'; then
        echo "public"
        return
    fi

    # Object declarations (singletons) — often used as constants/utility across modules
    if echo "$line_text" | grep -qP '^\s*object\s+\w+'; then
        echo "public"
        return
    fi

    # Companion object members (const val) — often API route constants
    if echo "$line_text" | grep -qP '^\s*const\s+val\s+'; then
        echo "public"
        return
    fi

    # Top-level val/var (non-const) — could be internal
    if echo "$line_text" | grep -qP '^\s*val\s+|^\s*var\s+'; then
        # Check if it's a SQL string or builder
        if echo "$line_text" | grep -qiP '(SQL|Query|INSERT|SELECT|UPDATE|DELETE|CREATE)'; then
            echo "internal"
            return
        fi
        echo "public"
        return
    fi

    # Top-level fun — check for Spring annotations
    if echo "$line_text" | grep -qP '^\s*fun\s+'; then
        # If inside a class with Spring annotation, it's public
        # Check broader file context for Spring annotations
        if head -n "$line_num" "$file" | grep -qP '@(RestController|Controller|Service|Component|Configuration|Aspect)'; then
            echo "public"
            return
        fi
        # Extension functions on common types are often utilities
        if echo "$line_text" | grep -qP 'fun\s+\w+\.'; then
            echo "internal"
            return
        fi
        echo "public"
        return
    fi

    # Regular class declarations
    if echo "$line_text" | grep -qP '^\s*class\s+\w+'; then
        # Check if it's in a controllers/services/pods package
        if echo "$file" | grep -qP '(controllers|services|pods|configuration|config)'; then
            echo "public"
            return
        fi
        # Check filename for common internal patterns
        local basename
        basename=$(basename "$file" .kt)
        if echo "$basename" | grep -qP '(Builder|Helper|Util|Internal|Impl$)'; then
            echo "internal"
            return
        fi
        echo "public"
        return
    fi

    # Default: for server, use internal to be safe
    echo "internal"
}

# ---------------------------------------------------------------------------
# Step 4: Apply the fix to a specific file:line
# ---------------------------------------------------------------------------

apply_fix() {
    local file="$1"
    local line_num="$2"
    local visibility="$3"

    local line_text
    line_text=$(sed -n "${line_num}p" "$file")

    # Skip if already has an explicit visibility modifier at the start of the declaration
    if echo "$line_text" | grep -qP '^\s*(public|private|protected|internal)\s+'; then
        return 1  # Signal: skipped
    fi

    # Determine what keyword starts the declaration and prepend the visibility
    # We need to handle: class, interface, enum class, data class, fun, val, var, object, const val,
    # annotation class, abstract class, open class, sealed class, typealias, override fun, etc.
    #
    # Strategy: find the declaration keyword and insert the visibility before it.
    # But we must NOT insert before override (override already implies the visibility of the parent).

    # Skip override declarations — they inherit visibility from the parent
    if echo "$line_text" | grep -qP '^\s*override\s+'; then
        return 1
    fi

    # Handle constructor parameters (val/var in data class constructor):
    # e.g., "@param:JsonProperty(TARGET) val target: AclKey"
    # These need visibility before val/var in the parameter list
    if echo "$line_text" | grep -qP '^\s*@param:.*\bval\b|^\s*@param:.*\bvar\b'; then
        local new_param
        new_param=$(echo "$line_text" | perl -pe "s/(\bval\b)/${visibility} \$1/; s/(\bvar\b)/${visibility} \$1/" | perl -pe 's/(public|internal)\s+(public|internal)/$1/')
        if [[ "$new_param" != "$line_text" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                echo -e "  ${YELLOW}[dry-run]${NC} $file:$line_num"
                echo -e "    ${RED}- $line_text${NC}"
                echo -e "    ${GREEN}+ $new_param${NC}"
            else
                local tmpline
                tmpline=$(mktemp /tmp/fixline-XXXXXX.txt)
                printf '%s' "$new_param" > "$tmpline"
                perl -i -e "
                    my \$ln = $line_num;
                    my \$repl = do { local \$/; open my \$fh, '<', '$tmpline'; <\$fh> };
                    while (<>) {
                        if (\$. == \$ln) { print \$repl . \"\\n\"; } else { print; }
                    }
                " "$file"
                rm -f "$tmpline"
            fi
            return 0
        fi
    fi

    # Build the sed replacement.
    # Match the leading whitespace + optional modifiers + declaration keyword
    # Declaration keywords: class, interface, fun, val, var, object, enum, data, annotation,
    #                       abstract, open, sealed, const, typealias, suspend, inline, infix, operator, tailrec
    #
    # We want to insert `public ` (or `internal `) right before the first keyword.

    local new_line
    # Use perl for more precise replacement
    new_line=$(echo "$line_text" | perl -pe "
        # Insert visibility before the declaration keyword
        # Handle: data class, enum class, annotation class, sealed class, abstract class, open class,
        #         sealed interface, value class, inner class, inline class
        s/^(\s*)(data\s+class|enum\s+class|annotation\s+class|sealed\s+class|sealed\s+interface|abstract\s+class|open\s+class|value\s+class|inner\s+class|inline\s+class)/\$1${visibility} \$2/ ||
        # Handle: suspend fun, inline fun, infix fun, operator fun, tailrec fun
        s/^(\s*)(suspend\s+fun|inline\s+fun|infix\s+fun|operator\s+fun|tailrec\s+fun)/\$1${visibility} \$2/ ||
        # Handle: const val, abstract val, abstract var, abstract fun
        s/^(\s*)(const\s+val|abstract\s+val|abstract\s+var|abstract\s+fun)/\$1${visibility} \$2/ ||
        # Handle: companion object
        s/^(\s*)(companion\s+object)/\$1${visibility} \$2/ ||
        # Handle: constructor
        s/^(\s*)(constructor\s*\()/\$1${visibility} \$2/ ||
        # Handle: class, interface, fun, val, var, object, typealias
        s/^(\s*)(class|interface|fun|val|var|object|typealias)\b/\$1${visibility} \$2/
    ")

    # Verify something changed
    if [[ "$new_line" == "$line_text" ]]; then
        # Could not apply the fix — maybe it's an unusual declaration
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run]${NC} $file:$line_num"
        echo -e "    ${RED}- $line_text${NC}"
        echo -e "    ${GREEN}+ $new_line${NC}"
    else
        # Apply the fix in-place using perl for safe line replacement
        # Write new_line to a temp file to avoid shell escaping issues
        local tmpline
        tmpline=$(mktemp /tmp/fixline-XXXXXX.txt)
        printf '%s' "$new_line" > "$tmpline"
        perl -i -e "
            my \$ln = $line_num;
            my \$repl = do { local \$/; open my \$fh, '<', '$tmpline'; <\$fh> };
            while (<>) {
                if (\$. == \$ln) { print \$repl . \"\\n\"; } else { print; }
            }
        " "$file"
        rm -f "$tmpline"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Step 5: Process a module
# ---------------------------------------------------------------------------

process_module() {
    local module_name="$1"  # chronicle-api or chronicle-server
    local module_short="$2" # api or server
    local build_file="$PROJECT_ROOT/$module_name/build.gradle"

    echo ""
    echo -e "${GREEN}=== Processing $module_name ===${NC}"

    # Save original build.gradle
    cp "$build_file" "${build_file}.bak"

    # Enable explicitApi()
    echo -e "${BLUE}  Enabling explicitApi() in build.gradle...${NC}"
    enable_explicit_api "$build_file" "$module_name"

    # Capture compilation errors
    local error_file=""
    capture_errors "$module_name" error_file

    # Restore build.gradle (we'll re-enable later if everything works)
    cp "${build_file}.bak" "$build_file"

    local error_count
    error_count=$(wc -l < "$error_file")

    if [[ "$error_count" -eq 0 ]]; then
        echo -e "${GREEN}  No explicit API errors found! Module may already be compliant.${NC}"
        rm -f "${build_file}.bak" "$error_file"
        return
    fi

    echo -e "${BLUE}  Processing $error_count violations...${NC}"

    # Parse each error and apply fixes
    # Error format: e: file:///path/to/File.kt:LINE:COL Explicit API mode ...
    local module_public=0
    local module_internal=0
    local module_skipped=0

    # Process errors grouped by file for efficiency
    local prev_file=""
    while IFS= read -r error_line; do
        # Extract file path and line number
        # Format: e: file:///home/opt/chronicle/chronicle-api/src/main/.../File.kt:42:1 ...
        local file_path line_num

        # Parse the error line
        if [[ "$error_line" =~ e:\ file://([^:]+):([0-9]+): ]]; then
            file_path="${BASH_REMATCH[1]}"
            line_num="${BASH_REMATCH[2]}"
        else
            continue
        fi

        # Apply package filter if specified
        if [[ -n "$PACKAGE_FILTER" ]]; then
            local pkg_path
            pkg_path=$(echo "$PACKAGE_FILTER" | tr '.' '/')
            if [[ "$file_path" != *"$pkg_path"* ]]; then
                continue
            fi
        fi

        # Classify and apply
        local visibility
        visibility=$(classify_visibility "$file_path" "$line_num" "$module_short")

        if apply_fix "$file_path" "$line_num" "$visibility"; then
            if [[ "$visibility" == "public" ]]; then
                (( module_public++ )) || true
            else
                (( module_internal++ )) || true
            fi
        else
            (( module_skipped++ )) || true
        fi
    done < "$error_file"

    # Update global counters
    (( PUBLIC_COUNT += module_public )) || true
    (( INTERNAL_COUNT += module_internal )) || true
    (( SKIPPED_COUNT += module_skipped )) || true
    (( TOTAL_FIXES += module_public + module_internal )) || true

    echo ""
    echo -e "${GREEN}  $module_name results:${NC}"
    echo -e "    public:   $module_public"
    echo -e "    internal: $module_internal"
    echo -e "    skipped:  $module_skipped (already had modifier or override)"

    # If not dry-run, enable explicitApi() in the build file
    if [[ "$DRY_RUN" == false ]]; then
        echo -e "${BLUE}  Enabling explicitApi() permanently in build.gradle...${NC}"
        enable_explicit_api "$build_file" "$module_name"

        # Remove the old comment
        sed -i '/\/\/ explicitApi() skipped/d' "$build_file"
    fi

    # Clean up
    rm -f "${build_file}.bak" "$error_file"
}

# ---------------------------------------------------------------------------
# Step 6: Verify compilation
# ---------------------------------------------------------------------------

verify_compilation() {
    local module_name="$1"
    local gradle_task=":${module_name}:compileKotlin"

    echo ""
    echo -e "${BLUE}  Verifying $module_name compiles...${NC}"

    cd "$PROJECT_ROOT"
    ./gradlew ":${module_name}:dependencies" --no-daemon --write-locks -q > /dev/null 2>&1 || true
    if ./gradlew "$gradle_task" --no-daemon -q 2>&1; then
        echo -e "${GREEN}  $module_name compiles successfully!${NC}"
        return 0
    else
        echo -e "${RED}  $module_name has compilation errors after fixes.${NC}"
        echo -e "${YELLOW}  Running a second pass to catch remaining issues...${NC}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Step 7: Second pass — fix any remaining errors after first pass
# ---------------------------------------------------------------------------

second_pass() {
    local module_name="$1"
    local module_short="$2"
    local build_file="$PROJECT_ROOT/$module_name/build.gradle"

    echo -e "${BLUE}  Running second pass for $module_name...${NC}"

    local error_file=""
    capture_errors "$module_name" error_file

    local error_count
    error_count=$(wc -l < "$error_file")

    if [[ "$error_count" -eq 0 ]]; then
        echo -e "${GREEN}  No remaining errors!${NC}"
        rm -f "$error_file"
        return 0
    fi

    echo -e "${YELLOW}  $error_count errors remain, applying fixes...${NC}"

    local pass2_fixed=0
    while IFS= read -r error_line; do
        local file_path line_num

        if [[ "$error_line" =~ e:\ file://([^:]+):([0-9]+): ]]; then
            file_path="${BASH_REMATCH[1]}"
            line_num="${BASH_REMATCH[2]}"
        else
            continue
        fi

        if [[ -n "$PACKAGE_FILTER" ]]; then
            local pkg_path
            pkg_path=$(echo "$PACKAGE_FILTER" | tr '.' '/')
            if [[ "$file_path" != *"$pkg_path"* ]]; then
                continue
            fi
        fi

        local visibility
        visibility=$(classify_visibility "$file_path" "$line_num" "$module_short")

        if apply_fix "$file_path" "$line_num" "$visibility"; then
            (( pass2_fixed++ )) || true
        fi
    done < "$error_file"

    echo -e "${BLUE}  Second pass fixed $pass2_fixed additional declarations${NC}"
    (( TOTAL_FIXES += pass2_fixed )) || true

    rm -f "$error_file"
}

# ---------------------------------------------------------------------------
# Step 8: Fix return type errors
# ---------------------------------------------------------------------------

# Infer the return type for a const val based on its initializer
infer_const_type() {
    local value="$1"
    # String literal
    if echo "$value" | grep -qP '^"'; then
        echo "String"
        return
    fi
    # String concatenation
    if echo "$value" | grep -qP '\+\s*"|\+\s*\w+'; then
        echo "String"
        return
    fi
    # Integer literal
    if echo "$value" | grep -qP '^[0-9]+$'; then
        echo "Int"
        return
    fi
    # Long literal
    if echo "$value" | grep -qP '^[0-9]+L$'; then
        echo "Long"
        return
    fi
    # Boolean
    if echo "$value" | grep -qP '^(true|false)$'; then
        echo "Boolean"
        return
    fi
    # Double
    if echo "$value" | grep -qP '^[0-9]+\.[0-9]+$'; then
        echo "Double"
        return
    fi
    # Default: String (most const vals in API are strings)
    echo "String"
}

fix_return_type() {
    local file="$1"
    local line_num="$2"

    local line_text
    line_text=$(sed -n "${line_num}p" "$file")

    local new_line="$line_text"
    local changed=false

    # Case 1: const val without type — add type annotation
    # e.g., "public const val FOO = "/bar"" -> "public const val FOO: String = "/bar""
    if echo "$line_text" | grep -qP 'const\s+val\s+\w+\s*='; then
        # Extract the value part after =
        local val_name val_part
        val_name=$(echo "$line_text" | perl -ne 'print $1 if /const\s+val\s+(\w+)\s*=/')
        val_part=$(echo "$line_text" | perl -ne 'print $1 if /=\s*(.+?)\s*$/')
        local inferred_type
        inferred_type=$(infer_const_type "$val_part")
        # Insert type annotation after val name
        new_line=$(echo "$line_text" | perl -pe "s/(const\s+val\s+${val_name})\s*=/\$1: ${inferred_type} =/")
        changed=true
    fi

    # Case 2: val/var without type, with initializer — infer from initializer
    # e.g., "val index = joinToString..." — harder to infer, skip complex cases
    if [[ "$changed" == false ]] && echo "$line_text" | grep -qP '^\s*(public\s+|internal\s+|private\s+|protected\s+)?(val|var)\s+\w+\s*=' && ! echo "$line_text" | grep -qP ':\s*\w'; then
        # Only handle simple cases: string literals, numeric literals
        local val_part
        val_part=$(echo "$line_text" | perl -ne 'print $1 if /=\s*(.+?)\s*$/')
        if echo "$val_part" | grep -qP '^"'; then
            local val_name
            val_name=$(echo "$line_text" | perl -ne 'print $1 if /(val|var)\s+(\w+)\s*=/ && print $2')
            val_name=$(echo "$line_text" | perl -ne '/(?:val|var)\s+(\w+)\s*=/ && print $1')
            new_line=$(echo "$line_text" | perl -pe "s/((val|var)\s+\Q${val_name}\E)\s*=/\$1: String =/")
            changed=true
        fi
    fi

    # Case 3: fun without return type (implicit Unit)
    # e.g., "public fun doSomething()" -> "public fun doSomething(): Unit"
    # Only for interface/abstract methods that end with ) or have no body
    if [[ "$changed" == false ]] && echo "$line_text" | grep -qP '\bfun\s+\w+.*\)\s*$'; then
        # Function ends with ) — no return type and no body = implicit Unit
        new_line=$(echo "$line_text" | perl -pe 's/(\))\s*$/\$1: Unit/')
        changed=true
    fi

    if [[ "$changed" == false ]] || [[ "$new_line" == "$line_text" ]]; then
        return 1
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[dry-run][return-type]${NC} $file:$line_num"
        echo -e "    ${RED}- $line_text${NC}"
        echo -e "    ${GREEN}+ $new_line${NC}"
    else
        local tmpline
        tmpline=$(mktemp /tmp/fixline-XXXXXX.txt)
        printf '%s' "$new_line" > "$tmpline"
        perl -i -e "
            my \$ln = $line_num;
            my \$repl = do { local \$/; open my \$fh, '<', '$tmpline'; <\$fh> };
            while (<>) {
                if (\$. == \$ln) { print \$repl . \"\\n\"; } else { print; }
            }
        " "$file"
        rm -f "$tmpline"
    fi

    return 0
}

capture_return_type_errors() {
    local module_name="$1"
    local _result_var="$2"
    local gradle_task=":${module_name}:compileKotlin"

    echo -e "${BLUE}  Compiling $module_name to capture return type errors...${NC}" >&2

    local _raw_err_file
    _raw_err_file=$(mktemp /tmp/explicit-api-rterr-XXXXXX.txt)
    local _filt_file
    _filt_file=$(mktemp /tmp/explicit-api-rtfilt-XXXXXX.txt)

    cd "$PROJECT_ROOT"
    ./gradlew ":${module_name}:dependencies" --no-daemon --write-locks -q > /dev/null 2>&1 || true
    ./gradlew "$gradle_task" --no-daemon -q > "$_raw_err_file" 2>&1 || true

    grep -E "e: file://.*Return type must be specified" "$_raw_err_file" > "$_filt_file" 2>/dev/null || true

    local count
    count=$(wc -l < "$_filt_file")
    echo -e "${BLUE}  Found $count return type violations in $module_name${NC}" >&2

    rm -f "$_raw_err_file"
    eval "$_result_var='$_filt_file'"
}

fix_return_types_pass() {
    local module_name="$1"

    echo ""
    echo -e "${GREEN}=== Fixing return type errors in $module_name ===${NC}"

    local rt_error_file=""
    capture_return_type_errors "$module_name" rt_error_file

    local rt_count
    rt_count=$(wc -l < "$rt_error_file")

    if [[ "$rt_count" -eq 0 ]]; then
        echo -e "${GREEN}  No return type errors!${NC}"
        rm -f "$rt_error_file"
        return
    fi

    echo -e "${BLUE}  Processing $rt_count return type violations...${NC}"

    local rt_fixed=0
    local rt_skipped=0

    while IFS= read -r error_line; do
        local file_path line_num

        if [[ "$error_line" =~ e:\ file://([^:]+):([0-9]+): ]]; then
            file_path="${BASH_REMATCH[1]}"
            line_num="${BASH_REMATCH[2]}"
        else
            continue
        fi

        if [[ -n "$PACKAGE_FILTER" ]]; then
            local pkg_path
            pkg_path=$(echo "$PACKAGE_FILTER" | tr '.' '/')
            if [[ "$file_path" != *"$pkg_path"* ]]; then
                continue
            fi
        fi

        if fix_return_type "$file_path" "$line_num"; then
            (( rt_fixed++ )) || true
        else
            (( rt_skipped++ )) || true
        fi
    done < "$rt_error_file"

    echo -e "${GREEN}  Return type results for $module_name:${NC}"
    echo -e "    fixed:   $rt_fixed"
    echo -e "    skipped: $rt_skipped (complex types that need manual review)"

    (( TOTAL_FIXES += rt_fixed )) || true

    rm -f "$rt_error_file"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo -e "${GREEN}=== Chronicle explicitApi() Visibility Fixer ===${NC}"
echo "Project root: $PROJECT_ROOT"
echo "Mode: $(if $DRY_RUN; then echo 'DRY RUN'; else echo 'APPLY'; fi)"
if [[ -n "$PACKAGE_FILTER" ]]; then
    echo "Package filter: $PACKAGE_FILTER"
fi

if [[ "$MODULE" == "api" || "$MODULE" == "all" ]]; then
    process_module "chronicle-api" "api"
    if [[ "$DRY_RUN" == false ]]; then
        if ! verify_compilation "chronicle-api"; then
            second_pass "chronicle-api" "api"
            verify_compilation "chronicle-api" || true
        fi
    fi
    # Fix return type errors (separate pass)
    fix_return_types_pass "chronicle-api"
    if [[ "$DRY_RUN" == false ]]; then
        # May need multiple passes for return types since fixing one can reveal more
        if ! verify_compilation "chronicle-api"; then
            fix_return_types_pass "chronicle-api"
            verify_compilation "chronicle-api" || echo -e "${RED}  WARNING: chronicle-api still has errors. Some may need manual fixing.${NC}"
        fi
    fi
fi

if [[ "$MODULE" == "server" || "$MODULE" == "all" ]]; then
    process_module "chronicle-server" "server"
    if [[ "$DRY_RUN" == false ]]; then
        if ! verify_compilation "chronicle-server"; then
            second_pass "chronicle-server" "server"
            verify_compilation "chronicle-server" || true
        fi
    fi
    # Fix return type errors (separate pass)
    fix_return_types_pass "chronicle-server"
    if [[ "$DRY_RUN" == false ]]; then
        if ! verify_compilation "chronicle-server"; then
            fix_return_types_pass "chronicle-server"
            verify_compilation "chronicle-server" || echo -e "${RED}  WARNING: chronicle-server still has errors. Some may need manual fixing.${NC}"
        fi
    fi
fi

echo ""
echo -e "${GREEN}=== Summary ===${NC}"
echo -e "  Total fixes applied: $TOTAL_FIXES"
echo -e "  Public:              $PUBLIC_COUNT"
echo -e "  Internal:            $INTERNAL_COUNT"
echo -e "  Skipped:             $SKIPPED_COUNT"

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo -e "${YELLOW}  This was a dry run. No files were modified.${NC}"
    echo -e "${YELLOW}  Run without --dry-run to apply changes.${NC}"
fi
