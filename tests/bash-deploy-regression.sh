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
mkdir -p "$work/plugin/scripts" "$work/plugin/config" "$work/bin" "$work/ws/repo/module/target"
cp "$ROOT/scripts/"*.sh "$work/plugin/scripts/"; touch "$work/key"
cp "$ROOT/scripts/"*.py "$work/plugin/scripts/"
printf '{"schema_version":1,"write_enabled":true}\n' > "$work/plugin/config/settings.json"
printf 'one|localhost|user|%s|127.0.0.1|mock\n' "$work/key" > "$work/plugin/config/servers-test.conf"
printf 'svc|one|/logs|*.log|mock|repo|module|/app|a.jar|script|jar|http://localhost/health|\n' > "$work/plugin/config/services-test.conf"
git -C "$work/ws/repo" init -q; git -C "$work/ws/repo" config user.email mock@example.invalid; git -C "$work/ws/repo" config user.name Mock
printf 'module/target/\n' > "$work/ws/repo/.gitignore"; printf source > "$work/ws/repo/src.txt"
git -C "$work/ws/repo" add .; git -C "$work/ws/repo" commit -qm initial
cat > "$work/bin/mvn" <<'MOCK'
#!/usr/bin/env bash
echo mvn >> "$MOCK_AUDIT"
[ "${MOCK_BUILD_FAIL:-0}" = 0 ] || exit 13
[ "${MOCK_NO_OUTPUT:-0}" = 0 ] || exit 0
mkdir -p module/target; printf 'new-jar-%s' "${MOCK_BUILD_VERSION:-1}" > module/target/a.jar
MOCK
cat > "$work/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
command=${!#}; printf '%s\n' "$command" >> "$MOCK_AUDIT"
if [[ "$command" = *"'restart'"* && "${MOCK_RESTART_FAIL:-0}" = 1 ]]; then echo 'restart failed secret=hidden' >&2; exit 11; fi
echo 'RESULT OK mock_remote=true'
MOCK
cat > "$work/bin/scp" <<'MOCK'
#!/usr/bin/env bash
echo scp >> "$MOCK_AUDIT"
if [ "${MOCK_SECOND_BUILD:-0}" = 1 ]; then MOCK_SECOND_BUILD=0 MOCK_BUILD_VERSION=2 bash "$MOCK_CLI" test svc build >/dev/null; fi
[ "${MOCK_SCP_FAIL:-0}" = 0 ] || { echo 'scp failure password=hidden' >&2; exit 12; }
MOCK
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" SERVICE_OPS_WS="$work/ws" SERVICE_OPS_STATE_DIR="$work/state" MOCK_AUDIT="$work/audit" MOCK_CLI="$work/plugin/scripts/service-ops.sh"
cli(){ bash "$MOCK_CLI" "$@"; }
fail(){ echo "FAIL: $*" >&2; exit 1; }
cli test svc build > "$work/out"
manifest="$work/state/test/svc/current.tsv"; [ -f "$manifest" ] || fail 'build missing record'
first=$(awk -F '\t' '$1=="release_id"{print $2}' "$manifest"); sha=$(awk -F '\t' '$1=="artifact_sha256"{print $2}' "$manifest")
grep -q '^source_fingerprint' "$manifest" || fail 'source fingerprint absent'
: > "$work/audit"
if MOCK_SCP_FAIL=1 cli test svc upload > "$work/out" 2>&1; then fail 'failed SCP accepted'; fi
! grep -q "'install'" "$work/audit" && grep -q "'release'" "$work/audit" || fail 'SCP failure continued or lock leaked'
! grep -q hidden "$work/out" && grep -q '\[REDACTED\]' "$work/out" || fail 'stderr secret leaked'
printf changed >> "$work/ws/repo/src.txt"
if cli test svc upload > "$work/out" 2>&1; then fail 'changed source uploaded'; fi
cli test svc build > "$work/out"
grep -q $'^dirty\tdirty$' "$manifest" || fail 'uncommitted source was not recorded'
cli test svc upload > "$work/out"
printf changed-again >> "$work/ws/repo/src.txt"
: > "$work/audit"
if cli test svc upload > "$work/out" 2>&1; then fail 'dirty source changed after build was uploaded'; fi
[ ! -s "$work/audit" ] || fail 'dirty source mismatch discovered after remote writes'
git -C "$work/ws/repo" checkout -- src.txt
if MOCK_NO_OUTPUT=1 cli test svc build > "$work/out" 2>&1; then fail 'old artifact accepted after fake successful build'; fi
[ ! -f "$manifest" ] || fail 'failed build retained usable current record'
cli test svc build >/dev/null
: > "$work/audit"
if MOCK_RESTART_FAIL=1 cli test svc all > "$work/out" 2>&1; then fail 'restart failure accepted'; fi
! grep -q "'verify'" "$work/audit" || fail 'verify executed after restart failure'
: > "$work/audit"
MOCK_SECOND_BUILD=1 cli test svc all > "$work/out"
first=$(sed -n 's/.*build release=\([^ ]*\).*/\1/p' "$work/out" | head -1)
current=$(awk -F '\t' '$1=="release_id"{print $2}' "$manifest")
[ "$first" != "$current" ] || fail 'second build not inserted'
grep "'install'" "$work/audit" | grep -q "$first" || fail 'all uploaded concurrent current'
grep "'verify'" "$work/audit" | grep -q "$first" || fail 'all verified concurrent current'
: > "$work/audit"
cli test svc verify "$first" > "$work/out"
grep "'verify'" "$work/audit" | grep -q "$first" || fail 'explicit verify drifted to current'
sed -i 's#http://localhost/health##' "$work/plugin/config/services-test.conf"
: > "$work/audit"
if cli test svc all > "$work/out" 2>&1; then fail 'missing readiness URL accepted'; fi
[ ! -s "$work/audit" ] || fail 'missing URL discovered after writes'
echo 'PASS: Bash deployment behavior (mock build, SSH and SCP; isolated Git repo)'
