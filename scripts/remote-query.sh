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
case "$action" in
  status) output=$(ps -eo pid,pcpu,pmem,etime,args | grep -F -- "$service" | grep -v 'grep -F' | head -n "$count" || true); [ -z "$output" ] || printf '%s\n' "$output"; [ -z "$output" ] && echo 'RESULT NO_MATCH observation=process' || echo 'RESULT OK observation=process'; exit 0;;
  ps) ps -eo pid,pcpu,pmem,etime,args | awk 'NR==1 || /[j]ava/' | head -n "$maxlines"; printf 'RESULT OK\n'; exit 0;;
  disk) df -h; printf 'RESULT OK\n'; exit 0;;
  mem) free -m; printf 'RESULT OK\n'; exit 0;;
  top) top -bn1 | head -n 25 || { code=$?; [ "$code" -eq 141 ] || fail TOP_FAILED; }; printf 'RESULT OK\n'; exit 0;;
  services) find /opt -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n "$maxlines"; printf 'RESULT OK\n'; exit 0;;
  net) ss -tln; ss -tn | awk 'NR>1 {print $1,$5}' | head -n "$maxlines"; printf 'RESULT OK\n'; exit 0;;
  jvm) output=$(ps -eo pid,pcpu,pmem,etime,args | awk 'NR==1 || /[j]ava/' | { if [ -n "$pattern" ]; then grep -F -- "$pattern" || true; else cat; fi; } | head -n 30); [ -z "$output" ] || printf '%s\n' "$output"; [ -z "$output" ] && echo 'RESULT NO_MATCH' || echo 'RESULT OK'; exit 0;;
esac
[ -d "$directory" ] || { echo 'RESULT NO_LOG reason=directory_missing'; exit 2; }
files=(); partial=0; readbytes=0; outputlines=0; discovered=0
while IFS= read -r -d '' file; do
  base=${file##*/}; include=0
  case "$base" in $glob) include=1;; esac
  case "$base" in $glob.*) include=1;; esac
  if [ -n "$day" ] && [ "$action" != nginx-stats ]; then
    dashed="${day:0:4}-${day:4:2}-${day:6:2}"
    [[ "$base" = *"$day"* || "$base" = *"$dashed"* ]] || include=0
  fi
  [ "$include" -eq 1 ] || continue
  discovered=$((discovered+1))
  case "$base" in *.gz|*.bz2|*.xz|*.zip) partial=1; printf 'SKIPPED file=%s reason=compressed\n' "$file"; continue;; esac
  if [ "${#files[@]}" -ge "$maxfiles" ]; then partial=1; continue; fi
  files+=("$file")
done < <(find "$directory" -maxdepth 1 -type f -printf '%T@ %p\0' | sort -z -nr | while IFS= read -r -d '' entry; do printf '%s\0' "${entry#* }"; done)
[ "${#files[@]}" -gt 0 ] || { if [ "$partial" -eq 1 ]; then result PARTIAL; else result NO_LOG; fi; exit 2; }
if [ "$action" = logfiles ]; then
  for file in "${files[@]}"; do stat -c 'FILE %n size=%s modified=%y' "$file" || fail STAT_FAILED; done
  [ "$partial" -eq 0 ] && result OK || { result PARTIAL; exit 2; }; exit 0
fi
filter(){
  case "$action" in
    logs) tail -n "$count";;
    trace) grep -F -- "$pattern" || { code=$?; [ "$code" -eq 1 ] || exit "$code"; };;
    logsrange)
      awk -v s="$start" -v e="$end" '
        /^\[?[0-9]{4}-[0-9]{2}-[0-9]{2}/ {ts=$0; sub(/^\[/,"",ts); ts=substr(ts,1,19); inside=(ts>=s && ts<=e)}
        inside {print}' |
      { if [ -n "$pattern" ]; then grep -iE -- "$pattern" || { code=$?; [ "$code" -eq 1 ] || exit "$code"; }; else cat; fi; };;
    nginx-stats)
      awk -v day="$day" 'BEGIN {split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec",m," "); if(day!="")needle=substr(day,7,2)"/"m[substr(day,5,2)+0]"/"substr(day,1,4)}
        day=="" || index($4,needle) {path=$7; sub(/\?.*/,"",path); status[$9]++; url[$9" "path]++}
        END {for(s in status)print "STATUS",s,status[s]; for(u in url)print "URL",u,url[u]}' | sort -rn -k3;;
    *) grep -iE -C "$context" -- "$pattern" || { code=$?; [ "$code" -eq 1 ] || exit "$code"; };;
  esac
}
for file in "${files[@]}"; do stat -c 'FILE %n size=%s modified=%y' "$file" || fail STAT_FAILED; done
if [ "$action" = health ]; then
  ps -eo pid,pcpu,pmem,etime,args | grep -F -- "$service" | grep -v 'grep -F' | head -n 10 || true
  pattern='ERROR|WARN|Exception|Caused by:'
fi
matched=0
for file in "${files[@]}"; do
  remaining=$((budget-readbytes)); [ "$remaining" -gt 0 ] && [ "$outputlines" -lt "$maxlines" ] || { partial=1; break; }
  size=$(stat -c '%s' "$file") || fail STAT_FAILED
  bytes=$size; if [ "$bytes" -gt "$remaining" ]; then bytes=$remaining; partial=1; fi
  readbytes=$((readbytes+bytes))
  output=$(tail -c "$bytes" "$file" | filter) || fail FILTER_FAILED
  [ -n "$output" ] || continue
  matched=1
  lines=$(printf '%s\n' "$output" | wc -l); limit=$count; remaininglines=$((maxlines-outputlines)); [ "$limit" -le "$remaininglines" ] || limit=$remaininglines
  [ "$action" = count ] || [ "$lines" -le "$limit" ] || partial=1
  if [ "$action" = count ]; then printf 'COUNT file=%s count=%s bounded=true\n' "$file" "$lines"; outputlines=$((outputlines+1)); else printf '%s\n' "$output" | tail -n "$limit"; emitted=$lines; [ "$emitted" -le "$limit" ] || emitted=$limit; outputlines=$((outputlines+emitted)); fi
done
if [ "$partial" -eq 1 ]; then result PARTIAL; exit 2; fi
if [ "$matched" -eq 0 ]; then result NO_MATCH; else result OK; fi
