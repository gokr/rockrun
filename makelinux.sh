#!/bin/bash
# Build a Linux AppImage for Rockrun.
# Requires: appimagetool in PATH (https://github.com/AppImage/AppImageKit)
set -e

# Get script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEST=build/appimage/rockrun.AppDir
NORX_DIR="${NORX_DIR:-$HOME/tankfeud/norx}"
ORX_LIB="$NORX_DIR/orx/code/lib/dynamic/liborx.so"

if [ ! -f "$ORX_LIB" ]; then
  echo "Error: liborx.so not found at $ORX_LIB"
  echo "Set NORX_DIR to your Norx checkout and build ORX (release64)."
  exit 1
fi

if ! command -v appimagetool >/dev/null 2>&1; then
  echo "Error: appimagetool not found in PATH"
  exit 1
fi

# Extract version from rockrun.nimble
VERSION=$(grep -E '^version\s*=\s*"[^"]+"' rockrun.nimble | sed -E 's/version[[:space:]]*=[[:space:]]*"([^"]+)"/\1/')

echo "=== Building Rockrun ${VERSION} Linux AppImage ==="

# Clean out previous build
rm -rf $DEST
mkdir -p $DEST/usr/{bin,lib}

# Copy template extras
cp -a templates/appimage/rockrun-AppDir.x86-64/. $DEST/

# Game data next to the binary (bootstrap looks in getAppDir()/data)
cp -a data $DEST/usr/bin/

# ORX runtime library
cp "$ORX_LIB" $DEST/usr/lib/

# Build the binary (release)
nim c -d:release -o:$DEST/usr/bin/rockrun src/rockrun.nim

# AppRun makes the bundled library findable
chmod +x $DEST/AppRun

# Package
appimagetool $DEST "build/Rockrun-${VERSION}-linux-x86_64.AppImage"
echo "Created build/Rockrun-${VERSION}-linux-x86_64.AppImage"
