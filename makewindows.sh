#!/bin/bash
# Build a Windows x64 zip for Rockrun using a Vagrant Windows 10 VM.
# Requires: vagrant + virtualbox, and the VM provisioned with
# scripts/windows-setup.bat (run manually once as Administrator inside the
# VM - it installs Chocolatey, Git, Nim, MinGW).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEST=$SCRIPT_DIR/build/windows/rockrun.WindowsDir

# Clean out previous build
rm -rf $DEST
mkdir -p $DEST

# Copy template
cp -a templates/windows/rockrun-WindowsDir.x86_64/. $DEST/ || true
cp -a data $DEST/

# Build orx.dll if needed and copy it
if [ ! -f $SCRIPT_DIR/build/orx/orx.dll ]; then
  echo "orx.dll not found, building it in the VM..."
  ./makeorxwindows.sh
fi
cp $SCRIPT_DIR/build/orx/orx.dll $DEST/

# Build the exe in the VM
echo "Building rockrun.exe in the Vagrant VM..."
vagrant up
vagrant provision --provision-with build-rockrun
if [ $? -ne 0 ]; then
  echo "Error: failed to build rockrun in the VM"
  exit 1
fi
if [ ! -e $SCRIPT_DIR/build/rockrun.exe ]; then
  echo "Error: build/rockrun.exe not found"
  exit 1
fi
mv $SCRIPT_DIR/build/rockrun.exe $DEST/

# Extract version
VERSION=$(grep -E '^version\s*=\s*"[^"]+"' rockrun.nimble | sed -E 's/version[[:space:]]*=[[:space:]]*"([^"]+)"/\1/')

# Zip it
cd build/windows
FILENAME="Rockrun-${VERSION}-windows-x86_64"
rm -rf $FILENAME 2>/dev/null
rm -f ../$FILENAME.zip 2>/dev/null
mv rockrun.WindowsDir $FILENAME
zip -r ../$FILENAME.zip $FILENAME
echo "Created build/$FILENAME.zip"
