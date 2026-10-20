#!/usr/bin/env python3
"""Check publishable files without printing private values.

An optional external plan adds exact, locally held denylist patterns. No plan or
captured device data belongs in this repository. --history scans every Git object,
including unreachable objects and snapshots outside ordinary branch history.
"""
import argparse
import json
from pathlib import Path
import re
import struct
import subprocess
import zlib


HOME_PREFIX = "/" + "Users/"
PERSONAL_HOME = re.compile(re.escape(HOME_PREFIX) + r"(?!example/|developer/|USERNAME/|<)[A-Za-z0-9_.-]+/")
CREDENTIAL = re.compile(r"\bCPE_PASS\s*=\s*(['\"])([^'\"\n]*)\1")
PLACEHOLDERS = {"", "…", "...", "example-password", "your-password", "change-me"}


def text_findings(data, plan=None):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return []
    if "\0" in text:
        return []
    result = []
    if PERSONAL_HOME.search(text):
        result.append("personal-home-path")
    if any(m[2] not in PLACEHOLDERS and "$" not in m[2] for m in CREDENTIAL.finditer(text)):
        result.append("literal-test-credential")
    if plan:
        for item in plan.get("confirmed_exact_replacements", []):
            if re.search(item["match_regex"], text):
                result.append("private-value:" + item["category"])
        for item in plan.get("identity_field_replacements", []):
            if item["original"] in text:
                result.append("private-git-identity")
    return sorted(set(result))


def embedded_text(data):
    """Read PNG text metadata, including compressed text inside an ICNS container."""
    if data.startswith(b"icns") and len(data) >= 8:
        at = 8
        while at + 8 <= len(data):
            size = int.from_bytes(data[at + 4:at + 8], "big")
            if size < 8 or at + size > len(data):
                break
            yield from embedded_text(data[at + 8:at + size])
            at += size
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return
    at = 8
    while at + 12 <= len(data):
        size = struct.unpack_from(">I", data, at)[0]
        kind = data[at + 4:at + 8]
        body = data[at + 8:at + 8 + size]
        if at + 12 + size > len(data):
            break
        try:
            if kind == b"tEXt":
                yield body.replace(b"\0", b"\n")
            elif kind == b"zTXt":
                _, compressed = body.split(b"\0", 1)
                yield zlib.decompress(compressed[1:])
            elif kind == b"iTXt":
                _, rest = body.split(b"\0", 1)
                flag, method = rest[:2]
                _, _, text = rest[2:].split(b"\0", 2)
                yield zlib.decompress(text) if flag == 1 and method == 0 else text
        except (ValueError, zlib.error):
            # A malformed metadata chunk cannot be declared clean.
            yield b"privacy-invalid-image-metadata"
        at += 12 + size


def payload_findings(data, plan=None):
    """Scan binary string tables too; NUL bytes must not bypass artifact checks."""
    result = []
    for payload in [data, *embedded_text(data)]:
        if payload == b"privacy-invalid-image-metadata":
            result.append("invalid-image-text-metadata")
            continue
        normalized = payload.decode("utf-8", errors="ignore").replace("\0", "\n").encode()
        result.extend(text_findings(normalized, plan))
    return sorted(set(result))


def path_findings(path):
    p = Path(path)
    name = p.name.lower()
    if name == ".gitignore":
        return ["gitignore-must-remain-local"]
    if name.startswith(".env") and name != ".env.example":
        return ["private-environment-file"]
    if p.suffix.lower() in {".har", ".pcap", ".pcapng", ".docx", ".patch", ".diff", ".dmg", ".zip", ".tgz"}:
        return ["raw-capture-or-private-document"]
    if p.suffix.lower() in {".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".mobileprovision"}:
        return ["private-key-or-signing-material"]
    if name.startswith("reference-") and p.suffix.lower() in {".png", ".jpg", ".jpeg"}:
        return ["raw-reference-image"]
    return []


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True,
                          capture_output=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true")
    parser.add_argument("--private-plan", type=Path, help="External private audit plan; never commit this file")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    plan = json.loads(args.private_plan.read_text()) if args.private_plan else None
    findings = []
    tracked = set(git(root, "ls-files", "-z").decode().split("\0")) - {""}
    working = set(git(root, "ls-files", "-co", "--exclude-standard", "-z").decode().split("\0")) - {""}
    for name in sorted(working):
        path = root / name
        if not path.is_file() or path.is_symlink():
            continue
        for kind in path_findings(name):
            # .gitignore may exist locally, but may never be in the index.
            if kind != "gitignore-must-remain-local" or name in tracked:
                findings.append((name, kind))
        for kind in payload_findings(path.read_bytes(), plan):
            findings.append((name, kind))
    ignored = set(git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "-z").decode().split("\0")) - {""}
    for name in sorted(ignored):
        if name == ".gitignore" or "__pycache__" in Path(name).parts or Path(name).parts[0] in {".build", "build", "render", ".swiftpm"}:
            continue
        path = root / name
        if path.is_file():
            findings.append((name, "ignored-file-outside-build-roots"))
    objects_checked = 0
    if args.history:
        inventory = git(root, "cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype)")
        for line in inventory.decode().splitlines():
            oid, kind = line.split()
            if kind in {"blob", "commit", "tag"}:
                objects_checked += 1
                for finding in payload_findings(git(root, "cat-file", kind, oid), plan):
                    findings.append(("object:" + oid, finding))
            elif kind == "tree":
                for entry in git(root, "ls-tree", "-z", oid).split(b"\0"):
                    if entry:
                        name = entry.split(b"\t", 1)[1].decode("utf-8", errors="replace")
                        for finding in path_findings(name):
                            findings.append(("tree:" + oid, finding))
    for path, kind in findings:
        print(f"FAIL {path}: {kind}")
    print(f"Privacy check: {len(working)} working paths, {objects_checked} text objects, {len(findings)} findings")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
