#!/usr/bin/env python3
"""Minimal DevTools-protocol client for the read-only field capture workflow.

The user logs in manually in the Chrome window this project launches. After that, this
script connects to the page target and evaluates *read-only* expressions in the console
context, so no credentials are ever typed, read or stored by the agent. Nothing is sent
to the device except the requests the page itself makes.

Usage:
    python3 script/cdp.py tabs
    python3 script/cdp.py eval "<expression>"
    python3 script/cdp.py navigate <url>
"""
import json
import subprocess
import sys
import urllib.request
from urllib.parse import urlparse

import os


def _pick_port():
    """CDP_PORT wins; otherwise the first of 9222/9223 that serves /json/list.

    Chrome's chrome://inspect remote-debugging mode has no HTTP /json endpoint, so a
    port that answers with an empty body is skipped.
    """
    if os.environ.get("CDP_PORT"):
        return int(os.environ["CDP_PORT"])
    for port in (9222, 9223):
        try:
            with urllib.request.urlopen(f"http://localhost:{port}/json/list", timeout=2) as r:
                if json.loads(r.read().decode()):
                    return port
        except Exception:
            continue
    return 9222


PORT = _pick_port()
BASE = f"http://localhost:{PORT}"


def http_json(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as response:
        return json.loads(response.read().decode())


def page_target():
    for target in http_json("/json/list"):
        if target.get("type") == "page" and "192.168.8.1" in target.get("url", "") \
                and "fh_api" not in target.get("url", ""):
            return target
    raise SystemExit("no page target found")


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
    completed = subprocess.run(
        [node, "-e", script, ws_url, json.dumps(calls)],
        capture_output=True, text=True, timeout=60,
    )
    if completed.returncode != 0:
        raise SystemExit(completed.stderr.strip() or "cdp call failed")
    return json.loads(completed.stdout.strip().splitlines()[-1])


def _node_path():
    candidates = [
        "/Users/developer/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/node/bin/node",
    ]
    for path in candidates:
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
            if target.get("type") == "page":
                print(f"{target['url']}\n  {target['webSocketDebuggerUrl']}")
        return 0
    if command == "eval":
        result = evaluate(argv[2])
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    if command == "navigate":
        url = argv[2]
        parsed = urlparse(url)
        if parsed.hostname != "192.168.8.1":
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
