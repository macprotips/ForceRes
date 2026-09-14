#!/bin/bash
# run-checks.sh
#
# Single validation entry point for ForceRes. See "Build and
# validation". Runs:
#
#   1. swift build --build-tests (debug) after touching every project source,
#      so each module is recompiled and every compiler diagnostic is
#      re-emitted (an incremental build only prints diagnostics for files it
#      recompiles). Fails on any warning: or error: line except the
#      toolchain's "search path ... not found" linker warnings.
#   2. swift test - the full unit suite.
#   3. swift run forceres-probe --virtual-support - exercises the private
#      virtual-display API availability check end to end (exits 1 when the
#      API is unavailable).
#   4. An nm -u check on debug binaries (including forceres-vdhost) confirming
#      no CGVirtualDisplay*, SLSIsDisplayMode* or SkyLight symbol is imported
#      directly, and an otool -L check that no binary links a framework under
#      PrivateFrameworks (private API must be resolved at runtime only).
#   5. A check that swift build produced the forceres-vdhost helper binary.
#
# Usage:
#   Scripts/run-checks.sh            debug checks only
#   Scripts/run-checks.sh --release  also runs Scripts/build-app.sh afterwards
#
# Exits non-zero on the first failed check category, after printing a summary
# of every category's pass/fail state.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

# Use the full Xcode toolchain: `swift test` and codesign need it, and the
# Command Line Tools alone are not enough. Override by exporting DEVELOPER_DIR,
# or drop a line in Scripts/local.env (untracked).
if [ -f "$(dirname "$0")/local.env" ]; then
    . "$(dirname "$0")/local.env"
fi
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export DEVELOPER_DIR
echo "run-checks.sh: DEVELOPER_DIR=$DEVELOPER_DIR"

RUN_RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --release) RUN_RELEASE=1 ;;
        *)
            echo "run-checks.sh: unknown argument: $arg" >&2
            exit 1 ;;
    esac
done

FAILED=0
declare -a SUMMARY

note_result() {
    # note_result <label> <exit-code>
    if [ "$2" -eq 0 ]; then
        SUMMARY+=("PASS  $1")
    else
        SUMMARY+=("FAIL  $1")
        FAILED=1
    fi
}

# Linker warnings from the toolchain's SDK layout, not from our code.
BENIGN_WARNING_PATTERN='ld: warning: search path .* not found'

# --- 1. swift build (debug), fail on any warning/error from our targets ----

echo
echo "run-checks.sh: swift build --build-tests (all project sources touched)"
find Sources Tests \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) -type f -exec touch {} +
BUILD_LOG=$(mktemp)
swift build --build-tests 2>&1 | tee "$BUILD_LOG"
BUILD_EXIT=${PIPESTATUS[0]}

if [ "$BUILD_EXIT" -ne 0 ]; then
    echo "run-checks.sh: swift build exited non-zero ($BUILD_EXIT)"
    note_result "swift build" 1
else
    OFFENDING=$(grep -E 'warning:|error:' "$BUILD_LOG" | grep -v -E "$BENIGN_WARNING_PATTERN" || true)
    if [ -n "$OFFENDING" ]; then
        echo "run-checks.sh: swift build produced warnings/errors in our own code:"
        echo "$OFFENDING"
        note_result "swift build (zero warnings)" 1
    else
        note_result "swift build (zero warnings)" 0
    fi
fi
rm -f "$BUILD_LOG"

# --- 2. swift test -----------------------------------------------------

echo
echo "run-checks.sh: swift test"
swift test
note_result "swift test" $?

# --- 3. forceres-probe --virtual-support --------------------------------

echo
echo "run-checks.sh: swift run forceres-probe --virtual-support"
swift run forceres-probe --virtual-support
note_result "forceres-probe --virtual-support" $?

# --- 4. private-symbol and private-framework check on debug binaries -------

PRIVATE_SYMBOL_PATTERN='CGVirtualDisplay|SLSIsDisplayMode|SkyLight'

echo
echo "run-checks.sh: checking debug binaries for direct private-symbol imports ($PRIVATE_SYMBOL_PATTERN) and PrivateFrameworks links"
BIN_PATH=$(swift build --show-bin-path 2>/dev/null)
SYMBOL_CHECK_FAILED=0
FRAMEWORK_CHECK_FAILED=0
if [ -d "$BIN_PATH" ]; then
    for bin in "$BIN_PATH/ForceRes" "$BIN_PATH/forceres-probe" "$BIN_PATH/forceres-dev" "$BIN_PATH/forceres-vdhost"; do
        if [ -f "$bin" ]; then
            HITS=$(nm -u "$bin" 2>/dev/null | grep -E "$PRIVATE_SYMBOL_PATTERN" || true)
            if [ -n "$HITS" ]; then
                echo "run-checks.sh: $bin directly imports private symbols:"
                echo "$HITS"
                SYMBOL_CHECK_FAILED=1
            fi
            LINKS=$(otool -L "$bin" 2>/dev/null | grep -i 'PrivateFrameworks' || true)
            if [ -n "$LINKS" ]; then
                echo "run-checks.sh: $bin links a private framework:"
                echo "$LINKS"
                FRAMEWORK_CHECK_FAILED=1
            fi
        fi
    done
else
    echo "run-checks.sh: could not determine build bin path; skipping symbol check" >&2
    SYMBOL_CHECK_FAILED=1
    FRAMEWORK_CHECK_FAILED=1
fi
note_result "no direct CGVirtualDisplay*/SLSIsDisplayMode*/SkyLight imports" $SYMBOL_CHECK_FAILED
note_result "no PrivateFrameworks links (otool -L)" $FRAMEWORK_CHECK_FAILED

# --- 5. forceres-vdhost helper binary produced -----------------------------

echo
echo "run-checks.sh: checking swift build produced forceres-vdhost"
if [ -f "$BIN_PATH/forceres-vdhost" ]; then
    note_result "forceres-vdhost helper built" 0
else
    echo "run-checks.sh: $BIN_PATH/forceres-vdhost not found"
    note_result "forceres-vdhost helper built" 1
fi

# --- Optional: release packaging ----------------------------------------

if [ "$RUN_RELEASE" -eq 1 ]; then
    echo
    echo "run-checks.sh: --release given, running Scripts/build-app.sh"
    "$SCRIPT_DIR/build-app.sh"
    note_result "build-app.sh" $?
fi

# --- Summary -------------------------------------------------------

echo
echo "run-checks.sh: summary"
for line in "${SUMMARY[@]}"; do
    echo "  $line"
done

if [ "$FAILED" -ne 0 ]; then
    echo "run-checks.sh: one or more checks FAILED"
    exit 1
fi

echo "run-checks.sh: all checks passed"
