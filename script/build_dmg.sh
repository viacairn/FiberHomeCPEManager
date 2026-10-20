#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 script/package_release.py "$@"
