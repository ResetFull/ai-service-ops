# Security policy

The public Alpha is experimental. Production operations are read-only.
Run with a dedicated least-privilege account and grant only the directories
and service actions required for your inventory. Do not grant blanket root or
unrestricted sudo merely to make a query succeed.

## Reporting

Use this repository's GitHub private vulnerability reporting channel when it
is available. If unavailable, request a private contact without posting exploit
details, credentials, host addresses, logs or personal data in a public issue.

Include a synthetic reproducer, affected version, controller/remote operating
systems and the observable impact. Never send a complete credential or state
directory. No response-time SLA is promised by this volunteer project.

## Supported security boundary

- Local code, executors and build repositories are trusted.
- Remote log text is data; it cannot authorize actions or generate task phases.
- Local policy does not replace operating-system authorization.
- Known-host verification stays enabled; missing authentication fails closed.
- Changing a local request identifier is not recovery from an UNKNOWN write.
- Cancelled local processes do not prove remote termination.
- Pattern redaction is best-effort; review evidence before sharing it.

The project has no telemetry collector or model backend. A chosen AI host may
send evidence to its model provider; inspect that host's data policies.

## Release hygiene

Only templates and synthetic fixtures belong in the repository or archives.
Never include live inventories, keys, DPAPI files, host fingerprints, receipts,
release snapshots or captured server output. CI uses isolated fixtures and
must not receive maintainer SSH credentials or access to business networks.

Keep .ssh outside the checkout, including public keys, SSH config and known_hosts.
An ignored file is not a publication guarantee: check the staged tree and the
actual archive. scripts/privacy_check.py rejects common key material, credential
paths and non-example IPv4 addresses. This gate is best-effort and cannot detect
every secret, private hostname or sensitive free-text value.
