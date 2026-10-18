#!/bin/bash
# Complete UI matrix, one run, one summary.
#
#   ./script/ui_matrix.sh                 # everything that needs no device session
#   CPE_PASS='…' ./script/ui_matrix.sh    # also logs in and covers the connected pages
#
# Design notes:
#   * One pass. The earlier version needed two invocations (logged out / logged in) and was
#     often run twice just to count results; every scenario now runs exactly once.
#   * Phases are ordered so the panel starts clean: login-page checks first, then a single
#     login, then every connected check, then the two quit paths (which need fresh
#     processes and therefore run last).
#   * The exit code reflects failures; the old script exited 0 even when checks failed.
#   * The password only goes into the app's own password field; it is never logged.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="build/FiberHomeCPEManager.app"
CPE_HOST="${CPE_HOST:-192.168.8.1}"
PROBE=".build/ui_probe"
LOGIN=".build/ui_login"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"

# Keep compiler caches inside the workspace: the default /var/folders location is not
# writable for this sandboxed shell.
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/mcache"
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/mcache"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

pass=0
fail=0
skip=0
failed=()
started=$(date +%s)

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Only recompile when the source is newer than the binary.
build() {
    local src="$1" out="$2"
    if [ ! -x "$out" ] || [ "$src" -nt "$out" ]; then
        echo "building $(basename "$out")…"
        SDKROOT="$SDK" xcrun swiftc -target arm64-apple-macos14.0 "$src" -o "$out" || exit 1
    fi
}

# A menu-bar client can only exercise the connected pages when the CPE is on this Mac's
# network. Without a precheck an offline device looks like a broken app.
device_reachable() {
    local code
    code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://$CPE_HOST/" 2>/dev/null)
    code=${code:-000}
    [ "$code" != "000" ]
}

relaunch() {
    # The app is sandboxed and launched from inside this sandboxed shell; libsecinit
    # intermittently SIGTRAPs before applicationDidFinishLaunching (no code runs). Retry
    # rather than reporting every later scenario as "no status item".
    local attempt
    for attempt in 1 2 3 4 5; do
        pkill -x FiberHomeCPEManager 2>/dev/null
        for _ in $(seq 1 20); do pgrep -x FiberHomeCPEManager >/dev/null || break; sleep 0.1; done
        open -n "$APP"
        for _ in $(seq 1 40); do pgrep -x FiberHomeCPEManager >/dev/null && break; sleep 0.1; done
        sleep 1.5   # let the status item register and catch an immediate launch crash
        if pgrep -x FiberHomeCPEManager >/dev/null; then return 0; fi
        echo "  app launch attempt $attempt failed (sandbox init)"
    done
    return 1
}

# Runs one scenario and folds its PASS/FAIL/SKIP lines into the summary.
ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

run() {
    local name="$1" out p f s t0 t1
    t0=$(ms)
    out=$("$PROBE" "$name" 2>&1)
    t1=$(ms)
    p=$(printf '%s\n' "$out" | grep -c 'PASS')
    f=$(printf '%s\n' "$out" | grep -c 'FAIL')
    s=$(printf '%s\n' "$out" | grep -c 'SKIP')
    pass=$((pass + p)); fail=$((fail + f)); skip=$((skip + s))
    printf '  %-22s %2d pass  %5dms' "$name" "$p" "$((t1 - t0))"
    [ "$f" -gt 0 ] && printf '  \033[31m%d fail\033[0m' "$f"
    [ "$s" -gt 0 ] && printf '  %d skip' "$s"
    printf '\n'
    if [ "$f" -gt 0 ]; then
        failed+=("$name")
        printf '%s\n' "$out" | grep 'FAIL' | sed 's/^/      /'
    fi
}

build script/ui_probe.swift "$PROBE"
build script/ui_login.swift "$LOGIN"

# ---------------------------------------------------------------- phase 1: login page
say "phase 1 · login page"
relaunch
for scenario in login-empty login-extra login-fullwidth esc cmdw external-click about; do
    run "$scenario"
done

# ---------------------------------------------------------------- reachability
say "device"
if device_reachable; then
    echo "  reachable  http://$CPE_HOST/"
    DEVICE=1
else
    echo "  [33munreachable[0m  http://$CPE_HOST/  (不在本机网段，跳过已连接检查)"
    DEVICE=0
fi

# ---------------------------------------------------------------- login once
# A fresh instance keeps the address field at its default and keeps AppKit's key window
# sane; typing into a panel that several scenarios have toggled is unreliable.
say "login"
LOGGED_IN=0
relaunch
if [ -n "${CPE_PASS:-}" ] && [ "$DEVICE" = "1" ]; then
    if "$LOGIN" 2>&1 | grep -q "LOGIN OK"; then
        echo "  PASS  UI 登录"
        pass=$((pass + 1)); LOGGED_IN=1
    else
        echo "  FAIL  UI 登录"
        fail=$((fail + 1)); failed+=("login")
        # A stale login page after a failed attempt would make every connected scenario
        # fail with "no status item" style noise; start clean for the quit-path checks.
        relaunch
    fi
elif [ -z "${CPE_PASS:-}" ]; then
    echo "  SKIP  未提供 CPE_PASS，跳过已连接页检查"
    skip=$((skip + 1))
else
    echo "  SKIP  设备不可达，跳过登录与已连接页检查"
    skip=$((skip + 1))
fi

# ---------------------------------------------------------------- phase 2: connected app
if [ -n "${CPE_PASS:-}" ] && [ "$DEVICE" = "1" ] && [ "$LOGGED_IN" = "1" ]; then
    say "phase 2 · connected"
    for scenario in contextmenu styles keys devices-filter-select a11y controls sms sms-poll relogin; do
        run "$scenario"
    done
fi

# ---------------------------------------------------------------- quit paths (last)
say "quit paths"
relaunch
run "power"
relaunch
run "cmdq"

elapsed=$(( $(date +%s) - started ))
say "summary"
printf '  %d passed, %d failed, %d skipped  (%ds)\n' "$pass" "$fail" "$skip" "$elapsed"
if [ "$fail" -gt 0 ]; then
    printf '  failing scenarios: %s\n' "${failed[*]}"
    exit 1
fi
