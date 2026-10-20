# AI Service Ops

Evidence-driven SSH operations for AI agents and humans.

[中文说明](README.zh-CN.md) · [Configuration](docs/configuration.md) · [Security](SECURITY.md)

AI Service Ops combines a deterministic PowerShell/Bash execution layer with
Codex skills. It collects bounded diagnostic evidence, records task receipts,
and supports explicitly enabled non-production releases. Production is read-only.

**Public Alpha:** local-first, single-operator, Linux servers. The host agent
performs reasoning; this project does not run its own LLM or an autonomous daemon.

| Capability | Behavior |
|---|---|
| Diagnostics | Processes, bounded logs, trace IDs, resources, Nginx and configured storage samples |
| Guided investigation | Startup and HTTP 502 evidence recipes, explicit missing evidence |
| Execution control | Default read-only policy, production guards, locks and immutable release records |
| Task receipts | Request deduplication, config fingerprints, redacted bounded output |
| Uncertain writes | UNKNOWN with retained locks; read-only reconciliation before another decision |
| Event integrity | Local authenticated event channel; log text cannot impersonate execution phases |

## Try it without credentials

Requires Python 3.10+. The demo does not connect to SSH or the network.

```sh
git clone https://github.com/ResetFull/ai-service-ops.git
cd ai-service-ops
python scripts/demo.py
```

The synthetic demo reports a sample port conflict, redacts a fake password and
phone number, and retains UNDETERMINED because its evidence is incomplete.
Task receipts are saved outside the checkout.

## Configure a real server

Controller requirements: Python 3.10+, OpenSSH, and either PowerShell 7 or Bash 4+.
The remote programs target GNU/Linux with Bash, GNU coreutils/findutils, awk,
and timeout. Release verification additionally needs curl, tar and SHA-256 tools.
macOS controllers and other remote operating systems are not validated in this Alpha.

```powershell
pwsh ./scripts/service-ops.ps1 config init
pwsh ./scripts/service-ops.ps1 config validate
pwsh ./scripts/service-ops.ps1 demo
```

Bash uses the same arguments:

```sh
bash scripts/service-ops.sh config init
bash scripts/service-ops.sh config validate
bash scripts/service-ops.sh demo
```

Edit the inventory directory printed by init. Initialization preserves every
existing file. Credentials and state never belong in the checkout.
See [configuration](docs/configuration.md) for all fields and safe examples.

```sh
bash scripts/service-ops.sh test doctor query
bash scripts/service-ops.sh task --timeout 60 --request-id incident-001 run test demo-app status demo-node
bash scripts/service-ops.sh task list
bash scripts/service-ops.sh task status JOB_ID
bash scripts/service-ops.sh task evidence JOB_ID
bash scripts/service-ops.sh task --timeout 120 diagnose test demo-app startup --server demo-node
```

Every SSH connection checks known_hosts strictly. Verify the server fingerprint
through a trusted channel before enrolling it. Missing credentials stop execution;
the tool does not guess passwords or try unrelated identities.

## Use with Codex

This repository includes a local plugin marketplace and two skills:
diagnose-services and operate-test-services.

```sh
codex plugin marketplace add https://github.com/ResetFull/ai-service-ops.git
codex plugin add ai-service-ops@ai-service-ops
```

The CLI can also run without an AI host. No model API key or hosted service
is provided by this project. Any model's access to evidence is controlled by
the host application you choose.

## Releases and recovery

Writes are disabled until the user edits write_enabled in their local settings.
The public Alpha supports one configured test node per service, Java JARs and
static frontends. Maven tests run by default; build settings are configurable.
An explicit request to deploy does not imply permission to rollback or migrate
an existing directory layout.

Use one task run ... all invocation for a complete release; its fixed build
record follows upload and verification. Never split it into concurrent commands
that follow a changing current index.

If a write times out or disconnects, UNKNOWN does not mean the operation stopped.
Keep the lock and collect task reconcile evidence. This never unlocks, retries,
resumes or rolls back automatically. Local cancellation cannot prove remote
termination. See [operation contracts](docs/architecture.md).

Task SUCCEEDED means a query finished within its stated scope. It does not
mean the application is healthy. NO_MATCH, NO_LOG and PARTIAL remain explicit;
running processes and HTTP 200 alone do not establish release identity.

## Validation and limitations

Run the isolated regression suite:

```sh
python scripts/run_checks.py
python scripts/package_release.py
```

CI checks Windows and Linux controllers. Regression fixtures exercise SSH/SCP
failures, process identity, frontend switching, redaction, policy and receipts.
These checks do not certify your own deployment scripts, server permissions,
production environment, or business end-to-end behavior.
The initial release also underwent [isolated live validation](docs/validation.md);
private inventories and raw receipts are excluded.

There is no MCP server, multi-user authorization service, automatic remediation,
Kubernetes controller, or multi-node deployment in this release.

## License and contributions

Apache-2.0. See [LICENSE](LICENSE), [NOTICE](NOTICE),
[contribution guidance](CONTRIBUTING.md), and [security policy](SECURITY.md).
