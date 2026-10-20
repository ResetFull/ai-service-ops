#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source <(sed '/^usage(){/,$d' "$ROOT/scripts/service-ops.sh")
PLUGIN_ROOT=$ROOT
work=$(mktemp -d)
cleanup(){
  local resolved; resolved=$(cd "$work" && pwd -P)
  [[ "$resolved" = /tmp/* || "$resolved" = /c/Users/*/AppData/Local/Temp/* ]] || exit 1
  rm -f -- "$work/program" "$work/events"; rmdir "$work"
}
trap cleanup EXIT
printf 'fixture\n' > "$work/program"
prepare_ssh_auth(){ SSH_OPTIONS=(); SRV_USER=fixture; SRV_HOST=fixture.invalid; SRV_NAME=node; }
ssh(){ return 124; }
code=0
SERVICE_OPS_REMOTE_MUTATION=1 ssh_program "$work/program" 0 > "$work/events" 2>&1 || code=$?
[ "$code" -eq 75 ] && grep -q 'RESULT UNKNOWN' "$work/events" || { echo 'write deadline did not remain UNKNOWN'; exit 1; }
code=0
SERVICE_OPS_REMOTE_MUTATION=0 ssh_program "$work/program" 0 > "$work/events" 2>&1 || code=$?
[ "$code" -eq 2 ] && grep -q 'RESULT PARTIAL' "$work/events" || { echo 'query deadline changed'; exit 1; }
remote(){ printf '%s\n' "$1" >> "$work/events"; }
: > "$work/events"
(REMOTE_LOCK_HELD=1; REMOTE_WRITE_UNKNOWN=1; unlock) > /dev/null 2>&1 || true
! grep -q release "$work/events" || { echo 'uncertain writes released their lock'; exit 1; }
timeout(){ shift; "$@"; }
scp(){ return 255; }
code=0
scp_put "$work/program" /tmp/fixture > "$work/events" 2>&1 || code=$?
[ "$code" -eq 75 ] && grep -q 'RESULT UNKNOWN' "$work/events" || { echo 'uncertain transfer did not remain UNKNOWN'; exit 1; }
code=0
(SERVICE_OPS_PYTHON=python; SERVICE_OPS_TASK_SCOPE=test; SERVICE_OPS_CONFIG_FINGERPRINT=mismatch; assert_task_config) > "$work/events" 2>&1 || code=$?
[ "$code" -ne 0 ] && grep -q CONFIG_CHANGED "$work/events" || { echo 'configuration drift was accepted'; exit 1; }
echo 'PASS: Bash uncertain writes retain locks and preserve query deadline semantics'
