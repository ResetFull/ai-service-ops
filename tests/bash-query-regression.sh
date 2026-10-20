#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
temp_root=$(cd "${TMPDIR:-/tmp}" && pwd -P)
work=$(mktemp -d "$temp_root/service-ops-test.XXXXXXXX")
cleanup(){
  local resolved; resolved=$(cd "$work" && pwd -P) || return 1
  [[ "$resolved" = "$temp_root"/service-ops-test.* ]] || { echo 'unsafe test cleanup path' >&2; return 1; }
  rm -rf -- "$resolved"
}
trap cleanup EXIT
mkdir -p "$work/plugin/scripts" "$work/plugin/config" "$work/bin" "$work/logs"
cp "$ROOT/scripts/"*.sh "$work/plugin/scripts/"
cp "$ROOT/scripts/"*.py "$work/plugin/scripts/"
touch "$work/key"
printf 'one|localhost|user|%s|127.0.0.1|mock\ntwo|localhost|user|%s|127.0.0.2|mock\n' "$work/key" "$work/key" > "$work/plugin/config/servers-test.conf"
printf 'svc|one,two|%s|*.log|mock||||||jar||\n' "$work/logs" > "$work/plugin/config/services-test.conf"
cp "$work/plugin/config/servers-test.conf" "$work/plugin/config/servers-prod.conf"
cp "$work/plugin/config/services-test.conf" "$work/plugin/config/services-prod.conf"
cat > "$work/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
if [ "${MOCK_SSH_HANG:-0}" = 1 ]; then sleep 10; exit 0; fi
if [ "${MOCK_SSH_FAIL:-0}" = 1 ]; then echo 'ssh refused password=secret' >&2; exit 255; fi
printf '%s\n' "${!#}" >> "$MOCK_AUDIT"
bash -c "${!#}"
MOCK
chmod +x "$work/bin/ssh"
export SERVICE_OPS_TEST_SED=$(command -v sed)
cat > "$work/bin/sed" <<'MOCK'
#!/usr/bin/env bash
for argument in "$@"; do
  case "$argument" in *'/Ig;'*|*'#Ig;'*) echo 'unsupported case-insensitive sed flag' >&2; exit 2;; esac
done
exec "$SERVICE_OPS_TEST_SED" "$@"
MOCK
chmod +x "$work/bin/sed"
export PATH="$work/bin:$PATH" MOCK_AUDIT="$work/audit"
cli(){ bash "$work/plugin/scripts/service-ops.sh" "$@"; }
fail(){ echo "FAIL: $*" >&2; exit 1; }
printf '[2026-09-27 23:59:58] ERROR first quote '\'' semicolon ; dollar $()\ntrace-123 old\n' > "$work/logs/service.2026-09-27.log"
printf '[2026-09-28 00:00:02] ERROR second\ntrace-123 new\n' > "$work/logs/service.2026-09-28.log"
cli test svc logsrange '2026-09-27 23:59:57' '2026-09-28 00:00:03' > "$work/out"
grep -q 'first quote' "$work/out" && grep -q 'ERROR second' "$work/out" || fail 'cross-day range missed rolling file'
cli test svc grep "quote ' semicolon" > "$work/out"
grep -q 'first quote' "$work/out" || fail 'quoted keyword changed'
[ "$(grep -c 'EVIDENCE' "$work/out")" -eq 1 ] || fail 'single-node query widened its default scope'
cli test svc grepall 'ERROR' > "$work/out"
[ "$(grep -c 'EVIDENCE' "$work/out")" -eq 2 ] || fail 'grepall skipped a configured node'
cli test svc grep "'; touch $work/injected; #" > "$work/out"
[ ! -e "$work/injected" ] || fail 'query keyword executed shell code'
printf '[2026-09-28 00:01:00] {"PASSWORD":"value with space", "cardNo":"6222 3333"} Authorization: Bearer secret-value https://host/path?token=secret\n' >> "$work/logs/service.2026-09-28.log"
cli test svc logs 20 one > "$work/out"
! grep -q 'with space\|6222\|secret-value\|token=secret' "$work/out" || fail 'structured secret redaction failed'
cli test trace trace-123 svc > "$work/out"
[ "$(grep -c 'EVIDENCE' "$work/out")" -eq 2 ] || fail 'trace skipped configured nodes'
if cli test trace trace-123 svc unknown > "$work/out" 2>&1; then fail 'wrong server accepted'; fi
for invalid in '20260230' '2026;touch'; do if cli test svc logs 20 one "$invalid" > "$work/out" 2>&1; then fail 'invalid date accepted'; fi; done
if cli test svc logs '1;touch' > "$work/out" 2>&1; then fail 'injected count accepted'; fi
if cli test svc logsrange '2026-09-28 24:00:00' '2026-09-29 00:00:00' > "$work/out" 2>&1; then fail 'invalid clock accepted'; fi
if cli test svc logsrange '2026-09-27 23:59' '2026-09-28 00:01' '' one 20260928 > "$work/out" 2>&1; then fail 'cross-day query silently narrowed by date'; fi
cli test svc grep 'absent' > "$work/out"; grep -q 'RESULT NO_MATCH' "$work/out" || fail 'no-match state absent'
if MOCK_SSH_FAIL=1 cli test svc logs 20 one > "$work/out" 2>&1; then fail 'SSH failure treated as empty'; fi
grep -q 'RESULT SSH_FAILED' "$work/out" && grep -q '\[REDACTED\]' "$work/out" && ! grep -q secret "$work/out" || fail 'SSH evidence/redaction incorrect'
if SERVICE_OPS_QUERY_MAX_BYTES=10 cli test svc logs 20 one > "$work/out" 2>&1; then fail 'partial accepted as complete'; fi
grep -q 'RESULT PARTIAL' "$work/out" || fail 'partial state absent'
if MOCK_SSH_HANG=1 SERVICE_OPS_QUERY_TIMEOUT_SECONDS=1 cli test svc logs 20 one > "$work/out" 2>&1; then fail 'query deadline accepted hanging SSH'; fi
grep -q 'RESULT PARTIAL' "$work/out" || fail 'deadline state absent'
mv "$work/plugin/config/services-test.conf" "$work/plugin/config/services-test.saved"
if cli test doctor query > "$work/out" 2>&1; then fail 'doctor accepted missing configuration'; fi
grep -q CONFIG_MISSING "$work/out" || fail 'missing configuration evidence absent'
mv "$work/plugin/config/services-test.saved" "$work/plugin/config/services-test.conf"
if cli prod one exec 'touch /tmp/forbidden' > "$work/out" 2>&1; then fail 'production exec accepted'; fi
echo 'PASS: Bash query behavior (mock SSH; real temporary rolling logs)'
