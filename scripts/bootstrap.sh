#!/bin/bash
# Prepares a fresh checkout: the Xcode project is generated from project.yml,
# not committed, so this must run before opening neiro.xcodeproj.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Installing XcodeGen…"
    brew install xcodegen
fi

xcodegen generate
echo "Ready: open neiro.xcodeproj, or run scripts/ci.sh"
