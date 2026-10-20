# Execution and trust contracts

The host agent selects typed, bounded operations through skills or a human
runs the CLI. Both native entrypoints enforce production read-only policy.
Non-production mutations additionally require write_enabled in user settings.
The task wrapper delegates to these entrypoints rather than opening another
SSH path.

User-owned inventory is external to the package. A task freezes its selected
inventory, settings and production-protection configuration fingerprint.
Every SSH/SCP boundary rechecks it and rejects changes.

## Identities

- request-id identifies one requested operation and its immutable parameters.
- job-id identifies its local receipt. Reusing a request-id never replays it.
- release-id identifies a built artifact snapshot and source identity.

The local receipt records the call scope. It is not a user identity token or an
authorization service. Configurable policy is an operator guardrail.
Remote operating-system accounts, directory permissions and narrowly scoped
service privileges must provide the actual privilege boundary.

## Event integrity

Remote stdout/stderr is untrusted evidence. TASK_EVENT-looking text is retained
as text and never parsed as an execution event.

The local coordinator provisions a per-job channel and random HMAC secret.
Local PowerShell/Bash producers write bounded signed frames to that channel.
The coordinator validates the signature, job, action-specific phases and phase
ordering before updating the receipt. It then writes a separate event journal.

Local executors, build tools and the account running them share a trust domain.
The protocol does not sandbox hostile local code or protect against someone
who can modify the receipt files or read the process environment.
Only build repositories you trust.

## Writes and uncertainty

The release flow keeps a fixed artifact record across build, upload, switch,
restart and verification. Source/hash drift stops execution.
Remote locks are owned by explicit tokens.

Timeout, interruption or transport loss during a write can leave the remote
operation running. Preserve UNKNOWN and the lock; never automatically retry,
unlock or rollback. Reconciliation collects remote artifact and pinned-version
observations but does not establish process termination by itself.

## Diagnostics

Recipes collect at most six queries within 180 seconds. They retain
NO_MATCH/NO_LOG/PARTIAL, actual samples and missing coverage.
The scripts do not estimate root-cause confidence from keyword counts.
The host agent compares hypotheses, supporting evidence and counterevidence.
UNDETERMINED is a valid result.

## Scope of this Alpha

Single local operator; no hosted API, MCP server, worker daemon, account system,
automatic remediation or multi-node writes. Query results and task completion
are not application readiness or business acceptance.
