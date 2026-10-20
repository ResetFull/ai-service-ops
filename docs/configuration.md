# Configuration

Initialize with python scripts/ops_config.py init, or use the config init
subcommand of either native entrypoint.

Resolution order:

1. --dir, for the configuration command receiving that argument.
2. SERVICE_OPS_CONFIG_DIR, when set.
3. A legacy config directory inside a checkout, if present.
4. Windows: LOCALAPPDATA/ai-service-ops/config.
5. Linux: XDG_CONFIG_HOME/ai-service-ops, or ~/.config/ai-service-ops.

An explicit --dir on configuration commands selects that command's directory.
Set SERVICE_OPS_CONFIG_DIR to use the same non-default directory for operations.
The public package has no live config directory. examples/config contains
empty templates; it does not connect anywhere.

Configuration schema version 1 uses the existing pipe-separated inventory.
Groups are dev/test/prod and overseas-dev/test/prod; domestic-* aliases are
accepted. Regions are organizational labels, not inferred geography.
Arbitrary group names are deferred to a future schema version.

Server fields:

```text
name|host|user|authentication|lan|description
demo-node|example.invalid|ops|~/.ssh/id_ed25519|192.0.2.10|Replace with your own server
```

Service fields:

```text
name|servers|logDir|logGlob|description|repo|module|dir|artifact|deployMode|kind|verifyUrl|packageManager
demo-app|demo-node|/srv/demo/logs|*.log|Example application
```

Publish fields are optional for queries. Missing release fields or a readiness
URL stop release actions; they are never inferred from a process listing.
repo is relative to SERVICE_OPS_WS; no workstation path is auto-detected.

settings.json keys:

| Key | Default | Meaning |
|---|---|---|
| schema_version | 1 | Unsupported versions fail closed |
| write_enabled | false | Explicit local opt-in for non-production mutations |
| trace_services | [] | Default trace scope; otherwise specify services |
| backup_log_dir | empty | Explicit backup path, with optional {svc}/{host} placeholders |
| nginx_log_dir | /var/log/nginx | Access log directory |
| storage_roots | [] | Explicit absolute paths for bounded image-layout sampling |
| maven_profile | test | Maven build profile |
| run_build_tests | true | Maven tests run unless explicitly disabled |
| frontend_build_script | build:test | Package-manager build script |

Unknown fields, non-boolean policy values and unsafe paths are rejected.
Additive schema migrations are not automatic; config init only creates missing
files. Back up user configuration before changing its schema.

## Credentials and host identity

Private keys remain outside the repository. Password authentication uses a
password:PROFILE reference and SERVICE_OPS_PASSWORD_PROFILE. Windows may store
a user/machine-bound DPAPI credential with scripts/save-credential.ps1.
Bash does not decrypt DPAPI credentials.

Keep the entire .ssh directory in your user profile or another private location.
Use an absolute key path or ~/.ssh/id_ed25519 in your external inventory.
Do not copy .ssh, public-key lists, SSH config or known_hosts into a checkout,
even when a Git ignore rule exists. The publication gate rejects these files.
The project contains path examples only; it never imports your SSH directory.

The configuration must contain only a credential reference, never a password.
Do not weaken StrictHostKeyChecking. Verify host fingerprints independently.
Explicit inventory fields for ssh-agent, custom ports and ProxyJump are planned;
this Alpha makes no compatibility claim for those setups.

## Local state

SERVICE_OPS_STATE_DIR overrides state storage. Defaults are
LOCALAPPDATA/ai-service-ops on Windows and XDG_STATE_HOME/ai-service-ops on Linux.
State must be outside the plugin and business checkout. Receipts, events and
release artifacts can contain sensitive operational metadata; do not attach
the entire state directory to a public issue.

Only output is redacted by pattern. Free text may contain secrets the patterns
cannot identify. Review evidence before sharing it or sending it to a model.
