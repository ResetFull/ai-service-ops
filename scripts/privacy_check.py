"""Conservative publication gate. Findings contain locations, never secret values."""
import argparse
import ipaddress
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import zipfile

PRIVATE_DIRECTORIES = {".ssh", "credentials", "__pycache__"}
PRIVATE_ROOTS = {"config", "state", "reports", ".venv"}
PRIVATE_NAMES = {"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "known_hosts",
                 "authorized_keys", "hosts.yml", "current.tsv", "ssh_config"}
PRIVATE_EXTENSIONS = {".pem", ".key", ".p12", ".pfx", ".ppk", ".pub"}
PATTERNS = {
    "PRIVATE_KEY": re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"),
    "SSH_PUBLIC_KEY": re.compile(r"\b(?:ssh-(?:rsa|ed25519)|ecdsa-sha2-[a-z0-9-]+)\s+[A-Za-z0-9+/]{30,}={0,3}"),
    "GITHUB_TOKEN": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    "PROVIDER_KEY": re.compile(r"\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{40,}|AKIA[A-Z0-9]{16})\b"),
    "PERSONAL_PATH": re.compile(r"(?:[A-Za-z]:[/\\]Users[/\\]|/home/|/Users/)[A-Za-z0-9_.-]+"),
}
IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
EXAMPLE_NETWORKS = tuple(ipaddress.ip_network(value) for value in
                         ("127.0.0.0/8", "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24"))


def source_paths(root):
    result = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached",
                             "--others", "--exclude-standard"], capture_output=True, check=True)
    return sorted(set(result.stdout.decode("utf-8").split("\0")) - {""})


def path_issues(name):
    path = PurePosixPath(name.replace("\\", "/"))
    parts = tuple(part.lower() for part in path.parts)
    if not parts or path.is_absolute() or ".." in parts or ":" in parts[0]:
        return ["UNSAFE_PATH"]
    if any(part in PRIVATE_DIRECTORIES for part in parts) or parts[0] in PRIVATE_ROOTS:
        return ["PRIVATE_DIRECTORY"]
    if path.name.lower() in PRIVATE_NAMES or path.suffix.lower() in PRIVATE_EXTENSIONS:
        return ["PRIVATE_FILE"]
    if path.name == ".env" or (path.name.startswith(".env.") and path.name != ".env.example"):
        return ["ENVIRONMENT_FILE"]
    return []


def inspect_bytes(name, data):
    findings = [{"path": name, "line": 0, "category": category} for category in path_issues(name)]
    if len(data) > 2097152:
        return findings + [{"path": name, "line": 0, "category": "FILE_BUDGET_EXCEEDED"}]
    try:
        content = data.decode("utf-8-sig")
    except UnicodeError:
        return findings + [{"path": name, "line": 0, "category": "UNREVIEWED_BINARY"}]
    for number, line in enumerate(content.splitlines(), 1):
        for category, pattern in PATTERNS.items():
            if pattern.search(line):
                findings.append({"path": name, "line": number, "category": category})
        for match in IPV4.finditer(line):
            try:
                address = ipaddress.ip_address(match.group())
            except ValueError:
                continue
            if str(address) != "0.0.0.0" and not any(address in network for network in EXAMPLE_NETWORKS):
                findings.append({"path": name, "line": number, "category": "NON_EXAMPLE_ADDRESS"})
                break
    return findings


def scan_source(root):
    findings = []
    for name in source_paths(root):
        path = root / name
        if path.is_symlink():
            findings.append({"path": name, "line": 0, "category": "SYMLINK"})
        elif not path.is_file():
            findings.append({"path": name, "line": 0, "category": "MISSING_FILE"})
        else:
            findings.extend(inspect_bytes(name, path.read_bytes()))
    return findings


def scan_archive(path):
    findings, seen = [], set()
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            if item.filename in seen or ((item.external_attr >> 16) & 0o170000) == 0o120000:
                findings.append({"path": item.filename, "line": 0, "category": "DUPLICATE_OR_SYMLINK"})
            seen.add(item.filename)
            if item.is_dir():
                findings.extend({"path": item.filename, "line": 0, "category": issue}
                                for issue in path_issues(item.filename))
            elif item.file_size > 2097152:
                findings.append({"path": item.filename, "line": 0, "category": "FILE_BUDGET_EXCEEDED"})
            else:
                findings.extend(inspect_bytes(item.filename, archive.read(item)))
    return findings


def report(findings):
    for item in findings:
        print("{path}:{line}: {category}".format(**item))
    print(f"Privacy gate: {'FAILED' if findings else 'PASS'} ({len(findings)} findings)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--archive", type=Path)
    arguments = parser.parse_args()
    try:
        findings = scan_archive(arguments.archive) if arguments.archive else scan_source(arguments.root)
        report(findings)
        return int(bool(findings))
    except (OSError, ValueError, subprocess.SubprocessError, zipfile.BadZipFile):
        print("Privacy gate: FAILED (inspection unavailable)")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
