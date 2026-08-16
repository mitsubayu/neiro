#!/bin/bash
# The exact checks CI runs, so a green run here means a green pipeline.
# Usage: scripts/ci.sh [--release]
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED_DATA="build"
RESULTS="build/reports"
# xcodebuild refuses to overwrite an existing result bundle, so a repeat run
# locally would fail where a fresh CI agent would not.
rm -rf "$RESULTS"
mkdir -p "$RESULTS"

# CI agents have no certificate; a developer machine does. Building unsigned
# locally silently costs you the TCC grants (macOS re-prompts for audio
# capture on every launch), so only skip signing when there is no identity.
SIGNING=()
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    echo "▸ No signing identity — building unsigned"
    SIGNING=(CODE_SIGNING_ALLOWED=NO)
fi

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
    ${SIGNING[@]+"${SIGNING[@]}"} \
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
    ${SIGNING[@]+"${SIGNING[@]}"} \
    build >"$RESULTS/build.log" 2>&1 || {
    echo "✘ release build failed — see $RESULTS/build.log"
    exit 1
}

echo "✓ all checks passed"
