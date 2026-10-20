"""Run synthetic diagnostic evidence without credentials or network access."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

from ops_config import initialize
from task_runtime import TaskRunner, state_root

ROOT = Path(__file__).resolve().parents[1]


def run_demo(state):
    previous = os.environ.get("SERVICE_OPS_CONFIG_DIR")
    try:
        with tempfile.TemporaryDirectory(prefix="ai-ops-demo-") as temporary:
            root = Path(temporary)
            config = root / "config"
            initialize(config)
            (config / "servers-test.conf").write_text("demo-node|example.invalid|ops|key||Offline fixture\n", encoding="utf-8")
            (config / "services-test.conf").write_text("demo-app|demo-node|/tmp/demo|*.log|Offline fixture\n", encoding="utf-8")
            os.environ["SERVICE_OPS_CONFIG_DIR"] = str(config)
            runner = TaskRunner(root, state, [sys.executable, str(ROOT / "scripts/demo_fixture.py")], 30)
            report = runner.diagnose("test", "demo-app", "startup")
            evidence = [runner.evidence(job) for job in report["evidence_jobs"]]
            return {"demo": True, "network_calls": 0, "remote_writes": 0,
                    "diagnosis": report, "evidence": evidence,
                    "note": "Synthetic samples exercise receipts and redaction; they do not validate a real server"}
    finally:
        if previous is None:
            os.environ.pop("SERVICE_OPS_CONFIG_DIR", None)
        else:
            os.environ["SERVICE_OPS_CONFIG_DIR"] = previous


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path)
    arguments = parser.parse_args()
    print(json.dumps(run_demo(arguments.state_dir or state_root()), ensure_ascii=False))
