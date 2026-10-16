#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; fi
plugin="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$plugin" ]]; then
 swift test -Xswiftc -load-plugin-library -Xswiftc "$plugin" "$@"
else
 swift test "$@"
fi
