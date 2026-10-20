#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
temp_root=$(cd "${TMPDIR:-/tmp}" && pwd -P)
work=$(mktemp -d "$temp_root/service-ops-groups.XXXXXXXX")
cleanup(){
  local resolved; resolved=$(cd "$work" && pwd -P) || return 1
  [[ "$resolved" = "$temp_root"/service-ops-groups.* ]] || return 1
  rm -rf -- "$resolved"
}
trap cleanup EXIT
mkdir -p "$work/plugin/scripts" "$work/plugin/config" "$work/bin"
cp "$ROOT/scripts/service-ops.sh" "$ROOT/scripts/remote-query.sh" "$work/plugin/scripts/"
cp "$ROOT/scripts/"*.py "$work/plugin/scripts/"
printf '{"schema_version":1,"write_enabled":true}\n' > "$work/plugin/config/settings.json"
printf fixture > "$work/key"
export SERVICE_OPS_PASSWORD_OFFLINE='offline-password-not-for-argv'
export MOCK_CALLS="$work/calls"
cat > "$work/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " = *' StrictHostKeyChecking=yes '* ]]
if [[ " $* " = *' PreferredAuthentications=password '* ]]; then
  [[ " $* " = *' NumberOfPasswordPrompts=1 '* && " $* " != *' -i '* ]]
  [[ " $* " != *offline-password-not-for-argv* ]]
  [[ "$SSH_ASKPASS_REQUIRE" = force && -x "$SSH_ASKPASS" ]]
  [[ "$("$SSH_ASKPASS")" = "$SERVICE_OPS_PASSWORD_OFFLINE" ]]
else
  [[ " $* " = *' BatchMode=yes '* && " $* " = *' -i '* ]]
fi
printf called >> "$MOCK_CALLS"
cat >/dev/null
printf 'SAMPLE mocked\nRESULT OK\n'
MOCK
cp "$work/bin/ssh" "$work/bin/scp"
chmod +x "$work/bin/ssh" "$work/bin/scp"
export PATH="$work/bin:$PATH"
for scope in dev test prod overseas-dev overseas-test overseas-prod; do
  printf 'key|%s-key.invalid|root|%s/key||fixture\npassword|%s-password.invalid|root|password:OFFLINE||fixture\n' "$scope" "$work" "$scope" > "$work/plugin/config/servers-$scope.conf"
  printf '# no service fixtures\n' > "$work/plugin/config/services-$scope.conf"
done
script="$work/plugin/scripts/service-ops.sh"
for scope in domestic-dev domestic-test domestic-prod overseas-dev overseas-test overseas-prod test prod; do
  bash "$script" "$scope" key mem > "$work/out"
  grep -q 'RESULT OK' "$work/out"
  bash "$script" "$scope" password disk > "$work/out"
  grep -q 'RESULT OK' "$work/out"
done
before=$(wc -c < "$MOCK_CALLS")
for scope in prod domestic-prod overseas-prod; do
  for action in exec build upload restart rollback all unsupported-write; do
    if bash "$script" "$scope" key "$action" > "$work/out" 2>&1; then echo 'production write accepted' >&2; exit 1; fi
    grep -q PROD_READ_ONLY "$work/out"
  done
  if bash "$script" "$scope" doctor deploy > "$work/out" 2>&1; then exit 1; fi
  grep -q PROD_READ_ONLY "$work/out"
done
[[ "$(wc -c < "$MOCK_CALLS")" = "$before" ]]
printf 'collision|prod-key.invalid|root|%s/key||fixture\n' "$work" >> "$work/plugin/config/servers-dev.conf"
if bash "$script" domestic-dev collision exec ignored > "$work/out" 2>&1; then exit 1; fi
grep -q PROD_TARGET_READ_ONLY "$work/out"
unset SERVICE_OPS_PASSWORD_OFFLINE
if bash "$script" overseas-test password mem > "$work/out" 2>&1; then exit 1; fi
grep -q CREDENTIAL_MISSING "$work/out"
[[ "$(wc -c < "$MOCK_CALLS")" = "$before" ]]
printf 'pending|||||address missing\n' >> "$work/plugin/config/servers-overseas-prod.conf"
if bash "$script" overseas-prod pending mem > "$work/out" 2>&1; then exit 1; fi
grep -q HOST_ADDRESS_PENDING "$work/out"
echo 'PASS: Bash scope aliases, key/password auth, production guards, cross-group production protection and missing credentials'
