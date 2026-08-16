#!/bin/bash
# Build a macOS app bundle + DMG for Rockrun.
# Run on macOS. Uses the ORX dylib from the Norx checkout.
# Usage: ./makemac.sh [--universal]
set -e

APP_NAME="rockrun"
BUNDLE_NAME="Rockrun"
BUNDLE_ID="com.rockrun.game"
UNIVERSAL=false

for arg in "$@"; do
  case $arg in
    --universal) UNIVERSAL=true ;;
  esac
done

# Verify ORX environment variable (Norx checkout)
NORX_DIR="${NORX_DIR:-$HOME/tankfeud/norx}"
ORX="$NORX_DIR/orx"
if [ ! -d "$ORX" ]; then
  echo "Error: ORX directory not found at $ORX"
  echo "Set NORX_DIR to your Norx checkout."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Extract version
VERSION=$(grep -E '^version\s*=\s*"[^"]+"' rockrun.nimble | sed -E 's/version[[:space:]]*=[[:space:]]*"([^"]+)"/\1/')

MIN_VERSION="11.0"
BUILD_DIR="${SCRIPT_DIR}/build/macos"
APP_BUNDLE="${BUILD_DIR}/${BUNDLE_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
ORX_LIB="${ORX}/code/lib/dynamic/liborx.dylib"

echo "=== Building ${BUNDLE_NAME} ${VERSION} macOS DMG ==="

if [ ! -f "$ORX_LIB" ]; then
  echo "Error: liborx.dylib not found at $ORX_LIB"
  echo "Build ORX for mac first (code/build/mac/gmake: make config=release64)."
  exit 1
fi

# Step 1: prepare build directory
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Step 2: build the binary
echo "Building ${APP_NAME}..."
rm -rf ~/.cache/nim/${APP_NAME}_r

if [ "$UNIVERSAL" = true ]; then
  HOST_ARCH=$(uname -m)
  echo "Building for x86_64..."
  nim c -d:release --cpu:amd64 \
    --passC:"-target x86_64-apple-macos -mmacosx-version-min=${MIN_VERSION}" \
    --passL:"-target x86_64-apple-macos -mmacosx-version-min=${MIN_VERSION}" \
    -o:${APP_NAME}_x86_64 src/${APP_NAME}.nim
  if [ "$HOST_ARCH" = "arm64" ]; then
    echo "Building for arm64..."
    rm -rf ~/.cache/nim/${APP_NAME}_r
    nim c -d:release --cpu:arm64 \
      --passC:"-mmacosx-version-min=${MIN_VERSION}" \
      --passL:"-mmacosx-version-min=${MIN_VERSION}" \
      -o:${APP_NAME}_arm64 src/${APP_NAME}.nim
    lipo -create ${APP_NAME}_x86_64 ${APP_NAME}_arm64 -output ${APP_NAME}
    rm -f ${APP_NAME}_x86_64 ${APP_NAME}_arm64
  else
    mv ${APP_NAME}_x86_64 ${APP_NAME}
  fi
else
  nim c -d:release -o:${APP_NAME} src/${APP_NAME}.nim
fi
lipo -info ${APP_NAME}

# Step 3: app bundle structure
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Frameworks"
mkdir -p "${CONTENTS}/Resources"

cp "${APP_NAME}" "${CONTENTS}/MacOS/"
cp "${ORX_LIB}" "${CONTENTS}/Frameworks/"
cp -a data "${CONTENTS}/MacOS/"
cp -a data "${CONTENTS}/Resources/"

# Icon
ICON_SRC="${SCRIPT_DIR}/assets/rockrun.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="${BUILD_DIR}/rockrun.iconset"
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ICON_SRC" --out "${ICONSET}/icon_16x16.png" >/dev/null 2>&1
  sips -z 32 32 "$ICON_SRC" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null 2>&1
  sips -z 32 32 "$ICON_SRC" --out "${ICONSET}/icon_32x32.png" >/dev/null 2>&1
  sips -z 64 64 "$ICON_SRC" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null 2>&1
  sips -z 128 128 "$ICON_SRC" --out "${ICONSET}/icon_128x128.png" >/dev/null 2>&1
  sips -z 256 256 "$ICON_SRC" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null 2>&1
  sips -z 256 256 "$ICON_SRC" --out "${ICONSET}/icon_256x256.png" >/dev/null 2>&1
  sips -z 512 512 "$ICON_SRC" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null 2>&1
  sips -z 512 512 "$ICON_SRC" --out "${ICONSET}/icon_512x512.png" >/dev/null 2>&1
  sips -z 1024 1024 "$ICON_SRC" --out "${ICONSET}/icon_512x512@2x.png" >/dev/null 2>&1
  iconutil -c icns "$ICONSET" -o "${CONTENTS}/Resources/rockrun.icns"
  rm -rf "$ICONSET"
fi

# Step 4: fix dylib paths
install_name_tool -change @executable_path/liborx.dylib \
  @executable_path/../Frameworks/liborx.dylib "${CONTENTS}/MacOS/${APP_NAME}" 2>/dev/null || true
install_name_tool -change "$ORX_LIB" \
  @executable_path/../Frameworks/liborx.dylib "${CONTENTS}/MacOS/${APP_NAME}" 2>/dev/null || true

# Step 5: Info.plist
cat > "${CONTENTS}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${BUNDLE_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${BUNDLE_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>rockrun</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_VERSION}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.games</string>
</dict>
</plist>
EOF

# Step 6: ad-hoc codesign
codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --verbose "${APP_BUNDLE}" || echo "Note: ad-hoc signing may show warnings"

# Step 7: DMG
DMG_NAME="Rockrun-${VERSION}-mac.dmg"
DMG_STAGING="${BUILD_DIR}/dmg_staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -a "${APP_BUNDLE}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
rm -f "${SCRIPT_DIR}/build/${DMG_NAME}"
hdiutil create -volname "Rockrun ${VERSION}" -srcfolder "${DMG_STAGING}" \
  -ov -format UDZO "${SCRIPT_DIR}/build/${DMG_NAME}"
rm -rf "${DMG_STAGING}"

echo ""
echo "=== Build complete! ==="
echo "App bundle: ${APP_BUNDLE}"
echo "DMG: ${SCRIPT_DIR}/build/${DMG_NAME}"
echo "Note: users may need right-click > Open on first launch (not notarized)."
