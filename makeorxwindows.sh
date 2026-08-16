#!/bin/bash
# Build Windows x64 ORX dlls in the Vagrant VM.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

vagrant up
vagrant provision --provision-with build-orx
