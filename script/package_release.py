#!/usr/bin/env python3
"""Build an Apple Silicon Release DMG without local data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

import check_privacy


ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "FiberHomeCPEManager"


def run(*args, cwd=ROOT, capture=False, env=None):
    return subprocess.run([str(x) for x in args], cwd=cwd, env=env, check=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None).stdout


def public_paths(root=ROOT):
    data = run("git", "ls-files", "-co", "--exclude-standard", "-z", cwd=root, capture=True)
    return sorted({name for name in data.decode().split("\0")
                   if name and (root / name).is_file() and not check_privacy.is_local_api_path(name)})


def configure_local_excludes(root=ROOT):
    """Keep generated/private files local without requiring a committed .gitignore."""
    if not (root / ".git").exists():
        return
    relative = run("git", "rev-parse", "--git-path", "info/exclude", cwd=root, capture=True).decode().strip()
    path = Path(relative)
    if not path.is_absolute():
        path = root / path
    path.parent.mkdir(parents=True, exist_ok=True)
    existing = path.read_text() if path.exists() else ""
    entries = ["/.gitignore", "/.build/", "/build/", "/render/", "/.swiftpm/", "/.worktrees/",
               ".DS_Store", "__pycache__/", "*.py[cod]", "/.env", "/.env.*", "/.local-private/",
               "/docs/protocol/"]
    missing = [entry for entry in entries if entry not in existing.splitlines()]
    if missing:
        path.write_text(existing.rstrip() + "\n\n# Local-only artifacts and private settings\n" + "\n".join(missing) + "\n")


def check_files(root, names, plan):
    findings = []
    for name in names:
        path = root / name
        if path.is_symlink():
            findings.append((name, "unexpected-source-symlink"))
            continue
        for finding in check_privacy.path_findings(name) + check_privacy.payload_findings(path.read_bytes(), plan):
            findings.append((name, finding))
    if findings:
        for name, kind in findings:
            print(f"FAIL {name}: {kind}", file=sys.stderr)
        raise RuntimeError("Release source privacy check failed")


def audit_app(app, plan, architectures):
    forbidden_names = {".git", ".gitignore", ".DS_Store", "Tests", "UIRender", "FiberHomeCPEManagerProbe"}
    forbidden_suffixes = {".swift", ".swiftmodule", ".swiftdoc", ".py", ".pyc", ".sh", ".log", ".dSYM"}
    files = 0
    protocol_hash = hashlib.sha256((ROOT / "Sources/FHCPECore/Resources/firmware-protocol.der").read_bytes()).digest()
    for path in app.rglob("*"):
        if path.is_symlink():
            raise RuntimeError("Unexpected symlink inside application bundle")
        if not path.is_file():
            continue
        name = path.relative_to(app).as_posix()
        if forbidden_names.intersection(path.relative_to(app).parts) or path.suffix in forbidden_suffixes:
            raise RuntimeError("Development file found in application bundle: " + name)
        data = path.read_bytes()
        findings = check_privacy.path_findings(name) + check_privacy.payload_findings(data, plan)
        if path.suffix == ".der" and (path.name != "firmware-protocol.der" or hashlib.sha256(data).digest() != protocol_hash):
            findings.append("unexpected-key-material")
        if findings:
            raise RuntimeError("Artifact privacy check failed: " + name + ": " + ", ".join(findings))
        files += 1
    for component in [app, app / "Contents/PlugIns/FiberHomeCPEManagerWidget.appex"]:
        info = plistlib.loads((component / "Contents/Info.plist").read_bytes())
        binary = component / "Contents/MacOS" / info["CFBundleExecutable"]
        actual = set(run("lipo", "-archs", binary, capture=True).decode().split())
        if actual != set(architectures):
            raise RuntimeError("Incorrect release architectures")
        run("codesign", "--verify", "--strict", component)
        if not (app / "Contents/Resources/LICENSE").is_file() or not (app / "Contents/Resources/NOTICE").is_file():
            raise RuntimeError("Missing distribution license or notice")
    run("codesign", "--verify", "--strict", "--deep", app)
    return files


def build_app(work, output, names, architectures):
    source = work / "source"
    source.mkdir()
    for name in names:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
        target.chmod((ROOT / name).stat().st_mode & 0o777)
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(("CPE_", "FHCPE_")):
            env.pop(key)
    pinned_sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
    env["SDKROOT"] = str(pinned_sdk) if pinned_sdk.is_dir() else run("xcrun", "--show-sdk-path", capture=True).decode().strip()
    cache = work / "module-cache"
    cache.mkdir()
    env["CLANG_MODULE_CACHE_PATH"] = env["SWIFT_MODULE_CACHE_PATH"] = str(cache)
    env["TMPDIR"] = str(work)
    env["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    build = ["swift", "build", "--build-system", "swiftbuild", "--disable-sandbox", "--disable-keychain",
             "--configuration", "release", "--scratch-path", str(work / ".build")]
    for arch in architectures:
        build.extend(["--arch", arch])
    # Map compiler-origin paths as well as compiling from a non-personal temporary root.
    for original, replacement in [(str(source), "/src/FiberHomeCPEManager"), (str(Path.home()), "/builder")]:
        build.extend(["-Xswiftc", "-file-prefix-map", "-Xswiftc", original + "=" + replacement,
                      "-Xswiftc", "-debug-prefix-map", "-Xswiftc", original + "=" + replacement,
                      "-Xcc", "-ffile-prefix-map=" + original + "=" + replacement])
    for product in [APP_NAME, APP_NAME + "Widget"]:
        run(*build, "--product", product, cwd=source, env=env)
    bin_path = Path(run(*build, "--show-bin-path", cwd=source, env=env, capture=True).decode().strip().splitlines()[-1])
    app = output / (APP_NAME + ".app")
    if app.exists():
        shutil.rmtree(app)
    extension = app / "Contents/PlugIns/FiberHomeCPEManagerWidget.appex"
    for component, executable, plist, entitlements in [
        (extension, APP_NAME + "Widget", "FiberHomeCPEManagerWidgetInfo.plist", "FiberHomeCPEManagerWidget.entitlements"),
        (app, APP_NAME, "Info.plist", "FiberHomeCPEManager.entitlements"),
    ]:
        (component / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        (component / "Contents/Resources").mkdir(parents=True, exist_ok=True)
        binary = component / "Contents/MacOS" / executable
        shutil.copyfile(bin_path / executable, binary)
        binary.chmod(0o755)
        run("strip", "-S", "-x", binary)
        shutil.copyfile(source / "Packaging" / plist, component / "Contents/Info.plist")
        if component == app:
            shutil.copyfile(source / "Packaging/AppIcon.icns", component / "Contents/Resources/AppIcon.icns")
            for resource in bin_path.glob("*.bundle"):
                shutil.copytree(resource, component / "Contents/Resources" / resource.name)
            for name in ["LICENSE", "NOTICE"]:
                shutil.copyfile(source / name, component / "Contents/Resources" / name)
        run("xattr", "-cr", component)
        run("codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none",
            "--entitlements", source / "Packaging" / entitlements, component)
    return app


def supports_diskutil_images():
    try:
        result = subprocess.run(["diskutil", "image", "create", "from", "--help"],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except FileNotFoundError:
        return False
    return result.returncode == 0 and b"--volumeName" in result.stdout


def package_image(work, app, destination, plan, architectures):
    stage = work / "disk-image"
    stage.mkdir()
    shutil.copytree(app, stage / app.name)
    (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
    image = work / "validated-release.dmg"
    modern = supports_diskutil_images()
    if modern:
        run("diskutil", "image", "create", "from", "--format", "UDZO",
            "--volumeName", "FiberHome CPE Manager", stage, image)
    else:
        run("hdiutil", "create", "-volname", "FiberHome CPE Manager", "-srcfolder", stage,
            "-format", "UDZO", "-imagekey", "zlib-level=9", "-ov", image)
    run("hdiutil", "verify", image)
    mount = work / "mounted"
    mount.mkdir()
    if modern:
        run("diskutil", "image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mount, image, capture=True)
    else:
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, image, capture=True)
    try:
        # The mounted payload, rather than just the staging directory, is the final audit target.
        if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
            raise RuntimeError("Missing Applications shortcut")
        allowed = {app.name, "Applications", ".fseventsd", ".Trashes", ".HFS+ Private Directory Data\r"}
        if {p.name for p in mount.iterdir()} - allowed:
            raise RuntimeError("Unexpected file at DMG root")
        checked = audit_app(mount / app.name, plan, architectures)
    finally:
        run("diskutil", "eject", mount)
    pending = destination.with_name("." + destination.name + ".partial")
    shutil.copyfile(image, pending)
    pending.replace(destination)
    return checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-plan", type=Path, help="External local-only denylist")
    parser.add_argument("--output", type=Path, default=ROOT / "build/release")
    parser.add_argument("--configure-only", action="store_true", help="Set up local Git excludes without building")
    args = parser.parse_args()
    configure_local_excludes()
    if args.configure_only:
        print("Local Git exclusions configured; .gitignore remains untracked.")
        return
    architectures = ["arm64"]
    plan = json.loads(args.private_plan.read_text()) if args.private_plan else None
    preflight = [sys.executable, ROOT / "script/check_privacy.py", "--history"]
    if args.private_plan:
        preflight.extend(["--private-plan", args.private_plan.resolve()])
    run(*preflight)
    names = public_paths()
    check_files(ROOT, names, plan)
    if not {"LICENSE", "NOTICE"}.issubset(names):
        raise RuntimeError("LICENSE and NOTICE must be present in release sources")
    version = plistlib.loads((ROOT / "Packaging/Info.plist").read_bytes())["CFBundleShortVersionString"]
    if any(c not in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.-" for c in version):
        raise RuntimeError("Unsafe version string")
    output = args.output.resolve()
    # Release artifacts must stay in the locally excluded build directory.
    if not output.is_relative_to(ROOT / "build"):
        raise RuntimeError("Output must be inside the repository's local build directory")
    output.mkdir(parents=True, exist_ok=True)
    stem = APP_NAME + "-" + version
    image = output / (stem + ".dmg")
    with tempfile.TemporaryDirectory(prefix="fhcpem-release-", dir="/private/tmp") as temporary:
        work = Path(temporary)
        app = build_app(work, output, names, architectures)
        audit_app(app, plan, architectures)
        package_image(work, app, image, plan, architectures)
    checksum = hashlib.sha256(image.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(checksum + "  " + image.name + "\n")
    print("Created:", image.name, flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print("Release failed:", error, file=sys.stderr)
        raise SystemExit(1)
