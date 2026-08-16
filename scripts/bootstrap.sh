#!/bin/bash
# Prepares a fresh checkout: the Xcode project is generated from project.yml,
# not committed, so this must run before opening neiro.xcodeproj.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Installing XcodeGen…"
    brew install xcodegen
fi

# Sign as whoever is building. Xcode's automatic signing needs a team id, and
# hardcoding the author's in project.yml would only break everyone else's
# build — so take it from the environment, falling back to the team on the
# first codesigning identity in the keychain. Empty is fine: scripts/ci.sh
# builds unsigned when there is no identity at all.
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    identity=$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/.*"\(Apple Develop[^"]*\)".*/\1/p' | head -1)
    # The team id is the certificate's OU. The name's parenthetical looks like
    # one but is a different identifier — signing with it fails.
    if [[ -n "$identity" ]]; then
        DEVELOPMENT_TEAM=$(security find-certificate -c "$identity" -p 2>/dev/null |
            openssl x509 -noout -subject 2>/dev/null |
            sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' | head -1)
    fi
fi
export DEVELOPMENT_TEAM

xcodegen generate
echo "Ready: open neiro.xcodeproj, or run scripts/ci.sh"
