#!/usr/bin/env bash
set -euo pipefail
action=${1:?}; service=${2:-}; directory=${3:-}; glob=${4:-'*.log'}; day=${5:-}; pattern=${6:-}; count=${7:-200}; context=${8:-0}; start=${9:-}; end=${10:-}; budget=${11:-16777216}; maxfiles=${12:-20}; maxlines=${13:-2000}
fail(){ printf 'RESULT QUERY_FAILED reason=%s\n' "$*" >&2; exit 1; }
result(){ printf 'RESULT %s files=%s bytes=%s output_limit=%s\n' "$1" "${#files[@]}" "$readbytes" "$maxlines"; }
printf 'SAMPLE time=%s timezone=%s host=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(date '+%Z')" "$(hostname)"
[[ "$count" =~ ^[0-9]+$ && "$context" =~ ^[0-9]+$ && "$budget" =~ ^[0-9]+$ && "$maxfiles" =~ ^[0-9]+$ && "$maxlines" =~ ^[0-9]+$ ]] || fail INVALID_BUDGET
[ "$count" -ge 1 ] && [ "$count" -le 10000 ] && [ "$context" -le 100 ] && [ "$budget" -ge 1 ] && [ "$budget" -le 268435456 ] && [ "$maxfiles" -ge 1 ] && [ "$maxfiles" -le 100 ] && [ "$maxlines" -ge 1 ] && [ "$maxlines" -le 10000 ] || fail INVALID_BUDGET
[ "${#pattern}" -le 4096 ] || fail PATTERN_TOO_LONG
if [ -n "$pattern" ] && [ "$action" != trace ]; then
  regex_rc=0; printf '\n' | grep -E -- "$pattern" >/dev/null 2>&1 || regex_rc=$?
  [ "$regex_rc" -lt 2 ] || fail INVALID_PATTERN
fi
[ "$action" = nginx-config ] || fail INVALID_ACTION
files=(); readbytes=0; partial=0; outputlines=0
roots=()
for root in /opt/nginx/conf /opt/nginx/conf.d /etc/nginx /usr/local/nginx/conf; do
  [ ! -d "$root" ] || roots+=("$root")
done
[ "${#roots[@]}" -gt 0 ] || { echo 'RESULT NO_MATCH reason=nginx_configuration_directory_missing'; exit 2; }
# Read existing configuration only; nginx -t/-T can open or create log files.
while IFS= read -r -d '' file; do
  if [ "${#files[@]}" -ge "$maxfiles" ]; then partial=1; break; fi
  files+=("$file")
done < <(find "${roots[@]}" -maxdepth 4 -type f -name '*.conf' -print0 | sort -z)
[ "${#files[@]}" -gt 0 ] || { echo 'RESULT NO_MATCH reason=no_conf_files'; exit 2; }
declare -A storage_paths=()
for file in "${files[@]}"; do
  remaining=$((budget-readbytes)); remaininglines=$((maxlines-outputlines))
  [ "$remaining" -gt 0 ] && [ "$remaininglines" -gt 0 ] || { partial=1; break; }
  size=$(stat -c '%s' "$file") || fail STAT_FAILED
  bytes=$size; if [ "$bytes" -gt "$remaining" ]; then bytes=$remaining; partial=1; fi
  readbytes=$((readbytes+bytes))
  stat -c 'FILE %n size=%s modified=%y' "$file" || fail STAT_FAILED
  output=$(head -c "$bytes" "$file" | awk '
    /^[[:space:]]*#/ {next}
    {count=split($0,parts,/[;{}]/)
     for(i=1;i<=count;i++) {
       directive=parts[i]; sub(/^[[:space:]]+/,"",directive); sub(/[[:space:]]+$/,"",directive)
       if(directive ~ /^(server$|upstream[[:space:]]|listen[[:space:]]|server_name[[:space:]]|location[[:space:]]|root[[:space:]]|alias[[:space:]]|proxy_pass[[:space:]]|include[[:space:]]|client_max_body_size[[:space:]]|expires[[:space:]]|server[[:space:]]+[A-Za-z0-9.$_-]+:|add_header[[:space:]]+Access-Control-)/) print NR ":" directive
     }}' | sed -E 's#(https?://)[^/@[:space:]]+@#\1[REDACTED]@#g; s#(https?://[^?[:space:]]+)\?[^[:space:]]+#\1?[REDACTED]#g') || fail CONFIG_FILTER_FAILED
  [ -n "$output" ] || continue
  lines=$(printf '%s\n' "$output" | wc -l)
  if [ "$lines" -gt "$remaininglines" ]; then partial=1; fi
  printf '%s\n' "$output" | head -n "$remaininglines" || { code=$?; [ "$code" -eq 141 ] || fail OUTPUT_FAILED; }
  emitted=$lines; [ "$emitted" -le "$remaininglines" ] || emitted=$remaininglines
  outputlines=$((outputlines+emitted))
  while IFS= read -r storage_path; do
    [[ "$storage_path" = /* && "$storage_path" != *'$'* && "$storage_path" != *'"'* && "$storage_path" != *"'"* && "$storage_path" != *' '* ]] || continue
    storage_paths["$storage_path"]=1
  done < <(printf '%s\n' "$output" | awk '/^[0-9]+:(root|alias)[[:space:]]+/ {sub(/^[0-9]+:(root|alias)[[:space:]]+/,""); print}')
done
for storage_path in "${!storage_paths[@]}"; do
  stat -Lc 'STORAGE_PATH %n type=%F device=%d inode=%i owner=%U mode=%a' -- "$storage_path" 2>/dev/null || { printf 'STORAGE_PATH %s state=MISSING_OR_UNREADABLE\n' "$storage_path"; continue; }
  if command -v findmnt >/dev/null 2>&1; then findmnt -T "$storage_path" -n -o TARGET,FSTYPE || true; fi
done
echo 'OBSERVATION active_configuration=UNVERIFIED storage_metadata=literal_host_paths_only image_contents=NOT_READ'
if [ "$partial" -eq 1 ]; then result PARTIAL; exit 2; fi
result OK; exit 0
