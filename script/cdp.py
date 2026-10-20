#!/usr/bin/env python3
"""Device-scoped CDP client for protocol inspection.

Selects the actual device tab on a live localhost/127.0.0.1 endpoint (9222/9223).
It does not log evaluation arguments, log in automatically, or replay failed requests.
Evaluation can perform explicit caller-authorized audits; return only non-secret results.

Usage:
    python3 script/cdp.py tabs
    python3 script/cdp.py eval "<expression>"
    python3 script/cdp.py navigate <device-url>
"""
import json
import subprocess
import sys
import urllib.request
from urllib.parse import urlparse

import os
from pathlib import Path
from shutil import which


DEVICE_HOST = os.environ.get("CPE_HOST", "192.168.8.1")
BASE = None


def is_device_target(target):
    return target.get("type") == "page" and urlparse(target.get("url", "")).hostname == DEVICE_HOST \
        and not urlparse(target.get("url", "")).path.startswith("/fh_api/")


def _pick_endpoint():
    configured = os.environ.get("CDP_PORT")
    try:
        ports = [int(configured)] if configured else [9222, 9223]
    except ValueError:
        raise SystemExit("CDP_PORT must be a valid TCP port")
    if any(not 1 <= port <= 65535 for port in ports):
        raise SystemExit("CDP_PORT must be between 1 and 65535")
    hosts = [os.environ["CDP_HOST"]] if os.environ.get("CDP_HOST") else ["127.0.0.1", "localhost"]
    for port in ports:
        for host in hosts:
            base = f"http://{host}:{port}"
            try:
                with urllib.request.urlopen(base + "/json/list", timeout=2) as response:
                    targets = json.loads(response.read().decode())
                if isinstance(targets, list) and any(is_device_target(t) for t in targets if isinstance(t, dict)):
                    return base
            except (OSError, ValueError):
                continue
    raise SystemExit("CDP unavailable: no device tab on 127.0.0.1/localhost:9222 or 9223; no request sent")


def http_json(path):
    global BASE
    if BASE is None:
        BASE = _pick_endpoint()
    try:
        with urllib.request.urlopen(BASE + path, timeout=5) as response:
            return json.loads(response.read().decode())
    except (OSError, ValueError):
        raise SystemExit("CDP endpoint disconnected; no request replayed") from None


def page_target():
    targets = http_json("/json/list")
    if isinstance(targets, list):
        for target in targets:
            if isinstance(target, dict) and is_device_target(target):
                return target
    raise SystemExit("no device page target found")


def run_cdp(ws_url, calls):
    """Drives the page over the WebSocket using the bundled Node runtime."""
    node = _node_path()
    script = r"""
const [wsUrl, callsJson] = process.argv.slice(1);
const calls = JSON.parse(callsJson);
const ws = new WebSocket(wsUrl);
let index = 0;
const results = [];
ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: "Runtime.enable" }));
ws.onmessage = (event) => {
  const message = JSON.parse(event.data);
  if (message.id === 1) { send(); return; }
  if (message.id && message.id >= 2) {
    results.push(message.result ?? message.error ?? null);
    send();
  }
};
function send() {
  if (index >= calls.length) {
    console.log(JSON.stringify(results));
    ws.close();
    return;
  }
  const call = calls[index++];
  ws.send(JSON.stringify({ id: index + 1, ...call }));
}
ws.onerror = (error) => { console.error("WS_ERROR", String(error.message ?? error)); process.exit(1); };
"""
    try:
        completed = subprocess.run(
            [node, "-e", script, ws_url, json.dumps(calls)],
            capture_output=True, text=True, timeout=60,
        )
    except subprocess.TimeoutExpired:
        # TimeoutExpired includes the complete command, which can include credentials.
        raise SystemExit("CDP request timed out; no request replayed") from None
    if completed.returncode != 0:
        raise SystemExit(completed.stderr.strip() or "cdp call failed")
    return json.loads(completed.stdout.strip().splitlines()[-1])


def _node_path():
    candidates = [
        os.environ.get("CPE_NODE_PATH"),
        which("node"),
        str(Path.home() / ".dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin/node"),
    ]
    for path in candidates:
        if not path:
            continue
        try:
            subprocess.run([path, "--version"], capture_output=True, check=True, timeout=5)
            return path
        except Exception:
            continue
    return "node"


def evaluate(expression):
    target = page_target()
    calls = [{
        "method": "Runtime.evaluate",
        "params": {"expression": expression, "returnByValue": True, "awaitPromise": True},
    }]
    return run_cdp(target["webSocketDebuggerUrl"], calls)[0]


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    command = argv[1]
    if command == "tabs":
        for target in http_json("/json/list"):
            if is_device_target(target):
                print(f"{target['url']}\n  {target['webSocketDebuggerUrl']}")
        return 0
    if command == "eval":
        result = evaluate(argv[2])
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    if command == "navigate":
        url = argv[2]
        parsed = urlparse(url)
        if parsed.hostname != DEVICE_HOST:
            raise SystemExit("refusing to navigate away from the device origin")
        target = page_target()
        run_cdp(target["webSocketDebuggerUrl"], [{
            "method": "Page.navigate", "params": {"url": url},
        }])
        print("navigated")
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
