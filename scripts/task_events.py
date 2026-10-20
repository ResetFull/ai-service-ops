"""Authenticated local executor events; remote stdout is never a producer."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets

PHASES = {
    "build": {"build"},
    "upload": {"preflight", "acquire", "transfer", "install", "release"},
    "restart": {"preflight", "acquire", "restart", "release"},
    "rollback": {"preflight", "acquire", "rollback", "restart", "verify", "release"},
    "all": {"preflight", "acquire", "build", "transfer", "install", "restart", "verify", "release"},
    "verify": {"verify"}, "release-status": {"inspect"},
}
STATUSES = {"started", "completed", "failed", "unknown"}


def signature(event, secret):
    payload = json.dumps(event, sort_keys=True, separators=(",", ":")).encode()
    return hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()


def emit(phase, status, release_id="", artifact_sha256=""):
    path = os.environ.get("SERVICE_OPS_EVENT_FILE")
    secret = os.environ.get("SERVICE_OPS_EVENT_SECRET")
    job_id = os.environ.get("SERVICE_OPS_EVENT_JOB")
    if not path or not secret or not job_id:
        raise ValueError("EVENT_CHANNEL_REQUIRED")
    event = {"job_id": job_id, "phase": phase, "status": status,
             "release_id": release_id, "artifact_sha256": artifact_sha256}
    envelope = {"event": event, "signature": signature(event, secret)}
    encoded = json.dumps(envelope, separators=(",", ":")) + "\n"
    if len(encoded) > 8192:
        raise ValueError("EVENT_TOO_LARGE")
    with Path(path).open("a", encoding="utf-8", newline="\n") as output:
        output.write(encoded)
        output.flush()
        os.fsync(output.fileno())


class EventChannel:
    def __init__(self, directory, job_id, action):
        self.path = Path(directory) / "executor-events.jsonl"
        self.secret, self.job_id, self.action = secrets.token_hex(32), job_id, action
        self.offset, self.pending = 0, b""
        with self.path.open("x", encoding="utf-8"):
            os.chmod(self.path, 0o600)

    def environment(self):
        return {"SERVICE_OPS_EVENT_FILE": str(self.path), "SERVICE_OPS_EVENT_SECRET": self.secret,
                "SERVICE_OPS_EVENT_JOB": self.job_id}

    def verify(self, envelope):
        if not isinstance(envelope, dict) or not isinstance(envelope.get("event"), dict):
            return None
        event = envelope["event"]
        if not isinstance(envelope.get("signature"), str) or not hmac.compare_digest(
                signature(event, self.secret), envelope["signature"]):
            return None
        if event.get("job_id") != self.job_id or event.get("phase") not in PHASES.get(self.action, set()):
            return None
        if event.get("status") not in STATUSES:
            return None
        return event

    def read(self):
        if self.path.stat().st_size > 1048576:
            raise ValueError("EVENT_CHANNEL_BUDGET_EXCEEDED")
        with self.path.open("rb") as source:
            source.seek(self.offset)
            chunk = source.read(1048576)
        self.offset += len(chunk)
        pieces = (self.pending + chunk).split(b"\n")
        self.pending = pieces.pop()
        for line in pieces:
            if len(line) > 8192:
                continue
            try:
                event = self.verify(json.loads(line))
            except (ValueError, TypeError, UnicodeError):
                continue
            if event is not None:
                yield event


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("phase")
    parser.add_argument("status", choices=sorted(STATUSES))
    parser.add_argument("release_id", nargs="?", default="")
    parser.add_argument("artifact_sha256", nargs="?", default="")
    arguments = parser.parse_args()
    emit(arguments.phase, arguments.status, arguments.release_id, arguments.artifact_sha256)
