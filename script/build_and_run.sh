#!/bin/bash
# Builds FiberHomeCPEManager.app with the widget extension embedded, signs both with the local
# ad-hoc identity, and (unless --build-only) launches the result.
set -euo pipefail
cd "$(dirname "$0")/.."

# The active CLT ships an SDK newer than the installed Swift if SDKROOT is not pinned.
# 26.5 is the newest SDK whose Swift interface matches the installed compiler.
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
# Builder caches must live inside the workspace: the user-level SwiftPM caches are not
# writable from the sandbox this project is developed in.
export TMPDIR="${TMPDIR:-$PWD/.build/tmp}"
mkdir -p .build/tmp .build/mcache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/mcache"
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/mcache"

swift build --disable-sandbox --scratch-path .build --product FiberHomeCPEManager
swift build --disable-sandbox --scratch-path .build --product FiberHomeCPEManagerWidget
bin="$(swift build --disable-sandbox --scratch-path .build --show-bin-path)"

app="$PWD/build/FiberHomeCPEManager.app"
ext="$app/Contents/PlugIns/FiberHomeCPEManagerWidget.appex"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LoginItems"
mkdir -p "$ext/Contents/MacOS" "$ext/Contents/Resources"

cp "$bin/FiberHomeCPEManager" "$app/Contents/MacOS/FiberHomeCPEManager"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp Packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
for resource in "$bin"/*.bundle; do
  [[ -d "$resource" ]] && cp -R "$resource" "$app/Contents/Resources/"
done

cp "$bin/FiberHomeCPEManagerWidget" "$ext/Contents/MacOS/FiberHomeCPEManagerWidget"
cp Packaging/FiberHomeCPEManagerWidgetInfo.plist "$ext/Contents/Info.plist"
if [[ -f Packaging/Extension.entitlements ]]; then
  cp Packaging/Extension.entitlements "$ext/Contents/FiberHomeCPEManagerWidget.entitlements"
fi

# Sign inside-out: the extension first, then the containing app.
codesign --force --sign - --entitlements Packaging/FiberHomeCPEManagerWidget.entitlements --timestamp=none "$ext"
codesign --force --sign - --entitlements Packaging/FiberHomeCPEManager.entitlements --timestamp=none "$app"
codesign --verify --strict --deep "$app"

# Register the app with LaunchServices and the widget with PlugInKit so the desktop
# gallery can see the extension without a reboot.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$app" >/dev/null 2>&1 || true

if [[ "${1:-}" != "--build-only" ]]; then
  pkill -x FiberHomeCPEManager || true
  sleep 0.5
  open -n "$app"
fi
