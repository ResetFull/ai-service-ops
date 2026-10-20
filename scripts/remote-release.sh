#!/usr/bin/env bash
# Fixed remote program. Every caller-supplied value is data in argv.
set -euo pipefail
action=${1:?}; kind=${2:?}; target=${3:?}; artifact=${4:?}; release=${5:-}; expected=${6:-}; upload=${7:-}; mode=${8:-}; url=${9:-}; token=${10:-}
fail(){ printf 'RESULT QUERY_FAILED reason=%s\n' "$*" >&2; exit 1; }
[[ "$kind" = jar || "$kind" = frontend ]] || fail INVALID_KIND
[[ "$target" = /* && "$target" != / && "$target" != *$'\n'* && "$target" != *'/../'* && "$target" != */.. ]] || fail INVALID_TARGET
[[ "$artifact" =~ ^[A-Za-z0-9._-]+$ && "$artifact" != . && "$artifact" != .. ]] || fail INVALID_ARTIFACT
[[ -z "$release" || "$release" =~ ^[0-9]{14}-[a-f0-9]{8}$ ]] || fail INVALID_RELEASE_ID
[[ -z "$expected" || "$expected" =~ ^[a-f0-9]{64}$ ]] || fail INVALID_HASH
[[ -z "$token" || "$token" =~ ^[A-Za-z0-9-]{1,100}$ ]] || fail INVALID_LOCK_TOKEN
parent=${target%/*}; name=${target##*/}; root="$parent/.service-ops-$name"; lock="$root/lock"
sha(){ if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
require_lock(){ [ -f "$lock/token" ] && [ "$(cat "$lock/token")" = "$token" ] || fail LOCK_NOT_OWNED; }
record(){ printf 'release_id\t%s\nartifact_sha256\t%s\nkind\t%s\n' "$release" "$expected" "$kind" > "$1"; }
value(){ awk -F '\t' -v key="$2" '$1==key{print $2}' "$1"; }
preflight(){
  command -v tar >/dev/null || fail MISSING_TAR
  command -v sha256sum >/dev/null || command -v shasum >/dev/null || fail MISSING_SHA256
  [ -d "$parent" ] || fail TARGET_PARENT_NOT_FOUND
  if [ "$kind" = frontend ]; then
    [ ! -e "$target" ] || [ -L "$target" ] || fail LAYOUT_MIGRATION_REQUIRED
    if [ -L "$target" ]; then case "$(readlink -f "$target")" in "$root/releases/"*/site) ;; *) fail UNMANAGED_SYMLINK_TARGET;; esac; fi
  else
    [ -d "$target" ] || fail JAR_DIRECTORY_NOT_FOUND
    [[ "$mode" = script || "$mode" = stopstart ]] || fail INVALID_RESTART_MODE
  fi
  if [ -n "$url" ]; then command -v curl >/dev/null || fail MISSING_CURL; [[ "$url" =~ ^https?:// ]] || fail INVALID_VERIFY_URL; fi
}
switch_frontend(){
  local destination="$1" link="$root/.switch-$token"
  [ ! -e "$target" ] || [ -L "$target" ] || fail LAYOUT_MIGRATION_REQUIRED
  [ ! -e "$link" ] && [ ! -L "$link" ] || fail SWITCH_ALREADY_EXISTS
  ln -s "$destination" "$link"
  [ -L "$link" ] || fail NATIVE_SYMLINK_REQUIRED
  if ! mv -Tf "$link" "$target"; then rm -f "$link"; fail SWITCH_FAILED; fi
}
exact_pid(){
  local entry pid word previous path="$target/$artifact" resolved matches=''
  resolved=$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")
  for entry in /proc/[0-9]*/cmdline; do
    [ -r "$entry" ] || continue
    pid=${entry%/cmdline}; pid=${pid##*/}; previous=''; local found=0 executable
    executable=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    case "${executable##*/}" in java|java.exe) ;; *) continue;; esac
    while IFS= read -r -d '' word; do
      if [ "$previous" = -jar ]; then
        case "$word" in /*) ;; *) word="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)/$word";; esac
        [ "$(readlink -f "$word" 2>/dev/null || printf '%s' "$word")" = "$resolved" ] && found=1
      fi
      previous=$word
    done < "$entry"
    if [ "$found" -eq 1 ]; then [ -z "$matches" ] || matches+=,; matches+="$pid"; fi
  done
  [ -n "$matches" ] || return 1
  [[ "$matches" != *,* ]] || { echo 'PROCESS: MULTIPLE_MATCHES' >&2; return 2; }
  printf '%s\n' "$matches"
}
process_identity(){
  local pid statline; pid=$(exact_pid) || return $?
  statline=$(cat "/proc/$pid/stat") || return 1
  printf '%s:%s\n' "$pid" "$(printf '%s' "${statline##*) }" | awk '{print $20}')"
}
activate_record(){
  if [ -f "$root/current.tsv" ]; then cp "$root/current.tsv" "$root/previous.tsv"; fi
  cp "$root/releases/$release/manifest.tsv" "$root/current.tsv.new"; mv -f "$root/current.tsv.new" "$root/current.tsv"
}
site_checksums(){
  local directory="$1"
  (cd "$directory/site" && find . -type f -print0 | sort -z | while IFS= read -r -d '' file; do
    if command -v sha256sum >/dev/null; then sha256sum "$file"; else shasum -a 256 "$file"; fi
  done) > "$directory/files.sha256"
}
check_site(){
  local directory="$1" actual saved
  [ -f "$directory/files.sha256" ] || fail FILE_MANIFEST_MISSING
  saved=$(wc -l < "$directory/files.sha256"); actual=$(find "$directory/site" -type f | wc -l); [ "$saved" -eq "$actual" ] || fail FRONTEND_FILE_COUNT_MISMATCH
  (cd "$directory/site" && if command -v sha256sum >/dev/null; then sha256sum -c "$directory/files.sha256" >/dev/null; else shasum -a 256 -c "$directory/files.sha256" >/dev/null; fi) || fail FRONTEND_FILE_HASH_MISMATCH
}
verify(){
  [ -n "$release" ] && [ -n "$expected" ] || fail VERIFY_RECORD_REQUIRED
  [ -n "$url" ] || fail VERIFY_INCOMPLETE_URL_REQUIRED
  [[ "$url" =~ ^https?:// && "$url" != *$'\n'* ]] || fail INVALID_VERIFY_URL
  command -v curl >/dev/null || fail MISSING_CURL
  local directory="$root/releases/$release" hash pid code body separator='?'
  [ -f "$directory/manifest.tsv" ] || fail RELEASE_NOT_FOUND
  [ "$(value "$directory/manifest.tsv" artifact_sha256)" = "$expected" ] || fail RECORD_HASH_MISMATCH
  if [ "$kind" = frontend ]; then
    [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$directory/site")" ] || fail ACTIVE_RELEASE_MISMATCH
    [ -f "$target/index.html" ] && [ "$(cat "$target/service-ops-release.txt")" = "$release" ] || fail FRONTEND_VERSION_MISMATCH
    [ "$(sha "$directory/artifact.tar.gz")" = "$expected" ] || fail REMOTE_HASH_MISMATCH
    check_site "$directory"
    local base=${url%%\?*}; base=${base%index.html}; base=${base%/}
    body=$(curl --fail --silent --show-error --max-time 15 "$base/service-ops-release.txt?_service_ops=$release") || fail FRONTEND_HTTP_FAILED
    [ "$body" = "$release" ] || fail FRONTEND_HTTP_VERSION_MISMATCH
  else
    [ -f "$target/$artifact" ] || fail JAR_NOT_FOUND
    hash=$(sha "$target/$artifact"); [ "$hash" = "$expected" ] || fail REMOTE_HASH_MISMATCH
    pid=''; for ((attempt=0;attempt<30;attempt++)); do pid=$(exact_pid || true); [ -z "$pid" ] || break; sleep 1; done
    [ -n "$pid" ] || fail PROCESS_DOWN
    [ -f "$root/runtime.tsv" ] || fail RUNTIME_VERSION_UNVERIFIED
    [ "$(value "$root/runtime.tsv" release_id)" = "$release" ] && [ "$(value "$root/runtime.tsv" process_identity)" = "$(process_identity)" ] || fail RUNTIME_VERSION_MISMATCH
    [[ "$url" != *\?* ]] || separator='&'
    code=$(curl --silent --show-error --max-time 15 -o /dev/null -w '%{http_code}' "$url${separator}_service_ops=$release") || fail READINESS_HTTP_FAILED
    [ "$code" = 200 ] || fail "READINESS_HTTP_$code"
    printf 'PROCESS pid=%s artifact=%s sha256=%s\n' "$pid" "$target/$artifact" "$hash"
  fi
  printf 'RESULT OK release_id=%s\n' "$release"
}
case "$action" in
  preflight) preflight; printf 'RESULT OK preflight\n';;
  acquire)
    preflight; [ -n "$token" ] || fail LOCK_TOKEN_REQUIRED; mkdir -p "$root"
    if ! mkdir "$lock" 2>/dev/null; then fail "LOCKED owner=$(cat "$lock/token" 2>/dev/null || echo unknown)"; fi
    printf '%s\n' "$token" > "$lock/token"; date +%s > "$lock/created_at"; printf 'RESULT OK lock=%s\n' "$token";;
  release) require_lock; rm -f "$lock/token" "$lock/created_at"; rmdir "$lock"; printf 'RESULT OK released\n';;
  inspect)
    [ -f "$root/current.tsv" ] || fail NO_MANAGED_RELEASE
    current=$(value "$root/current.tsv" release_id); hash=$(value "$root/current.tsv" artifact_sha256)
    if [ "$kind" = frontend ]; then
      [ "$(readlink -f "$target")" = "$(readlink -f "$root/releases/$current/site")" ] || fail ACTIVE_RELEASE_MISMATCH
      [ "$(sha "$root/releases/$current/artifact.tar.gz")" = "$hash" ] || fail REMOTE_HASH_MISMATCH
      check_site "$root/releases/$current"
    else [ -f "$target/$artifact" ] && [ "$(sha "$target/$artifact")" = "$hash" ] || fail ACTIVE_RELEASE_MISMATCH; fi
    printf 'CURRENT release_id=%s artifact_sha256=%s\n' "$current" "$hash"
    if [ -f "$root/previous.tsv" ]; then printf 'PREVIOUS release_id=%s artifact_sha256=%s\n' "$(value "$root/previous.tsv" release_id)" "$(value "$root/previous.tsv" artifact_sha256)"; fi
    echo 'RESULT OK release_status=artifact';;
  install)
    require_lock; preflight
    [ -n "$release" ] && [ -n "$expected" ] && [ -f "$upload" ] || fail UPLOAD_RECORD_REQUIRED
    [ "$(sha "$upload")" = "$expected" ] || fail UPLOAD_HASH_MISMATCH
    mkdir -p "$root/releases"; directory="$root/releases/$release"; [ ! -e "$directory" ] || fail RELEASE_ALREADY_EXISTS
    stage="$root/.staging-$release-$token"; [ ! -e "$stage" ] || fail STAGING_ALREADY_EXISTS; mkdir "$stage"
    if [ "$kind" = frontend ]; then
      mkdir "$stage/site"
      tar -tvzf "$upload" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d"{bad=1}END{exit bad}' || fail UNSAFE_ARCHIVE_TYPE
      while IFS= read -r item; do [[ "$item" != /* && "$item" != ../* && "$item" != *'/../'* ]] || fail UNSAFE_ARCHIVE; done < <(tar -tzf "$upload")
      tar -xzf "$upload" -C "$stage/site" --no-same-owner
      [ -f "$stage/site/index.html" ] && [ "$(cat "$stage/site/service-ops-release.txt")" = "$release" ] || fail INVALID_FRONTEND_ARTIFACT
      [ -z "$(find "$stage/site" -type l -print -quit)" ] || fail ARCHIVE_SYMLINK_FORBIDDEN
      cp "$upload" "$stage/artifact.tar.gz"; record "$stage/manifest.tsv"; site_checksums "$stage"; mv "$stage" "$directory"
      switch_frontend "$directory/site"
    else
      process_identity > "$stage/previous_process" 2>/dev/null || true
      cp "$upload" "$stage/artifact.jar"; record "$stage/manifest.tsv"; mv "$stage" "$directory"
      if [ -f "$target/$artifact" ]; then cp "$target/$artifact" "$directory/previous.jar"; fi
      cp "$directory/artifact.jar" "$target/.$artifact.$token.new"; mv -f "$target/.$artifact.$token.new" "$target/$artifact"
    fi
    activate_record
    rm -f "$upload"; printf 'RESULT OK installed=%s sha256=%s\n' "$release" "$expected";;
  restart)
    require_lock
    if [ "$kind" = frontend ]; then printf 'RESULT OK restart=none\n'; exit 0; fi
    [ -f "$target/$artifact" ] || fail JAR_NOT_FOUND
    before=''; before_code=0; before=$(process_identity) || before_code=$?
    [ "$before_code" -ne 2 ] || fail MULTIPLE_JAR_PROCESSES
    case "$mode" in script) (cd "$target" && bash restart.sh) || fail RESTART_FAILED;; stopstart) (cd "$target" && bash stop.sh && sleep 1 && bash start.sh) || fail RESTART_FAILED;; *) fail INVALID_RESTART_MODE;; esac
    identity=''; for ((attempt=0;attempt<30;attempt++)); do identity=$(process_identity || true); [ -n "$identity" ] && [ "$identity" != "$before" ] && break; sleep 1; done
    [ -n "$identity" ] || fail PROCESS_DOWN
    [ "$identity" != "$before" ] || fail PROCESS_NOT_RESTARTED
    if [ -z "$release" ] && [ -f "$root/current.tsv" ]; then release=$(value "$root/current.tsv" release_id); fi
    printf 'release_id\t%s\nprocess_identity\t%s\n' "$release" "$identity" > "$root/runtime.tsv"
    printf 'RESULT OK restarted\n';;
  verify) verify;;
  rollback)
    require_lock; directory="$root/releases/$release"; [ -f "$directory/manifest.tsv" ] || fail RELEASE_NOT_FOUND
    [ "$(value "$directory/manifest.tsv" artifact_sha256)" = "$expected" ] || fail RECORD_HASH_MISMATCH
    if [ "$kind" = frontend ]; then
      [ "$(sha "$directory/artifact.tar.gz")" = "$expected" ] || fail REMOTE_HASH_MISMATCH
      check_site "$directory"
      switch_frontend "$directory/site"
    else
      [ "$(sha "$directory/artifact.jar")" = "$expected" ] || fail REMOTE_HASH_MISMATCH
      cp "$directory/artifact.jar" "$target/.$artifact.$token.new"; mv -f "$target/.$artifact.$token.new" "$target/$artifact"
    fi
    activate_record
    printf 'RESULT OK restored=%s verification_required=true\n' "$release";;
  *) fail INVALID_ACTION;;
esac
