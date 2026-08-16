#!/bin/bash
# Publish Rockrun builds to itch.io using butler.
# Usage: ./publish.sh gokr/rockrun
#   or:  ITCH_TARGET=gokr/rockrun ./publish.sh
set -e

ITCH_TARGET="${1:-${ITCH_TARGET}}"
if [ -z "$ITCH_TARGET" ]; then
  echo "Error: no itch.io target specified"
  echo "Usage: $0 username/gamename"
  exit 1
fi

if ! command -v butler >/dev/null 2>&1; then
  echo "Error: butler not found in PATH (https://itch.io/docs/butler)"
  exit 1
fi

VERSION=$(grep -E '^version\s*=\s*"[^"]+"' rockrun.nimble | sed -E 's/version[[:space:]]*=[[:space:]]*"([^"]+)"/\1/')
echo "Publishing Rockrun ${VERSION} to ${ITCH_TARGET}"

BUILD_DIR="build"
LINUX_BUILD="${BUILD_DIR}/Rockrun-${VERSION}-linux-x86_64.AppImage"
WINDOWS_BUILD="${BUILD_DIR}/Rockrun-${VERSION}-windows-x86_64.zip"
MAC_BUILD="${BUILD_DIR}/Rockrun-${VERSION}-mac.dmg"

PUBLISHED=0
FAILED=0
SKIPPED=0

publish_build() {
  local FILE="$1" CHANNEL="$2"
  if [ ! -f "$FILE" ]; then
    echo "Skipping ${CHANNEL}: ${FILE} not found"
    SKIPPED=$((SKIPPED + 1))
    return
  fi
  echo "Publishing ${CHANNEL} from ${FILE}..."
  if butler push "$FILE" "${ITCH_TARGET}:${CHANNEL}" --userversion "$VERSION"; then
    echo "Published ${CHANNEL}"
    PUBLISHED=$((PUBLISHED + 1))
  else
    echo "Failed to publish ${CHANNEL}"
    FAILED=$((FAILED + 1))
  fi
}

publish_build "$LINUX_BUILD" "linux"
publish_build "$WINDOWS_BUILD" "windows"
publish_build "$MAC_BUILD" "mac"

echo ""
echo "=== Summary: published=$PUBLISHED failed=$FAILED skipped=$SKIPPED ==="
if [ "$FAILED" -gt 0 ]; then exit 1; fi
if [ "$PUBLISHED" -eq 0 ]; then echo "Nothing published"; exit 1; fi
