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
mkdir -p "$work/proc/123" "$work/proc/124" "$work/bin" "$work/app"
cat > "$work/bin/readlink" <<'MOCK'
#!/usr/bin/env bash
case "${!#}" in */exe) [ -f "${!#}" ] && cat "${!#}";; *) printf '%s\n' "${!#}";; esac
MOCK
chmod +x "$work/bin/readlink"; export PATH="$work/bin:$PATH"
awk '/^exact_pid\(\)/{copy=1} /^activate_record\(\)/{copy=0} copy{print}' "$ROOT/scripts/remote-release.sh" | sed "s#/proc/#$work/proc/#g" > "$work/functions"
source "$work/functions"; target="$work/app"; artifact=a.jar
printf '/usr/bin/java' > "$work/proc/123/exe"; printf '/bin/bash' > "$work/proc/124/exe"
printf '/usr/bin/java\0-jar\0%s\0' "$target/$artifact" > "$work/proc/123/cmdline"
printf '/bin/bash\0-jar\0%s\0' "$target/$artifact" > "$work/proc/124/cmdline"
{ printf '123 (java process) S'; for ((field=4;field<=21;field++)); do printf ' 0'; done; printf ' 500\n'; } > "$work/proc/123/stat"
[ "$(exact_pid)" = 123 ] || { echo 'FAIL: non-java process accepted'; exit 1; }
[ "$(process_identity)" = 123:500 ] || { echo 'FAIL: starttime fingerprint wrong'; exit 1; }
printf '/usr/bin/java' > "$work/proc/124/exe"
code=0; exact_pid > "$work/out" 2>&1 || code=$?
[ "$code" -eq 2 ] || { echo 'FAIL: duplicate JVM accepted'; exit 1; }
echo 'PASS: Java process identity parser (isolated proc fixture; no live Linux JVM)'
