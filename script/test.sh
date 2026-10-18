#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; fi
export TMPDIR="${TMPDIR:-$PWD/.build/tmp}"
mkdir -p .build/tmp .build/mcache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/mcache"
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/mcache"
plugin="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$plugin" ]]; then
 swift test --disable-sandbox --scratch-path .build -Xswiftc -load-plugin-library -Xswiftc "$plugin" "$@"
else
 swift test --disable-sandbox --scratch-path .build "$@"
fi
