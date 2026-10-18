#!/bin/bash
# Verifies the two sizing invariants that were broken before:
#   1. the menu-bar item width never changes while data refreshes;
#   2. the popover window stays at exactly 350x580 on every page.
#
# Requires the app to be running with an open menu-bar item. Uses Accessibility, so the
# calling process needs Accessibility permission (already granted for this workspace).
set -euo pipefail
cd "$(dirname "$0")/.."

SAMPLES="${SAMPLES:-20}"
INTERVAL="${INTERVAL:-1}"

swiftc -O -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)" \
  script/width_probe.swift -o .build/width_probe 2>/dev/null

if ! pgrep -x FiberHomeCPEManager >/dev/null; then
  echo "FiberHomeCPEManager is not running; start it with ./script/build_and_run.sh" >&2
  exit 1
fi

.build/width_probe menubar "$SAMPLES" "$INTERVAL"
.build/width_probe window "$SAMPLES" "$INTERVAL"
