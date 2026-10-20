import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


def load_client():
    spec = importlib.util.spec_from_file_location("device_cdp", Path(__file__).with_name("cdp.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Response:
    def __init__(self, targets):
        self.targets = targets
    def __enter__(self):
        return self
    def __exit__(self, *_):
        return False
    def read(self):
        return json.dumps(self.targets).encode()


class CDPDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"CPE_HOST": "192.168.8.1"})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        for name in ["CDP_PORT", "CDP_HOST"]:
            os.environ.pop(name, None)
        self.client = load_client()
        self.device = {"type": "page", "url": "http://192.168.8.1/main.html"}

    def test_device_hostname_is_matched_exactly(self):
        self.assertFalse(self.client.is_device_target({"type": "page", "url": "https://example.invalid/?192.168.8.1"}))
        self.assertFalse(self.client.is_device_target({"type": "page", "url": "http://192.168.8.1/fh_api/sign/DO_WEB_LOGIN"}))
        self.assertTrue(self.client.is_device_target(self.device))

    def test_another_browser_on_first_port_does_not_hide_the_device(self):
        def endpoint(url, **_):
            return Response([self.device] if ":9223/" in url else [{"type": "page", "url": "https://example.invalid"}])
        with patch("urllib.request.urlopen", side_effect=endpoint):
            self.assertEqual(self.client._pick_endpoint(), "http://127.0.0.1:9223")

    def test_localhost_can_reach_a_different_ipv6_listener(self):
        def endpoint(url, **_):
            if "127.0.0.1" in url:
                raise OSError("not the CDP listener")
            return Response([self.device])
        with patch("urllib.request.urlopen", side_effect=endpoint):
            self.assertEqual(self.client._pick_endpoint(), "http://localhost:9222")

    def test_no_endpoint_fails_before_an_evaluation_is_sent(self):
        with patch("urllib.request.urlopen", side_effect=OSError("offline")), patch.object(self.client, "run_cdp") as send:
            with self.assertRaisesRegex(SystemExit, "no request sent"):
                self.client.evaluate("sensitive-expression")
            send.assert_not_called()

    def test_invalid_port_does_not_open_a_connection(self):
        with patch.dict(os.environ, {"CDP_PORT": "65536"}), patch("urllib.request.urlopen") as connect:
            with self.assertRaises(SystemExit):
                self.client._pick_endpoint()
            connect.assert_not_called()

    def test_timeout_never_prints_the_expression_or_replays_it(self):
        with patch.object(self.client, "_node_path", return_value="node"), patch("subprocess.run", side_effect=subprocess.TimeoutExpired("contains-secret", 60)) as process:
            with self.assertRaises(SystemExit) as error:
                self.client.run_cdp("ws://localhost:9222/test", [{"method": "Runtime.evaluate", "params": {"expression": "secret"}}])
            self.assertNotIn("secret", str(error.exception))
            self.assertEqual(process.call_count, 1)


if __name__ == "__main__":
    unittest.main()
