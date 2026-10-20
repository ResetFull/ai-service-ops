# AI Service Ops 0.1.0-alpha.1

First public Alpha under Apache-2.0.

AI-assisted SSH diagnostics and guarded releases through PowerShell/Bash and
Codex skills:

- External inventory and credentials; no live assets or SSH directory included.
- Read-only defaults, production guards and explicit test-write policy.
- Bounded diagnostic evidence, persistent receipts and request deduplication.
- Signed local execution events isolated from untrusted log text.
- Pinned JAR/frontend release identity, locks, verification and rollback.
- UNKNOWN write retention with read-only reconciliation.
- Credential-free demonstration, privacy gates and reproducible ZIP packaging.

Validation includes Windows/Linux CI and 52 final assertions over an authorized
test node, with disposable frontend/JVM fixtures. See docs/validation.md for
coverage and limitations. Real business releases and production writes are
outside that validation.

Install from the repository's Codex marketplace or extract the ZIP and use the
CLI. Run config init to create your own external inventory. Keep .ssh and all
operational state outside the checkout.

This release supports one test node per service. It has no hosted LLM, MCP
server, multi-user authorization service or autonomous remediation daemon.
