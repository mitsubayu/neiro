#!/bin/bash
# The exact checks CI runs, so a green run here means a green pipeline.
# Usage: scripts/ci.sh [--release]
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA="build"
RESULTS="build/reports"
mkdir -p "$RESULTS"

echo "▸ Generating project"
./scripts/bootstrap.sh >/dev/null

echo "▸ Unit tests (Debug)"
set -o pipefail
xcodebuild \
    -project neiro.xcodeproj \
    -scheme neiro \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULTS/tests.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    test 2>&1 | tee "$RESULTS/test.log" | grep -E "Test run with|✘|error:|BUILD" || true
grep -q "Test run with .* passed" "$RESULTS/test.log" || {
    echo "✘ tests failed — see $RESULTS/test.log"
    exit 1
}

echo "▸ Release build"
xcodebuild \
    -project neiro.xcodeproj \
    -scheme neiro \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$RESULTS/build.log" 2>&1 || {
    echo "✘ release build failed — see $RESULTS/build.log"
    exit 1
}

echo "✓ all checks passed"
