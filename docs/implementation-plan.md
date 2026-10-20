# Public Alpha implementation plan

Scope: publish an Apache-2.0 SSH operations toolkit with Codex skills, external
configuration, safe defaults, task receipts, and a credential-free demo.
The existing personal installation and its inventory are outside this change.

1. Separate public code and private data.
   Verify: no production inventory, personal path, credential, or internal
   topology appears in tracked files or the release archive.
2. Repair execution event integrity.
   Verify: stdout cannot forge task events; only authenticated local executor
   events matching the job and action enter the receipt.
3. Add external configuration and read-only defaults.
   Verify: init is non-destructive, settings are validated, and all entrypoints
   reject writes unless an explicit local policy enables them.
4. Make operational paths configurable and provide an offline demo.
   Verify: the demo runs without SSH or secrets and preserves bounded evidence.
5. Add documentation, packaging, and isolated CI.
   Verify: unit/native regressions pass, manifests agree, and the archive passes
   the same privacy checks as the repository.
6. Publish a public prerelease.
   Verify: remote commit and release tag match the reviewed local commit;
   archive hashes match, and CI results are reported separately from live tests.

Deferred: autonomous remediation, a hosted service, MCP, arbitrary environment
names, and multi-node writes. Production remains read-only.
