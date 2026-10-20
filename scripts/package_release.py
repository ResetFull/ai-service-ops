"""Build a deterministic, allowlisted plugin archive after publication checks."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

from privacy_check import report, scan_archive, scan_source, source_paths

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {"README.md", "README.zh-CN.md", "LICENSE", "NOTICE", "SECURITY.md",
              "CONTRIBUTING.md", "CHANGELOG.md", "plugin.json"}
DIRECTORIES = {"scripts", "skills", "examples", "docs", ".codex-plugin", ".agents"}


def git(root, *arguments):
    return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True,
                          text=True, check=True).stdout.strip()


def canonical_bytes(path):
    return path.read_text(encoding="utf-8").replace("\r\n", "\n").encode("utf-8")


def build(root, allow_dirty=False):
    if not allow_dirty and git(root, "status", "--porcelain"):
        raise ValueError("CLEAN_CHECKOUT_REQUIRED")
    findings = scan_source(root)
    if findings:
        report(findings)
        raise ValueError("SOURCE_PRIVACY_GATE_FAILED")
    portable = json.loads((root / "plugin.json").read_text(encoding="utf-8"))
    overlay = json.loads((root / ".codex-plugin/plugin.json").read_text(encoding="utf-8"))
    if any(portable[key] != overlay[key] for key in ("name", "version", "license")):
        raise ValueError("MANIFEST_MISMATCH")
    try:
        commit = git(root, "rev-parse", "--verify", "HEAD")
    except subprocess.CalledProcessError:
        if not allow_dirty:
            raise ValueError("COMMITTED_SOURCE_REQUIRED") from None
        commit = "uncommitted"
    payload = {}
    for name in source_paths(root):
        if name in ROOT_FILES or name.split("/")[0] in DIRECTORIES:
            payload[name] = canonical_bytes(root / name)
    metadata = {"name": portable["name"], "version": portable["version"], "source_commit": commit,
                "preview": allow_dirty, "files": {name: hashlib.sha256(data).hexdigest()
                                                for name, data in sorted(payload.items())}}
    payload["release.json"] = (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode()
    destination = root / "dist"
    destination.mkdir(exist_ok=True)
    archive_path = destination / f'{portable["name"]}-{portable["version"]}.zip'
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(payload.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (0o100755 if name.endswith(".sh") else 0o100644) << 16
            archive.writestr(entry, data)
    findings = scan_archive(archive_path)
    if findings:
        archive_path.unlink()
        report(findings)
        raise ValueError("ARCHIVE_PRIVACY_GATE_FAILED")
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    (destination / "SHA256SUMS").write_text(f"{digest}  {archive_path.name}\n", encoding="utf-8", newline="\n")
    return archive_path, digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--allow-dirty", action="store_true", help="Local preview only; never publish this archive")
    arguments = parser.parse_args()
    try:
        path, digest = build(ROOT, arguments.allow_dirty)
        print(f"{path.name}: {digest}")
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"Packaging failed: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
