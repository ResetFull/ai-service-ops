#!/usr/bin/env bash
set -euo pipefail
action=${1:?}; sample_limit=200; found_roots=0
[ "$action" = image-layout ] || { echo 'RESULT QUERY_FAILED reason=INVALID_ACTION'; exit 1; }
printf 'SAMPLE time=%s timezone=%s host=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(date '+%Z')" "$(hostname)"
shift
[ "$#" -gt 0 ] || { echo 'RESULT NO_LOG reason=STORAGE_ROOTS_REQUIRED'; exit 2; }
for root in "$@"; do
  [[ "$root" = /* && "$root" != / && "$root" != *'/../'* && "$root" != */.. ]] || { echo 'RESULT QUERY_FAILED reason=INVALID_STORAGE_ROOT'; exit 1; }
  if [ ! -d "$root" ]; then printf 'STORAGE_ROOT %s state=MISSING_OR_UNREADABLE\n' "$root"; continue; fi
  found_roots=$((found_roots+1))
  printf 'STORAGE_ROOT %s\n' "$root"
  if command -v findmnt >/dev/null 2>&1; then findmnt -T "$root" -n -o TARGET,FSTYPE,SOURCE || true; fi
  # A bounded sample of names only; all names are reduced to structural classes.
  set +e
  sample=$(find "$root" -mindepth 1 -maxdepth 5 -printf '%y\t%P\n' | head -n "$((sample_limit+1))")
  scan_status=$?
  set -e
  if [ "$scan_status" -ne 0 ] && [ "$scan_status" -ne 141 ]; then echo 'RESULT PARTIAL reason=directory_scan_failed'; exit 2; fi
  printf '%s\n' "$sample" | awk -F '\t' -v limit="$sample_limit" '
    function segment(value, position, previous) {
      if(value ~ /^(19|20)[0-9][0-9]$/) return "YYYY"
      if(value ~ /^(19|20)[0-9]{2}-[0-9]{2}-[0-9]{2}$/) return "YYYY-MM-DD"
      if(value ~ /^(19|20)[0-9]{6}$/) return "YYYYMMDD"
      if(value ~ /^(19|20)[0-9]{4}$/) return "YYYYMM"
      if(value ~ /^[0-9]{2}$/ && previous == "YYYY") return "MM"
      if(value ~ /^[0-9]{2}$/ && previous == "MM") return "DD"
      if(tolower(value) ~ /^(upload|uploads|image|images|img|imgs|attachment|attachments|photo|photos|avatar|idcard|identity|temp|file|files|video|videos)$/) return tolower(value)
      if(value ~ /^[0-9]+$/) return "<numeric-directory>"
      return "<directory>"
    }
    function naming(value, bare) {
      bare=value; sub(/\.[^.]*$/,"",bare)
      if(bare ~ /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/) return "UUID-36"
      if(bare ~ /^[0-9a-fA-F]{32}$/) return "HEX-32"
      if(bare ~ /^[0-9]{13}$/) return "NUMERIC-13"
      if(bare ~ /^(19|20)[0-9]{12,15}$/) return "DATETIME-NUMERIC"
      if(bare ~ /^[0-9]+$/) return "NUMERIC"
      if(bare ~ /^[0-9a-fA-F-]{32,36}_[0-9]+$/) return "UUID_NUMERIC"
      if(bare ~ /_/) return "MIXED_WITH_UNDERSCORE"
      return "OTHER_NAME"
    }
    NR<=limit && NF>=2 {
      entries++; count=split($2,parts,"/"); shape=""; previous=""
      end=($1=="d"?count:count-1)
      for(i=1;i<=end;i++) {part=segment(parts[i],i,previous);shape=shape (i==1?"":"/") part;previous=part}
      if($1=="d") {directories[shape]++; next}
      if($1!="f") {other++; next}
      files++; if(shape=="")shape="<root>"
      file_extension=tolower(parts[count]); sub(/^.*\./,"",file_extension)
      if(file_extension !~ /^(jpg|jpeg|png|webp|gif|pdf|mp4|json|html|txt)$/)file_extension="other-or-none"
      layouts[shape " | " naming(parts[count]) " | extension=" file_extension]++
    }
    END {
      printf "SAMPLE_COUNTS entries=%d files=%d other=%d limit=%d truncated=%s\n",entries,files,other,limit,(NR>limit?"true":"false")
      for(key in directories)print "DIRECTORY_SHAPE",key,"sample_count=" directories[key]
      for(key in layouts)print "FILE_SHAPE",key,"sample_count=" layouts[key]
    }'
done
[ "$found_roots" -gt 0 ] || { echo 'RESULT NO_MATCH reason=storage_roots_missing'; exit 2; }
echo 'RESULT OK coverage=bounded_name_sample image_contents=NOT_READ filenames=NOT_EXPOSED timezone_of_folder_generation=UNVERIFIED'
