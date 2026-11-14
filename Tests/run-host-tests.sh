#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun --sdk macosx clang -fobjc-arc -Wall -framework Foundation -framework CoreFoundation -lz \
  Tests/HostHarness.m Shared/PFShared.m Daemon/PFTendiesArchive.m -o build/tests/host-harness
PF_HOST_TEST_BIN="$PWD/build/tests/host-harness" python3 -m unittest discover -s Tests -v
