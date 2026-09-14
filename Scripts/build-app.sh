#!/bin/bash
# build-app.sh
#
# Builds ForceRes in release configuration and assembles, codesigns, and
# verifies a distributable dist/ForceRes.app bundle.
#
# Usage:
#   Scripts/build-app.sh [--version X.Y.Z] [--identity "<name>"] [--output DIR]
#
#   --version   App version (CFBundleShortVersionString); must match
#               ^[0-9]+\.[0-9]+(\.[0-9]+)?$. Default: the leading dotted
#               number of `git describe --tags --always --dirty` (a leading
#               "v" dropped), else 0.0.0; the rest of the describe output
#               (commit count, sha, -dirty) goes into CFBundleVersion after
#               the build timestamp instead.
#   --identity  Codesign identity name. Default: $CODESIGN_IDENTITY env var,
#               else the first "Developer ID Application" identity, else the
#               first "Apple Development" identity, else ad-hoc ("-").
#   --output    Output directory for the .app bundle. Default: dist/
#
# Exports DEVELOPER_DIR to the full Xcode install unless already set, since
# codesign/notarization-adjacent tooling on this machine needs it.
#
# PRODUCT_NAME=<product> substitutes another executable for the app binary to
# exercise the packaging steps alone.

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

PRODUCT_NAME="${PRODUCT_NAME:-ForceRes}"
BUNDLE_ID="com.macprotips.forceres"
APP_NAME="ForceRes"

VERSION=""
IDENTITY="${CODESIGN_IDENTITY:-}"
OUTPUT_DIR="dist"

usage() {
    cat <<EOF
Usage: $0 [--version X.Y.Z] [--identity "<name>"] [--output DIR]
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="$2"; shift 2 ;;
        --identity)
            IDENTITY="$2"; shift 2 ;;
        --output)
            OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "build-app.sh: unknown argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

# --- Version -----------------------------------------------------------
#
# CFBundleShortVersionString must be one to three dot-separated integers.
# CFBundleVersion is the UTC build timestamp, followed by whatever git
# describe reported beyond the version number (e.g. "-3-gabc1234-dirty" or a
# bare sha when there is no tag) so a build stays traceable.

VERSION_PATTERN='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
BUILD_NUMBER=$(date -u +%Y%m%d%H%M%S)

if [ -z "$VERSION" ]; then
    RAW_VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0")
    RAW_VERSION=${RAW_VERSION#v}
    # The leading dotted number, if any; the remainder is kept for CFBundleVersion.
    VERSION=$(echo "$RAW_VERSION" | sed -nE 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*$/\1/p')
    if [ -z "$VERSION" ]; then
        VERSION="0.0.0"
        VERSION_SUFFIX="$RAW_VERSION"
    else
        VERSION_SUFFIX=${RAW_VERSION#"$VERSION"}
    fi
    VERSION_SUFFIX=$(echo "$VERSION_SUFFIX" | sed -E 's/^[-+.]+//; s/[^A-Za-z0-9.-]/-/g')
    if [ -n "$VERSION_SUFFIX" ]; then
        BUILD_NUMBER="$BUILD_NUMBER-$VERSION_SUFFIX"
    fi
    echo "build-app.sh: no --version given; derived $VERSION from git describe '$RAW_VERSION'"
fi

if ! echo "$VERSION" | grep -Eq "$VERSION_PATTERN"; then
    echo "build-app.sh: --version '$VERSION' must match $VERSION_PATTERN (e.g. 1.0 or 1.0.0)" >&2
    exit 1
fi
if ! echo "$BUILD_NUMBER" | grep -Eq '^[A-Za-z0-9.-]+$'; then
    echo "build-app.sh: internal error: build number '$BUILD_NUMBER' is not plist-safe" >&2
    exit 1
fi

echo "build-app.sh: version=$VERSION build=$BUILD_NUMBER product=$PRODUCT_NAME"

# --- Identity selection --------------------------------------------------

if [ -z "$IDENTITY" ]; then
    IDENTITY_LIST=$(security find-identity -v -p codesigning 2>/dev/null || true)
    DEV_ID_LINE=$(echo "$IDENTITY_LIST" | grep '"Developer ID Application' | head -n1 || true)
    APPLE_DEV_LINE=$(echo "$IDENTITY_LIST" | grep '"Apple Development' | head -n1 || true)
    if [ -n "$DEV_ID_LINE" ]; then
        IDENTITY=$(echo "$DEV_ID_LINE" | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.*)"$/\1/')
        echo "build-app.sh: no --identity given; selected Developer ID identity: $IDENTITY"
    elif [ -n "$APPLE_DEV_LINE" ]; then
        IDENTITY=$(echo "$APPLE_DEV_LINE" | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ "(.*)"$/\1/')
        echo "build-app.sh: no --identity given and no Developer ID Application identity found;" \
             "falling back to Apple Development identity: $IDENTITY" \
             "(NOT suitable for distribution outside this Mac)"
    else
        IDENTITY="-"
        echo "build-app.sh: no --identity given and no usable signing identity found;" \
             "falling back to ad-hoc signing (-). This build cannot be notarized or distributed."
    fi
else
    echo "build-app.sh: using caller-specified identity: $IDENTITY"
fi

# --- Build -----------------------------------------------------------
#
# Two products ship inside the bundle: the app binary (PRODUCT_NAME) and the
# forceres-vdhost helper, which owns virtual displays.

VDHOST_PRODUCT="forceres-vdhost"
RESOURCE_BUNDLE="ForceRes_ForceRes.bundle"

echo "build-app.sh: swift build -c release --arch arm64 --product $PRODUCT_NAME"
swift build -c release --arch arm64 --product "$PRODUCT_NAME"

echo "build-app.sh: swift build -c release --arch arm64 --product $VDHOST_PRODUCT"
swift build -c release --arch arm64 --product "$VDHOST_PRODUCT"

BIN_PATH=$(swift build -c release --arch arm64 --product "$PRODUCT_NAME" --show-bin-path)
BUILT_BINARY="$BIN_PATH/$PRODUCT_NAME"
VDHOST_BIN_PATH=$(swift build -c release --arch arm64 --product "$VDHOST_PRODUCT" --show-bin-path)
BUILT_VDHOST_BINARY="$VDHOST_BIN_PATH/$VDHOST_PRODUCT"
# SwiftPM writes the app target's resource bundle (menu bar icons) next to the binary.
BUILT_RESOURCE_BUNDLE="$BIN_PATH/$RESOURCE_BUNDLE"

if [ ! -x "$BUILT_BINARY" ]; then
    echo "build-app.sh: expected built binary not found at $BUILT_BINARY" >&2
    exit 1
fi

if [ ! -x "$BUILT_VDHOST_BINARY" ]; then
    echo "build-app.sh: expected built binary not found at $BUILT_VDHOST_BINARY" >&2
    exit 1
fi

# --- Private-symbol guard ------------------------------------------------
# Private CGVirtualDisplay* classes and SkyLight's SLSIsDisplayMode* functions
# must be resolved at runtime only (NSClassFromString/dlsym), never imported
# or linked directly; the helper creates the instances and is
# checked too. otool -L confirms no PrivateFrameworks load command either.
PRIVATE_SYMBOL_PATTERN='CGVirtualDisplay|SLSIsDisplayMode|SkyLight'
for guarded_binary in "$BUILT_BINARY" "$BUILT_VDHOST_BINARY"; do
    echo "build-app.sh: checking $guarded_binary for direct private-symbol imports ($PRIVATE_SYMBOL_PATTERN)"
    if nm -u "$guarded_binary" 2>/dev/null | grep -Eq "$PRIVATE_SYMBOL_PATTERN"; then
        echo "build-app.sh: FAIL - binary directly imports a private symbol." >&2
        echo "Private CoreGraphics virtual-display classes and SkyLight functions must be" >&2
        echo "resolved at runtime (NSClassFromString/dlsym), never linked. Offending symbols:" >&2
        nm -u "$guarded_binary" 2>/dev/null | grep -E "$PRIVATE_SYMBOL_PATTERN" >&2
        exit 1
    fi
    echo "build-app.sh: OK - no direct private-symbol imports in $guarded_binary"
    echo "build-app.sh: checking $guarded_binary for PrivateFrameworks links"
    if otool -L "$guarded_binary" 2>/dev/null | grep -iq 'PrivateFrameworks'; then
        echo "build-app.sh: FAIL - binary links a private framework:" >&2
        otool -L "$guarded_binary" 2>/dev/null | grep -i 'PrivateFrameworks' >&2
        exit 1
    fi
    echo "build-app.sh: OK - no PrivateFrameworks links in $guarded_binary"
done

# --- Assemble bundle -------------------------------------------------

APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "build-app.sh: assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# CFBundleExecutable is always ForceRes, whichever product was built.
cp "$BUILT_BINARY" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Contents/MacOS is where Bundle.main.url(forAuxiliaryExecutable:) finds the helper.
cp "$BUILT_VDHOST_BINARY" "$MACOS_DIR/$VDHOST_PRODUCT"
chmod +x "$MACOS_DIR/$VDHOST_PRODUCT"

# Bundle.module (generated accessor) searches Bundle.main.resourceURL for the
# resource bundle, i.e. Contents/Resources.
if [ -d "$BUILT_RESOURCE_BUNDLE" ]; then
    cp -R "$BUILT_RESOURCE_BUNDLE" "$RESOURCES_DIR/$RESOURCE_BUNDLE"
elif [ "$PRODUCT_NAME" = "$APP_NAME" ]; then
    echo "build-app.sh: expected resource bundle not found at $BUILT_RESOURCE_BUNDLE" >&2
    exit 1
else
    echo "build-app.sh: no resource bundle for $PRODUCT_NAME; skipping" >&2
fi

# Both values are validated above to [A-Za-z0-9.-], so the only sed-special
# character they can carry is ".", which sed_escape neutralises.
sed_escape() { printf '%s' "$1" | sed -e 's/[][\\.*^$/&|]/\\&/g'; }
sed -e "s/__VERSION__/$(sed_escape "$VERSION")/" -e "s/__BUILD__/$(sed_escape "$BUILD_NUMBER")/" \
    "$REPO_ROOT/Resources/Info.plist" > "$CONTENTS_DIR/Info.plist"

if [ -f "$REPO_ROOT/Resources/AppIcon.icns" ]; then
    cp "$REPO_ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
else
    echo "build-app.sh: warning - Resources/AppIcon.icns not found; run Scripts/make-icon.sh first" >&2
fi

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

# --- Codesign ----------------------------------------------------------

CODESIGN_ARGS=(--force --options runtime --entitlements "$REPO_ROOT/Resources/ForceRes.entitlements" --sign "$IDENTITY")
VDHOST_CODESIGN_ARGS=(--force --options runtime --entitlements "$REPO_ROOT/Resources/ForceRes.entitlements" --identifier com.macprotips.forceres.vdhost --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
    CODESIGN_ARGS=(--force --options runtime --timestamp --entitlements "$REPO_ROOT/Resources/ForceRes.entitlements" --sign "$IDENTITY")
    VDHOST_CODESIGN_ARGS=(--force --options runtime --timestamp --entitlements "$REPO_ROOT/Resources/ForceRes.entitlements" --identifier com.macprotips.forceres.vdhost --sign "$IDENTITY")
else
    echo "build-app.sh: ad-hoc identity selected; dropping --timestamp (notarytool requires a real timestamp anyway and ad-hoc signing cannot be notarized)"
fi

# Nested code first: the app signature (below, without --deep) seals the
# already-signed helper and the resource bundle.
echo "build-app.sh: codesign ${VDHOST_CODESIGN_ARGS[*]} $MACOS_DIR/$VDHOST_PRODUCT"
codesign "${VDHOST_CODESIGN_ARGS[@]}" "$MACOS_DIR/$VDHOST_PRODUCT"

echo "build-app.sh: codesign --verify --strict on the helper"
codesign --verify --strict --verbose=2 "$MACOS_DIR/$VDHOST_PRODUCT"

if [ -d "$RESOURCES_DIR/$RESOURCE_BUNDLE" ]; then
    # The bundle holds no code; signing it gives it its own seal, and the app
    # signature covers it either way.
    echo "build-app.sh: codesign --force --sign $IDENTITY $RESOURCES_DIR/$RESOURCE_BUNDLE"
    codesign --force --sign "$IDENTITY" "$RESOURCES_DIR/$RESOURCE_BUNDLE"
    codesign --verify --strict --verbose=2 "$RESOURCES_DIR/$RESOURCE_BUNDLE"
fi

echo "build-app.sh: codesign ${CODESIGN_ARGS[*]} $APP_BUNDLE"
codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE"

echo "build-app.sh: codesign --verify --strict"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

echo "build-app.sh: codesign -dvv summary:"
codesign -dvv "$APP_BUNDLE" 2>&1 || true

# --- Deployment target check (informational) ------------------------------

LS_MIN=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$CONTENTS_DIR/Info.plist" 2>/dev/null || echo "?")
for checked_binary in "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/$VDHOST_PRODUCT"; do
    MINOS=$(vtool -show-build "$checked_binary" 2>/dev/null | awk '/minos/ { print $2; exit }')
    if [ "$MINOS" = "$LS_MIN" ]; then
        echo "build-app.sh: $(basename "$checked_binary") minos $MINOS matches LSMinimumSystemVersion $LS_MIN"
    else
        echo "build-app.sh: note - $(basename "$checked_binary") minos '$MINOS' differs from LSMinimumSystemVersion '$LS_MIN'"
    fi
done

echo "build-app.sh: spctl --assess --type execute (informational only; expected to fail" \
     "for anything but a notarized Developer ID build):"
if spctl --assess --type execute --verbose=4 "$APP_BUNDLE" 2>&1; then
    echo "build-app.sh: spctl assessment PASSED"
else
    echo "build-app.sh: spctl assessment FAILED (expected unless this is a stapled," \
         "notarized Developer ID build - see Scripts/notarize.sh)"
fi

echo "build-app.sh: bundle manifest:"
find "$APP_BUNDLE" -type f

echo "build-app.sh: done. App bundle at $APP_BUNDLE (version $VERSION, build $BUILD_NUMBER, identity: $IDENTITY)"
