#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
# CLT 6.4 currently ships SwiftUI SDK macros separately; 26.5 remains supported.
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
 export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build --product FHCPEM
bin="$(swift build --show-bin-path)"
app="$PWD/build/FHCPEM.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/FHCPEM" "$app/Contents/MacOS/FHCPEM"
cp Packaging/Info.plist "$app/Contents/Info.plist"
for resource in "$bin"/*.bundle; do
 [[ -d "$resource" ]] && cp -R "$resource" "$app/Contents/Resources/"
done
codesign --force --sign - --entitlements Packaging/FHCPEM.entitlements "$app"
codesign --verify --strict "$app"
if [[ "${1:-}" != "--build-only" ]]; then
 pkill -x FHCPEM || true
 open -n "$app"
fi
