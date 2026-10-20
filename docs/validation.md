# Alpha validation scope

The first Alpha was checked with isolated regression fixtures and an authorized
non-production GNU/Linux node. This document contains no inventory, key paths,
host addresses, raw output or private receipts.

## Reproducible checks

Run python -B scripts/run_checks.py --require-native with Python 3.10+,
PowerShell 7 and Bash 4+. Windows requires Git for Windows.

The suite covers policy defaults and production guards, literal parameter
transport, bounded queries, redaction, configuration drift, request reuse,
process identity, frontend release/rollback, uncertain writes, authenticated
events, privacy rejection and deterministic packaging.

GitHub Actions checks Windows/Linux controllers with Python 3.10 and 3.13.
The remote filesystem suite runs on Linux, where its native symlink/rename
contract applies. Windows runs the controller suites and reports that single
GNU/Linux remote suite as NOT_APPLICABLE. Neither CI platform receives business
network access or SSH credentials.

## Maintainer live validation

Windows PowerShell and Git Bash controllers were exercised over real SSH/SCP.
The manual validation used external private configuration and dedicated
temporary applications on an authorized test node:

- Existing-service process observations, log-file discovery and host resources.
- Missing-service observations remain NO_MATCH and exclude query processes.
- Two frontend versions, native Linux symlink switching, content hashes, HTTP
  release markers, pinned verification and rollback.
- Maven-built isolated JARs, real JVM startup, artifact/process identity and
  loopback readiness probes.
- Rejection of a competing lock and a corrupted local artifact snapshot.
- A real remote write deadline returns UNKNOWN and retains the owned lock.

All 52 final manual assertions passed. The temporary fixture processes and
directories were removed. Intentional failure injection is recorded as an
expected assertion, not an unresolved deployment.

Private live-test scripts and raw receipts are intentionally excluded from
source and archives. The automated suite is independently runnable.

## Limits

Validation does not certify production, another operator's restart scripts,
permissions, external dependencies, business end-to-end behavior, every Linux
distribution, macOS controllers or unsupported deployment modes. An Alpha
release is not a promise of zero defects.
