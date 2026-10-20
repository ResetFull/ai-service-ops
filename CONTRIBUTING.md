# Contributing

Start with a small reproducible problem and a test using temporary fixtures.
Do not depend on the maintainer's servers or local inventory.

Run python scripts/run_checks.py before opening a pull request.
Use Python 3.10+, PowerShell 7 and Bash 4+ where the corresponding checks apply.
Windows checks require Git for Windows. Linux remote scripts require GNU tools.

Keep one purpose per change, preserve existing query and release behavior,
and document observable validation. Use conventional commit messages.
Changes to execution, policy, authentication, events or recovery require
boundary/failure tests for both native entrypoints.

Do not remove tests, disable validation, weaken host-key checking or auto-delete
locks to make a failure disappear. Do not add an arbitrary-command escape hatch
to the task API. New write capabilities need an explicit policy contract.

Use documentation IP ranges and example.invalid/example.com in fixtures.
Run python scripts/privacy_check.py before sharing source or release assets.
Do not attach raw logs or personal inventories to pull requests.

Contributions must be yours to submit under Apache-2.0. Preserve required
third-party license and attribution notices. Report vulnerabilities privately
as described in SECURITY.md.
