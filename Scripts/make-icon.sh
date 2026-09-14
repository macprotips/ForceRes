#!/bin/sh
# make-icon.sh
#
# Generates Resources/AppIcon.icns from code, with no external image assets.
# Renders PNGs at every size iconutil requires (via Scripts/make-icon.swift,
# using CoreGraphics/AppKit), then packs them into an .icns with `iconutil`.
#
# Usage: sh Scripts/make-icon.sh
#
# The intermediate .iconset directory is written to Resources/icon-build/
# (gitignored) and removed after a successful run; Resources/AppIcon.icns is
# the only generated artifact meant to be committed.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

ICONSET_DIR="$REPO_ROOT/Resources/icon-build/AppIcon.iconset"
ICNS_PATH="$REPO_ROOT/Resources/AppIcon.icns"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

echo "make-icon.sh: rendering iconset PNGs..."
swift "$SCRIPT_DIR/make-icon.swift" "$ICONSET_DIR"

echo "make-icon.sh: packing iconset into $ICNS_PATH"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

rm -rf "$REPO_ROOT/Resources/icon-build"

echo "make-icon.sh: wrote $ICNS_PATH"
