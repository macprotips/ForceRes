#!/bin/bash
# notarize.sh
#
# Notarizes and staples an already-built, Developer-ID-signed dist/ForceRes.app
# (produced by Scripts/build-app.sh), and produces a distributable zip.
#
# Usage:
#   Scripts/notarize.sh [--profile <notarytool-keychain-profile>] [--version X.Y.Z]
#
#   --profile   Name of a keychain profile previously stored with
#               `xcrun notarytool store-credentials`. Default: $NOTARY_PROFILE
#               env var.
#   --version   Version string used to name the output zip
#               (dist/ForceRes-<version>.zip). Default: derived the same way
#               as build-app.sh (git describe, sanitized).
#
# Requires that dist/ForceRes.app was signed with a "Developer ID Application"
# identity; the notary service rejects ad-hoc and "Apple Development" builds,
# so this script fails fast instead of submitting one.

set -euo pipefail

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

APP_NAME="ForceRes"
OUTPUT_DIR="dist"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

PROFILE="${NOTARY_PROFILE:-}"
VERSION=""

usage() {
    cat <<EOF
Usage: $0 [--profile <notarytool-keychain-profile>] [--version X.Y.Z]
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --profile)
            PROFILE="$2"; shift 2 ;;
        --version)
            VERSION="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "notarize.sh: unknown argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

if [ -z "$PROFILE" ]; then
    echo "notarize.sh: no --profile given and NOTARY_PROFILE is unset." >&2
    echo "Create one once with:" >&2
    echo "  xcrun notarytool store-credentials <profile-name> --apple-id <id> --team-id <team> --password <app-specific-password>" >&2
    exit 1
fi

if [ ! -d "$APP_BUNDLE" ]; then
    echo "notarize.sh: $APP_BUNDLE not found. Run Scripts/build-app.sh first." >&2
    exit 1
fi

# --- Verify this is a Developer ID build ------------------------------

SIGNING_INFO=$(codesign -dvv "$APP_BUNDLE" 2>&1 || true)
if ! echo "$SIGNING_INFO" | grep -q 'Authority=Developer ID Application'; then
    echo "notarize.sh: $APP_BUNDLE was not signed with a \"Developer ID Application\" identity." >&2
    echo "Notarization requires Developer ID signing. Re-run:" >&2
    echo "  Scripts/build-app.sh --identity \"Developer ID Application: <Name> (<TEAMID>)\"" >&2
    echo "Current signing info:" >&2
    echo "$SIGNING_INFO" >&2
    exit 1
fi
echo "notarize.sh: confirmed Developer ID signature on $APP_BUNDLE"

if [ -z "$VERSION" ]; then
    RAW_VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0")
    VERSION=$(echo "$RAW_VERSION" | sed -E 's/^v//' | sed -E 's/[^A-Za-z0-9.-]/-/g')
fi

SUBMIT_ZIP="$OUTPUT_DIR/ForceRes-notarize-submission.zip"
FINAL_ZIP="$OUTPUT_DIR/ForceRes-$VERSION.zip"

# --- Zip, submit, wait ---------------------------------------------------

echo "notarize.sh: zipping $APP_BUNDLE -> $SUBMIT_ZIP"
rm -f "$SUBMIT_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$SUBMIT_ZIP"

echo "notarize.sh: submitting to notarytool (profile: $PROFILE), waiting for result..."
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait

# --- Staple ---------------------------------------------------------

echo "notarize.sh: stapling ticket to $APP_BUNDLE"
xcrun stapler staple "$APP_BUNDLE"

# --- Final assessment -----------------------------------------------

echo "notarize.sh: codesign --verify --strict --deep on the stapled bundle"
codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE"

echo "notarize.sh: spctl --assess --type execute (must pass for a stapled build):"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

# --- Package the stapled app for distribution ----------------------------

echo "notarize.sh: producing distributable zip $FINAL_ZIP"
rm -f "$FINAL_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$FINAL_ZIP"
rm -f "$SUBMIT_ZIP"

echo "notarize.sh: done. Notarized, stapled app at $APP_BUNDLE; distributable zip at $FINAL_ZIP"
