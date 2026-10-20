"""Persistent task receipts around the existing, policy-enforcing executors."""
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
from ops_config import check_policy, config_directory
from task_events import EventChannel

ROOT = Path(__file__).resolve().parents[1]
WRITES = {"build", "upload", "restart", "rollback", "all"}
READS = {"status", "health", "logs", "grep", "grepall", "backupgrep", "logsrange",
         "count", "logfiles", "ps", "disk", "mem", "top", "services", "net", "jvm",
         "nginx-config", "image-layout", "plan", "verify", "release-status"}
OUTPUT_LIMIT = 262144
JOB_ID = re.compile(r"job-[a-f0-9]{24}")
RELEASE_ID = re.compile(r"\d{14}-[a-f0-9]{8}")
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def now():
    return datetime.now(timezone.utc).isoformat()


def protect(text):
    text = ANSI.sub("", str(text))
    text = re.sub(r'(?i)(authorization["\x27]?\s*[=:]\s*["\x27]?\s*Bearer\s+)[^\s,"\x27;]+', r"\1[REDACTED]", text)
    text = re.sub(r'''(?i)(["'](?:password|passwd|token|secret|api[_-]?key|authorization|cardNo|bankCard|accountNo)["']\s*:\s*["'])[^"']*''', r"\1[REDACTED]", text)
    text = re.sub(r"(?i)((?:password|passwd|token|secret|api[_-]?key|authorization|cardNo|bankCard|accountNo)\s*[=:]\s*)[^\s,;]+", r"\1[REDACTED]", text)
    text = re.sub(r"(?<!\d)1[3-9]\d{9}(?!\d)", "[PHONE]", text)
    text = re.sub(r"(?<!\d)\d{17}[\dXx](?!\d)", "[IDENTITY]", text)
    return re.sub(r"(https?://[^\s?]+)\?[^\s]+", r"\1?[REDACTED]", text)


def digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def normalize_scope(scope):
    if not re.fullmatch(r"(?:(domestic|overseas)-)?(dev|test|prod)", scope):
        raise ValueError("INVALID_SCOPE")
    return scope.removeprefix("domestic-")


def config_fingerprint(root, scope):
    directory = config_directory(root)
    names = {f"servers-{scope}.conf", f"services-{scope}.conf", "settings.json"}
    names.update(path.name for path in directory.glob("servers-*prod.conf"))
    entries = []
    for name in sorted(names):
        path = directory / name
        if path.exists() and path.stat().st_size > 1048576:
            raise ValueError("CONFIG_TOO_LARGE")
        value = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else "-"
        entries.append(f"{name}\t{value}\n")
    return digest("".join(entries))


def config_rows(root, kind, scope):
    path = config_directory(root) / f"{kind}-{scope}.conf"
    if not path.is_file():
        raise ValueError("CONFIG_MISSING")
    return [line.split("|") for line in path.read_text(encoding="utf-8-sig").splitlines()
            if line.strip() and not line.lstrip().startswith("#")]


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temporary.open("x", encoding="utf-8", newline="\n") as handle:
            os.chmod(temporary, 0o600)
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def state_root():
    configured = os.environ.get("SERVICE_OPS_STATE_DIR")
    if configured:
        return Path(configured).expanduser().resolve()
    if os.name == "nt":
        return Path(os.environ["LOCALAPPDATA"]) / "ai-service-ops"
    return Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "ai-service-ops"


def executor_command(engine):
    if engine == "powershell":
        executable = shutil.which("pwsh")
        command = [executable, "-NoProfile", "-File", str(ROOT / "scripts/service-ops.ps1")]
    else:
        executable = os.environ.get("SERVICE_OPS_BASH") or shutil.which("bash")
        if os.name == "nt" and executable and "WindowsApps" in executable:
            git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
            executable = str(git_bash) if git_bash.is_file() else None
        command = [executable, str(ROOT / "scripts/service-ops.sh")]
    if not executable:
        raise ValueError("EXECUTOR_NOT_FOUND")
    return command


def stop_process(process):
    if process.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    else:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)


def read_output(stream, messages):
    try:
        while True:
            line = stream.readline(65536)
            if not line:
                break
            if not line.endswith("\n") and len(line) == 65536:
                while line and not line.endswith("\n"):
                    line = stream.readline(65536)
                messages.put("RESULT PARTIAL reason=OUTPUT_LINE_TOO_LONG\n")
            else:
                messages.put(line)
    finally:
        messages.put(None)


def process_identity(pid):
    if not isinstance(pid, int) or pid <= 0:
        return None
    if os.name == "nt":
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(ctypes.c_ulonglong)] * 4
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return None
        try:
            values = [ctypes.c_ulonglong() for _ in range(4)]
            code = wintypes.DWORD()
            if not kernel.GetExitCodeProcess(handle, ctypes.byref(code)) or code.value != 259:
                return None
            if kernel.GetProcessTimes(handle, *[ctypes.byref(value) for value in values]):
                return str(values[0].value)
        finally:
            kernel.CloseHandle(handle)
        return None
    try:
        text = Path(f"/proc/{pid}/stat").read_text()
        return text[text.rfind(")") + 2:].split()[19]
    except (OSError, IndexError):
        if sys.platform == "darwin":
            result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="],
                                    capture_output=True, text=True, check=False)
            return result.stdout.strip() or None
        return None


class TaskRunner:
    def __init__(self, root, state, command, timeout=1800):
        self.root, self.state, self.command = Path(root), Path(state).resolve(), command
        self.timeout = max(1, min(timeout, 3600))
        if self.state == self.root.resolve() or self.root.resolve() in self.state.parents:
            raise ValueError("STATE_MUST_BE_OUTSIDE_PLUGIN")

    def directory(self, job_id):
        if not JOB_ID.fullmatch(job_id):
            raise ValueError("INVALID_JOB_ID")
        path = self.state / "tasks" / job_id
        if path.is_symlink():
            raise ValueError("UNSAFE_STATE_PATH")
        return path

    def status(self, job_id):
        path = self.directory(job_id) / "job.json"
        if not path.is_file():
            raise ValueError("JOB_NOT_FOUND")
        record = json.loads(path.read_text(encoding="utf-8"))
        if record["status"] == "RUNNING" and (not record.get("owner_identity") or
                record["owner_identity"] != process_identity(record.get("owner_pid", -1))):
            record["stored_status"] = "RUNNING"
            record["status"] = "UNKNOWN"
            record["next_action"] = "inspect_before_retry"
        return record

    def evidence(self, job_id):
        record = self.status(job_id)
        path = self.directory(job_id) / "output.txt"
        return {"job_id": job_id, "evidence_id": record["evidence_id"],
                "scope": record["scope"], "status": record["status"],
                "output_truncated": record.get("output_truncated", False),
                "output": path.read_text(encoding="utf-8") if path.exists() else ""}

    def list_jobs(self, limit=20):
        directory = self.state / "tasks"
        if not directory.is_dir():
            return {"jobs": [], "partial": False}
        names, partial = [], False
        with os.scandir(directory) as entries:
            for entry in entries:
                if JOB_ID.fullmatch(entry.name) and entry.is_dir(follow_symlinks=False) and (Path(entry.path) / "job.json").is_file():
                    names.append(entry.name)
                if len(names) >= 1000:
                    partial = True
                    break
        records = [self.status(name) for name in names]
        records.sort(key=lambda record: record["created_at"], reverse=True)
        return {"jobs": [{key: record[key] for key in ("job_id", "scope", "target", "action", "status", "created_at")}
                         for record in records[:max(1, min(limit, 100))]], "partial": partial}

    def validate(self, scope, target, action, params):
        scope = normalize_scope(scope)
        if scope.endswith("prod") and action not in READS - {"plan", "verify", "release-status"} and target not in {"groups", "list", "servers", "doctor", "trace", "nginx-stats"}:
            raise ValueError("PROD_READ_ONLY")
        if action in WRITES and scope not in {"test", "overseas-test"}:
            raise ValueError("PROD_READ_ONLY")
        if action in WRITES:
            check_policy(config_directory(self.root), scope, action)
        if len(params) > 12 or any(len(str(value)) > 4096 for value in params):
            raise ValueError("INVALID_ARGUMENT_BUDGET")
        if target in {"groups", "list", "servers"}:
            return scope
        if target == "doctor" and action == "query":
            return scope
        if target == "trace" and re.fullmatch(r"[A-Za-z0-9._:-]{1,200}", action):
            return scope
        servers = config_rows(self.root, "servers", scope)
        services = config_rows(self.root, "services", scope)
        if target == "nginx-stats" and any(row[0] == action for row in servers):
            return scope
        matches = [row for row in servers + services if row[0] == target]
        if len(matches) != 1:
            raise ValueError("UNKNOWN_OR_AMBIGUOUS_TARGET")
        if action not in READS | WRITES:
            raise ValueError("UNSUPPORTED_ACTION")
        if action in WRITES and not any(row[0] == target for row in services):
            raise ValueError("SERVICE_REQUIRED")
        if action in WRITES and params and not (action == "rollback" and len(params) == 1 and RELEASE_ID.fullmatch(params[0])):
            raise ValueError("INVALID_WRITE_ARGUMENTS")
        return scope

    def run(self, scope, target, action, params, request_id=None):
        scope = self.validate(scope, target, action, params)
        request_id = request_id or uuid.uuid4().hex
        if not re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", request_id):
            raise ValueError("INVALID_REQUEST_ID")
        request_hash = digest(json.dumps([scope, target, action, params], ensure_ascii=False))
        job_id = "job-" + digest(request_id)[:24]
        directory = self.directory(job_id)
        if (directory / "job.json").exists():
            record = self.status(job_id)
            if record["request_hash"] != request_hash:
                raise ValueError("REQUEST_ID_CONFLICT")
            return record
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock = directory / "run.lock"
        try:
            descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError as error:
            raise ValueError("TASK_BUSY_INSPECT_BEFORE_RETRY") from error
        os.close(descriptor)
        try:
            # Another process may have completed between the first lookup and lock acquisition.
            if (directory / "job.json").exists():
                record = self.status(job_id)
                if record["request_hash"] != request_hash:
                    raise ValueError("REQUEST_ID_CONFLICT")
                return record
            record = {"schema_version": 1, "job_id": job_id, "task_id": request_id,
                      "request_id": request_id, "request_hash": request_hash, "scope": scope,
                      "target": target, "action": action, "params": [protect(value) for value in params],
                      "authorization_basis": "caller_task_scope_not_a_security_credential",
                      "config_fingerprint": config_fingerprint(self.root, scope),
                      "created_at": now(), "status": "RUNNING", "steps": [],
                      "owner_pid": os.getpid(), "owner_identity": process_identity(os.getpid()),
                      "evidence_id": job_id + ":output", "output_truncated": False}
            atomic_json(directory / "job.json", record)
            self.execute(record, params)
            return record
        finally:
            lock.unlink(missing_ok=True)

    def event(self, record, event):
        if not isinstance(event, dict) or not isinstance(event.get("status"), str):
            return
        if not re.fullmatch(r"[a-z-]{1,32}", str(event.get("phase", ""))) or event["status"] not in {"started", "completed", "failed", "unknown"}:
            return
        previous = next((item["status"] for item in reversed(record["steps"]) if item["phase"] == event["phase"]), None)
        if event["status"] != "started" and previous != "started":
            return
        event = {key: protect(event[key]) for key in ("phase", "status", "release_id", "artifact_sha256") if key in event}
        event["observed_at"] = now()
        if len(record["steps"]) >= 200:
            return
        record["steps"].append(event)
        if event["status"] == "unknown":
            record["remote_uncertainty"] = True
        release = event.get("release_id", "")
        if RELEASE_ID.fullmatch(release):
            record["release_id"] = release
        directory = self.directory(record["job_id"])
        with (directory / "events.jsonl").open("a", encoding="utf-8", newline="\n") as handle:
            os.chmod(handle.name, 0o600)
            handle.write(json.dumps(event, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        atomic_json(directory / "job.json", record)

    def execute(self, record, params):
        directory = self.directory(record["job_id"])
        channel = EventChannel(directory, record["job_id"], record["action"])
        environment = dict(os.environ, SERVICE_OPS_TASK_EVENTS="1",
                           SERVICE_OPS_PYTHON=sys.executable, SERVICE_OPS_TASK_SCOPE=record["scope"],
                           SERVICE_OPS_CONFIG_FINGERPRINT=record["config_fingerprint"])
        environment.update(channel.environment())
        command = self.command + [record["scope"], record["target"], record["action"]] + list(params)
        statuses, interrupted = set(), False
        process = None
        options = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {"start_new_session": True}
        deadline = time.monotonic() + self.timeout
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, encoding="utf-8", errors="replace", env=environment, **options)
            record["child_pid"] = process.pid
            atomic_json(directory / "job.json", record)
            interrupted = self.capture(record, process, statuses, deadline, channel)
            try:
                code = process.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                interrupted = True
                stop_process(process)
                code = process.wait(timeout=5)
            for event in channel.read():
                self.event(record, event)
        except KeyboardInterrupt:
            interrupted = True
            if process is not None:
                stop_process(process)
            code = 130
        except (OSError, ValueError) as error:
            record["error"] = protect(str(error))
            if process is not None:
                interrupted = True
                stop_process(process)
            code = 1
        finally:
            if process is not None and process.stdout is not None:
                process.stdout.close()
        self.finish(record, code, statuses, interrupted)

    def capture(self, record, process, statuses, deadline, channel):
        messages = queue.Queue(maxsize=128)
        threading.Thread(target=read_output, args=(process.stdout, messages), daemon=True).start()
        saved_bytes, interrupted = 0, False
        with (self.directory(record["job_id"]) / "output.txt").open("w", encoding="utf-8", newline="\n") as output:
            os.chmod(output.name, 0o600)
            while True:
                for event in channel.read():
                    self.event(record, event)
                if not interrupted and time.monotonic() >= deadline:
                    interrupted = True
                    stop_process(process)
                try:
                    line = messages.get(timeout=0.2)
                except queue.Empty:
                    continue
                if line is None:
                    break
                line = protect(line)
                statuses.update(re.findall(r"^RESULT (UNKNOWN|PARTIAL|NO_LOG|NO_MATCH|SSH_FAILED|QUERY_FAILED|OK)\b", line))
                encoded = line.encode("utf-8")
                if saved_bytes + len(encoded) <= OUTPUT_LIMIT:
                    output.write(line)
                    output.flush()
                    saved_bytes += len(encoded)
                else:
                    record["output_truncated"] = True
        return interrupted

    def finish(self, record, code, statuses, interrupted):
        record["exit_code"], record["finished_at"] = code, now()
        record["query_statuses"] = sorted(set(statuses))
        if record.get("remote_uncertainty") or "UNKNOWN" in statuses or interrupted and record["action"] in WRITES:
            record["status"] = "UNKNOWN"
        elif statuses & {"SSH_FAILED", "QUERY_FAILED"} or any(event["status"] == "failed" for event in record["steps"]):
            record["status"] = "FAILED"
        elif "PARTIAL" in statuses or "NO_LOG" in statuses or interrupted or record["output_truncated"] and record["action"] not in WRITES:
            record["status"] = "PARTIAL"
        else:
            record["status"] = "SUCCEEDED" if code == 0 else "FAILED"
        record["next_action"] = "inspect_before_retry" if record["status"] == "UNKNOWN" else "review_evidence"
        atomic_json(self.directory(record["job_id"]) / "job.json", record)

    def reconcile(self, job_id):
        record = self.status(job_id)
        if record["status"] == "RUNNING":
            raise ValueError("TASK_RUNNING")
        if config_fingerprint(self.root, record["scope"]) != record["config_fingerprint"]:
            raise ValueError("CONFIG_CHANGED")
        if record["action"] not in WRITES or record["action"] == "build":
            return {"job_id": job_id, "status": record["status"], "observation": "No remote write reconciliation required"}
        observation = self.run(record["scope"], record["target"], "release-status", [])
        observations = [observation["job_id"]]
        if record.get("release_id"):
            verification = self.run(record["scope"], record["target"], "verify", [record["release_id"]])
            observations.append(verification["job_id"])
        result = {"observed_at": now(), "observation_jobs": observations,
                  "note": "Read-only evidence only; no automatic unlock, retry, resume or rollback"}
        record["reconciliation"] = result
        atomic_json(self.directory(job_id) / "job.json", record)
        return {"job_id": job_id, "status": record["status"], "reconciliation": result}

    def diagnose(self, scope, service, scenario, server=None, start=None, end=None, nginx_server=None):
        scope = normalize_scope(scope)
        fingerprint = config_fingerprint(self.root, scope)
        rows = [row for row in config_rows(self.root, "services", scope) if row[0] == service]
        if len(rows) != 1:
            raise ValueError("UNKNOWN_OR_AMBIGUOUS_TARGET")
        nodes = rows[0][1].split(",")
        if not server and len(nodes) != 1:
            raise ValueError("EXPLICIT_DIAGNOSTIC_NODE_REQUIRED")
        server = server or nodes[0]
        if server not in nodes or bool(start) != bool(end):
            raise ValueError("INVALID_DIAGNOSTIC_SCOPE")
        queries = [(service, "status", [server]), (server, "net", []), (server, "jvm", [service])]
        queries.append((service, "logsrange", [start, end, "", server]) if start else (service, "health", [server]))
        if scenario == "http502" and nginx_server:
            queries += [(nginx_server, "nginx-config", []), ("nginx-stats", nginx_server, [])]
        deadline, results = time.monotonic() + min(self.timeout, 180), []
        for target, action, params in queries[:6]:
            if config_fingerprint(self.root, scope) != fingerprint:
                raise ValueError("CONFIG_CHANGED")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            runner = TaskRunner(self.root, self.state, self.command, min(remaining, 60))
            results.append(runner.run(scope, target, action, params))
            if "SSH_FAILED" in results[-1].get("query_statuses", []):
                break
        report = {"schema_version": 1, "scope": scope, "service": service, "server": server,
                  "scenario": scenario, "time_window": {"start": start, "end": end},
                  "status": "COMPLETE" if len(results) == len(queries) and all(item["status"] == "SUCCEEDED" for item in results) else "PARTIAL",
                  "root_cause": "UNDETERMINED", "evidence_jobs": [item["job_id"] for item in results],
                  "missing_evidence": [] if start else ["No explicit incident time window; samples do not establish historical coverage"],
                  "next_step": "Use the scenario runbook to separate observed facts, hypotheses and missing evidence"}
        if scenario == "http502" and not nginx_server:
            report["missing_evidence"].append("Nginx node not specified; upstream proxy evidence was not collected")
        for item in results:
            if item["status"] != "SUCCEEDED":
                report["missing_evidence"].append(f'{item["action"]}: {item["status"]} ({item["job_id"]}); inspect bounded query evidence')
        if len(results) < len(queries):
            report["missing_evidence"].append(f'{len(queries) - len(results)} queries not collected after deadline or SSH failure')
        if report["missing_evidence"]:
            report["status"] = "PARTIAL"
        report_id = "job-" + uuid.uuid4().hex[:24]
        report["job_id"] = report_id
        atomic_json(self.directory(report_id) / "diagnosis.json", report)
        summary = {"schema_version": 1, "job_id": report_id, "scope": scope, "target": service,
                   "action": "diagnose", "created_at": now(), "evidence_id": report_id + ":output",
                   "status": "SUCCEEDED" if report["status"] == "COMPLETE" else "PARTIAL",
                   "config_fingerprint": fingerprint, "diagnosis": report}
        atomic_json(self.directory(report_id) / "job.json", summary)
        (self.directory(report_id) / "output.txt").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        return report


def parser():
    result = argparse.ArgumentParser(description="Service Ops task receipts and bounded diagnostic evidence")
    result.add_argument("--engine", choices=["powershell", "bash"], default="powershell" if os.name == "nt" else "bash")
    result.add_argument("--timeout", type=int, default=1800)
    result.add_argument("--request-id")
    commands = result.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run")
    run.add_argument("scope")
    run.add_argument("target")
    run.add_argument("action", nargs="?", default="status")
    run.add_argument("params", nargs=argparse.REMAINDER)
    for name in ("status", "evidence", "reconcile"):
        commands.add_parser(name).add_argument("job_id")
    commands.add_parser("list").add_argument("--limit", type=int, default=20)
    diagnose = commands.add_parser("diagnose")
    diagnose.add_argument("scope")
    diagnose.add_argument("service")
    diagnose.add_argument("scenario", choices=["startup", "http502"])
    for option in ("server", "start", "end", "nginx-server"):
        diagnose.add_argument("--" + option)
    check = commands.add_parser("check-config")
    check.add_argument("scope")
    check.add_argument("fingerprint")
    return result


def main():
    options = parser().parse_args()
    try:
        if options.request_id and options.command != "run":
            raise ValueError("REQUEST_ID_ONLY_FOR_RUN")
        if options.command == "check-config":
            if config_fingerprint(ROOT, normalize_scope(options.scope)) != options.fingerprint:
                raise ValueError("CONFIG_CHANGED")
            return 0
        runner = TaskRunner(ROOT, state_root(), executor_command(options.engine), options.timeout)
        if options.command == "run":
            value = runner.run(options.scope, options.target, options.action, options.params, options.request_id)
        elif options.command == "list":
            value = runner.list_jobs(options.limit)
        elif options.command == "diagnose":
            value = runner.diagnose(options.scope, options.service, options.scenario, options.server,
                                    options.start, options.end, options.nginx_server)
        else:
            value = getattr(runner, options.command)(options.job_id)
        print(json.dumps(value, ensure_ascii=False))
        return 0 if value.get("status") in (None, "SUCCEEDED", "RUNNING", "COMPLETE") else 2
    except (ValueError, OSError) as error:
        print(json.dumps({"error": protect(str(error)), "status": "FAILED"}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
