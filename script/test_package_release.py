import contextlib
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check_privacy
import package_release as release


class PackageReleaseTests(unittest.TestCase):
    def test_fresh_checkout_excludes_local_artifacts_without_tracking_gitignore(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            release.configure_local_excludes(root)
            before = (root / ".git/info/exclude").read_text()
            release.configure_local_excludes(root)
            self.assertEqual(before, (root / ".git/info/exclude").read_text())
            (root / ".gitignore").write_text("fixture")
            (root / "build").mkdir()
            (root / "build/release.bin").write_text("fixture")
            self.assertEqual(release.public_paths(root), [])

    def test_source_list_respects_local_exclusions_without_committing_gitignore(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".git/info/exclude").write_text("/.gitignore\n/.env\n/build/\n")
            for name in ["source.swift", ".gitignore", ".env"]:
                (root / name).write_text("fixture")
            (root / "build").mkdir()
            (root / "build/log.txt").write_text("fixture")
            self.assertEqual(release.public_paths(root), ["source.swift"])

    def test_binary_private_path_blocks_source_export(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "image.bin").write_bytes(b"\0\xff" + (check_privacy.HOME_PREFIX + "private-tester/file").encode())
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(RuntimeError):
                release.check_files(root, ["image.bin"], None)

    def app_fixture(self, root):
        app = root / "FiberHomeCPEManager.app"
        for component, executable in [(app, "FiberHomeCPEManager"),
                                      (app / "Contents/PlugIns/FiberHomeCPEManagerWidget.appex", "FiberHomeCPEManagerWidget")]:
            (component / "Contents/MacOS").mkdir(parents=True)
            (component / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": executable}))
            (component / "Contents/MacOS" / executable).write_bytes(b"\xcf\xfa\xed\xfe\0public-fixture")
        (app / "Contents/Resources").mkdir()
        for name in ["LICENSE", "NOTICE"]:
            (app / "Contents/Resources" / name).write_text("public fixture")
        return app

    @staticmethod
    def fake_tools(*args, **kwargs):
        return b"arm64\n" if args[0] == "lipo" else b""

    def test_mounted_app_audit_rejects_development_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.app_fixture(Path(temporary))
            (app / "Contents/Resources/debug.swift").write_text("fixture")
            with self.assertRaisesRegex(RuntimeError, "Development file"):
                release.audit_app(app, None, ["arm64"])

    def test_app_audit_checks_private_binary_strings(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = self.app_fixture(Path(temporary))
            (app / "Contents/MacOS/FiberHomeCPEManager").write_bytes(b"\0private-fixture-token\0")
            plan = {"confirmed_exact_replacements": [{"match_regex": "private-fixture-token", "category": "fixture"}]}
            with self.assertRaisesRegex(RuntimeError, "Artifact privacy check failed"):
                release.audit_app(app, plan, ["arm64"])

    def test_firmware_protocol_material_is_allowed_only_when_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(release, "run", self.fake_tools):
            app = self.app_fixture(Path(temporary))
            material = app / "Contents/Resources/firmware-protocol.der"
            material.write_bytes((release.ROOT / "Sources/FHCPECore/Resources/firmware-protocol.der").read_bytes())
            self.assertGreater(release.audit_app(app, None, ["arm64"]), 0)
            material.write_bytes(b"unrecognized-key")
            with self.assertRaisesRegex(RuntimeError, "unexpected-key-material"):
                release.audit_app(app, None, ["arm64"])

    def test_wrong_architecture_cannot_be_packaged(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(release, "run", return_value=b"wrong-architecture\n"):
            app = self.app_fixture(Path(temporary))
            with self.assertRaisesRegex(RuntimeError, "Incorrect release architectures"):
                release.audit_app(app, None, ["arm64"])


if __name__ == "__main__":
    unittest.main()
