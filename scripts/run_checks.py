"""Run self-contained regression suites; no SSH credentials or inventory required."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
LINUX_REMOTE_SUITES = {"bash-behavior-regression.sh"}


def engines():
    bash = shutil.which("bash")
    if os.name == "nt":
        candidate = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
        bash = str(candidate) if candidate.exists() else None
    return {".py": [sys.executable], ".sh": [bash] if bash else None,
            ".ps1": [shutil.which("pwsh"), "-NoLogo", "-NoProfile", "-File"] if shutil.which("pwsh") else None}


def manifest_check():
    portable = json.loads((ROOT / "plugin.json").read_text(encoding="utf-8"))
    codex = json.loads((ROOT / ".codex-plugin/plugin.json").read_text(encoding="utf-8"))
    marketplace = json.loads((ROOT / ".agents/plugins/marketplace.json").read_text(encoding="utf-8"))
    for field in ("name", "version", "license", "author"):
        if portable[field] != codex[field]:
            raise ValueError("PLUGIN_MANIFEST_MISMATCH")
    if marketplace["plugins"][0]["name"] != portable["name"]:
        raise ValueError("MARKETPLACE_NAME_MISMATCH")
    if portable["extensions"]["com.openai"]["interface"] != codex["interface"]:
        raise ValueError("PLUGIN_INTERFACE_MISMATCH")
    for name in ("diagnose-services", "operate-test-services"):
        if not (ROOT / "skills" / name / "SKILL.md").is_file():
            raise ValueError("MISSING_SKILL")


def run_suite(name, command, environment):
    started = time.monotonic()
    try:
        result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=300)
        status, output = ("PASS" if result.returncode == 0 else "FAIL"), result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        status, output = "FAIL", "SUITE_TIMEOUT"
    print(f"{status}: {name}", flush=True)
    if status == "FAIL":
        print("\n".join(output.splitlines()[-20:]), flush=True)
    return {"suite": name, "status": status, "seconds": round(time.monotonic() - started, 2)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-native", action="store_true")
    arguments = parser.parse_args()
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONIOENCODING="utf-8")
    for key in tuple(environment):
        if key.startswith("SERVICE_OPS_"):
            environment.pop(key)
    results = []
    try:
        manifest_check()
        results.append({"suite": "manifests", "status": "PASS"})
    except (ValueError, KeyError, OSError):
        results.append({"suite": "manifests", "status": "FAIL"})
    runtimes = engines()
    for path in sorted((ROOT / "tests").glob("*-regression.*")):
        if os.name == "nt" and path.name in LINUX_REMOTE_SUITES:
            print(f"NOT_APPLICABLE: {path.name} (GNU/Linux remote filesystem; covered by Linux CI)", flush=True)
            results.append({"suite": path.name, "status": "NOT_APPLICABLE", "reason": "GNU_LINUX_REMOTE_REQUIRED"})
            continue
        prefix = runtimes.get(path.suffix)
        if not prefix:
            status = "FAIL" if arguments.require_native else "SKIP"
            print(f"{status}: {path.name} (engine unavailable)", flush=True)
            results.append({"suite": path.name, "status": status})
        else:
            results.append(run_suite(path.name, prefix + [str(path)], environment))
    with tempfile.TemporaryDirectory(prefix="ai-ops-demo-check-") as temporary:
        results.append(run_suite("offline-demo", [sys.executable, "scripts/demo.py", "--state-dir", temporary], environment))
    results.append(run_suite("privacy", [sys.executable, "scripts/privacy_check.py"], environment))
    destination = ROOT / "reports"
    destination.mkdir(exist_ok=True)
    (destination / "checks.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    failed = sum(item["status"] == "FAIL" for item in results)
    skipped = sum(item["status"] == "SKIP" for item in results)
    inapplicable = sum(item["status"] == "NOT_APPLICABLE" for item in results)
    print(f"Checks: {len(results) - failed - skipped - inapplicable} passed, {failed} failed, {skipped} skipped, {inapplicable} not applicable")
    return int(bool(failed))


if __name__ == "__main__":
    raise SystemExit(main())
