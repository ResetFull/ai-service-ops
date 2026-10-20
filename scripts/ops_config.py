"""User-owned configuration and shared policy for both CLI entrypoints."""
import argparse
import json
import os
from pathlib import Path
import re
import sys

SCOPES = ("dev", "test", "prod", "overseas-dev", "overseas-test", "overseas-prod")
MUTATIONS = {"build", "upload", "restart", "rollback", "all", "exec"}
DEFAULTS = {
    "schema_version": 1,
    "write_enabled": False,
    "trace_services": [],
    "backup_log_dir": "",
    "nginx_log_dir": "/var/log/nginx",
    "storage_roots": [],
    "maven_profile": "test",
    "run_build_tests": True,
    "frontend_build_script": "build:test",
}


def config_directory(root):
    explicit = os.environ.get("SERVICE_OPS_CONFIG_DIR")
    if explicit:
        return Path(explicit).expanduser().resolve()
    legacy = Path(root) / "config"
    if legacy.is_dir():
        return legacy.resolve()
    if os.name == "nt":
        return Path(os.environ["LOCALAPPDATA"]) / "ai-service-ops/config"
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "ai-service-ops"


def safe_remote_path(value, allow_empty=False):
    return isinstance(value, str) and ((allow_empty and value == "") or
        bool(re.fullmatch(r"/[A-Za-z0-9_./{}-]+", value)) and
        ".." not in value.split("/") and value != "/")


def settings(directory):
    path = Path(directory) / "settings.json"
    value = dict(DEFAULTS)
    if path.exists():
        if path.stat().st_size > 65536:
            raise ValueError("SETTINGS_TOO_LARGE")
        supplied = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(supplied, dict) or supplied.keys() - DEFAULTS.keys():
            raise ValueError("UNKNOWN_SETTINGS_FIELDS")
        value.update(supplied)
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValueError("UNSUPPORTED_CONFIG_VERSION")
    if any(type(value[key]) is not bool for key in ("write_enabled", "run_build_tests")):
        raise ValueError("INVALID_BOOLEAN_SETTING")
    for key in ("trace_services", "storage_roots"):
        if not isinstance(value[key], list) or len(value[key]) > 100:
            raise ValueError("INVALID_LIST_SETTING")
    if any(not isinstance(item, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,100}", item)
           for item in value["trace_services"]):
        raise ValueError("INVALID_TRACE_SERVICE")
    if not safe_remote_path(value["backup_log_dir"], allow_empty=True) or not safe_remote_path(value["nginx_log_dir"]):
        raise ValueError("INVALID_REMOTE_DIRECTORY")
    if any(not safe_remote_path(item) for item in value["storage_roots"]):
        raise ValueError("INVALID_STORAGE_ROOT")
    for key in ("maven_profile", "frontend_build_script"):
        if not isinstance(value[key], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_:.-]{0,63}", value[key]):
            raise ValueError("INVALID_BUILD_SETTING")
    return value


def check_policy(directory, scope, action):
    if not re.fullmatch(r"(?:(domestic|overseas)-)?(dev|test|prod)", scope):
        raise ValueError("INVALID_SCOPE")
    if action not in MUTATIONS:
        return
    if scope.endswith("prod"):
        raise ValueError("PROD_READ_ONLY")
    if not settings(directory)["write_enabled"]:
        raise ValueError("WRITES_DISABLED")


def initialize(directory):
    directory = Path(directory).expanduser().resolve()
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    created, preserved = [], []
    contents = {"settings.json": json.dumps(DEFAULTS, indent=2) + "\n"}
    for scope in SCOPES:
        contents[f"servers-{scope}.conf"] = "# name|host|user|authentication|lan|description\n"
        contents[f"services-{scope}.conf"] = "# name|servers|logDir|logGlob|description|repo|module|dir|artifact|deployMode|kind|verifyUrl|packageManager\n"
    for name, text in contents.items():
        path = directory / name
        try:
            with path.open("x", encoding="utf-8", newline="\n") as handle:
                os.chmod(path, 0o600)
                handle.write(text)
            created.append(name)
        except FileExistsError:
            preserved.append(name)
    return {"config_dir": str(directory), "created": created, "preserved": preserved,
            "write_enabled": settings(directory)["write_enabled"]}


def validate(directory):
    directory = Path(directory)
    policy = settings(directory)
    servers, services = 0, 0
    for scope in SCOPES:
        names, rows = set(), []
        for kind in ("servers", "services"):
            path = directory / f"{kind}-{scope}.conf"
            if not path.is_file() or path.stat().st_size > 1048576:
                raise ValueError("CONFIG_MISSING_OR_TOO_LARGE")
            for line in path.read_text(encoding="utf-8-sig").splitlines():
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                row = line.split("|")
                if len(row) < (6 if kind == "servers" else 5) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,100}", row[0]):
                    raise ValueError("INVALID_CONFIG_ROW")
                if row[0] in names:
                    raise ValueError("DUPLICATE_CONFIG_TARGET")
                names.add(row[0])
                if kind == "servers":
                    servers += 1
                else:
                    rows.append(row)
            if kind == "servers":
                server_names = set(names)
        for row in rows:
            if not set(row[1].split(",")) <= server_names:
                raise ValueError("UNKNOWN_SERVICE_NODE")
        services += len(rows)
    return {"config_dir": str(directory), "servers": servers, "services": services,
            "write_enabled": policy["write_enabled"], "schema_version": 1}


def main():
    parser = argparse.ArgumentParser(description="External configuration; init never overwrites existing files")
    parser.add_argument("command", choices=("init", "validate", "resolve", "settings", "policy", "value"))
    parser.add_argument("values", nargs="*")
    parser.add_argument("--dir", dest="directory")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    arguments = parser.parse_args()
    try:
        directory = Path(arguments.directory).expanduser().resolve() if arguments.directory else config_directory(arguments.root)
        if arguments.command == "resolve":
            print(directory)
        elif arguments.command == "init":
            print(json.dumps(initialize(directory)))
        elif arguments.command == "validate":
            print(json.dumps(validate(directory)))
        elif arguments.command == "settings":
            print(json.dumps(settings(directory)))
        elif arguments.command == "policy":
            if len(arguments.values) != 2:
                raise ValueError("POLICY_ARGUMENTS_REQUIRED")
            check_policy(directory, *arguments.values)
        else:
            if len(arguments.values) != 1 or arguments.values[0] not in DEFAULTS:
                raise ValueError("UNKNOWN_SETTING")
            value = settings(directory)[arguments.values[0]]
            print(json.dumps(value) if isinstance(value, (bool, list)) else value)
        return 0
    except (ValueError, OSError) as error:
        print(json.dumps({"status": "FAILED", "error": str(error)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
