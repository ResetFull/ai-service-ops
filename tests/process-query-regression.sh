#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source <(awk '/^process_sample\(\)/{copy=1} /^printf .SAMPLE/{copy=0} copy{print}' "$ROOT/scripts/remote-query.sh")
type process_sample >/dev/null 2>&1 || { echo 'process sampler missing'; exit 1; }
export PROCESS_FIXTURE_SELF=$BASHPID
ps(){
  printf 'PID PPID CPU MEM ELAPSED COMMAND\n'
  printf '%s 1 0 0 00:00 bash -s -- status fixture-service\n' "$PROCESS_FIXTURE_SELF"
  printf '424242 1 1 2 00:10 java -jar /srv/fixture-service.jar\n'
  printf '424243 %s 0 0 00:00 grep fixture-service\n' "$PROCESS_FIXTURE_SELF"
}
output=$(process_sample fixture-service 10 "$PROCESS_FIXTURE_SELF")
[[ "$output" = *'424242'* && "$output" != *'bash -s'* && "$output" != *'grep fixture-service'* ]]
[[ -z "$(process_sample missing-service 10 "$PROCESS_FIXTURE_SELF")" ]]
echo 'PASS: process observations exclude query ancestors and descendants'
