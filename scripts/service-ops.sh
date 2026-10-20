#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_DIR="$PLUGIN_ROOT/config"
WS="${SERVICE_OPS_WS:-${SERVER_OPS_WS:-}}"
STATE_DIR="${SERVICE_OPS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ai-service-ops}"
if [[ "${OSTYPE:-}" = msys* ]]; then STATE_DIR="${SERVICE_OPS_STATE_DIR:-${LOCALAPPDATA:?LOCALAPPDATA required}/ai-service-ops}"; STATE_DIR=$(cygpath -u "$STATE_DIR"); fi
QUERY_TIMEOUT="${SERVICE_OPS_QUERY_TIMEOUT_SECONDS:-20}"
QUERY_BYTES="${SERVICE_OPS_QUERY_MAX_BYTES:-16777216}"
QUERY_FILES="${SERVICE_OPS_QUERY_MAX_FILES:-20}"
QUERY_LINES="${SERVICE_OPS_QUERY_MAX_LINES:-2000}"
log(){ printf '>> %s\n' "$*"; }
die(){ printf 'RESULT QUERY_FAILED reason=%s\n' "$*" >&2; exit 1; }
assert_task_config(){
  [ -z "${SERVICE_OPS_CONFIG_FINGERPRINT:-}" ] || "${SERVICE_OPS_PYTHON:?}" "$PLUGIN_ROOT/scripts/task_runtime.py" check-config "$SERVICE_OPS_TASK_SCOPE" "$SERVICE_OPS_CONFIG_FINGERPRINT" || die CONFIG_CHANGED
}
task_event(){
  [ "${SERVICE_OPS_TASK_EVENTS:-}" = 1 ] || return 0
  "$SERVICE_OPS_PYTHON" "$PLUGIN_ROOT/scripts/task_events.py" "$1" "$2" "${RELEASE_ID:-}" "${ARTIFACT_SHA:-}" || {
    REMOTE_WRITE_UNKNOWN=1; printf 'RESULT UNKNOWN reason=EVENT_CHANNEL_FAILED\n' >&2; return 75;
  }
}
init_python(){
  [ -z "${SERVICE_OPS_PYTHON:-}" ] || return 0
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then export SERVICE_OPS_PYTHON=$candidate; return 0; fi
  done
  die PYTHON_3_10_REQUIRED
}
init_config(){
  CONF_DIR=$("$SERVICE_OPS_PYTHON" "$PLUGIN_ROOT/scripts/ops_config.py" resolve --root "$PLUGIN_ROOT") || die CONFIG_DIRECTORY_UNAVAILABLE
  if [[ "${OSTYPE:-}" = msys* ]]; then CONF_DIR=$(cygpath -u "$CONF_DIR"); export SERVICE_OPS_CONFIG_DIR; SERVICE_OPS_CONFIG_DIR=$(cygpath -w "$CONF_DIR")
  else export SERVICE_OPS_CONFIG_DIR="$CONF_DIR"; fi
}
ops_setting(){ "$SERVICE_OPS_PYTHON" "$PLUGIN_ROOT/scripts/ops_config.py" value "$1" --dir "$CONF_DIR"; }
identifier(){ [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$ ]] || die INVALID_IDENTIFIER; }
number(){ [[ "$1" =~ ^[0-9]{1,9}$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ] || die INVALID_NUMBER; }
number "$QUERY_TIMEOUT" 1 120; number "$QUERY_BYTES" 1 268435456; number "$QUERY_FILES" 1 100; number "$QUERY_LINES" 1 10000
validate_date(){
  [ -n "${1:-}" ] || return 0
  [[ "$1" =~ ^[0-9]{8}$ ]] || die INVALID_DATE
  local normalized; normalized=$(date -d "${1:0:4}-${1:4:2}-${1:6:2}" +%Y%m%d 2>/dev/null || date -j -f '%Y%m%d' "$1" '+%Y%m%d' 2>/dev/null || true)
  [ "$normalized" = "$1" ] || die INVALID_DATE
}
validate_time(){
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || die INVALID_TIME
  validate_date "${1:0:4}${1:5:2}${1:8:2}"
  [ "${1:11:2}" -le 23 ] && [ "${1:14:2}" -le 59 ] && [ "${1:17:2}" -le 59 ] || die INVALID_TIME
}
release_id(){ [[ "$1" =~ ^[0-9]{14}-[a-f0-9]{8}$ ]] || die INVALID_RELEASE_ID; }
config(){ [ -f "$1" ] || die CONFIG_MISSING; awk 'NF && $0 !~ /^[[:space:]]*#/ {sub(/\r$/,""); print}' "$1"; }
scope_name(){
  case "$1" in dev|test|prod|overseas-dev|overseas-test|overseas-prod) printf '%s\n' "$1";;domestic-dev|domestic-test|domestic-prod) printf '%s\n' "${1#domestic-}";;*) die INVALID_SCOPE;;esac
}
assert_scope_action(){
  if [[ "$ENV_NAME" != *prod ]]; then
    case "$ACTION" in build|upload|restart|rollback|all|exec)
      "$SERVICE_OPS_PYTHON" "$PLUGIN_ROOT/scripts/ops_config.py" policy "$ENV_NAME" "$ACTION" --dir "$CONF_DIR" || die WRITES_DISABLED;;
    esac
    return 0
  fi
  case "$TARGET_NAME" in groups|list|servers|all-disk|all-ps|trace|nginx-stats) return 0;;doctor) [[ -z "$ACTION" || "$ACTION" = query ]] && return 0;;*)
    case "$ACTION" in ''|status|health|logs|grep|grepall|backupgrep|logsrange|count|logfiles|ps|disk|mem|top|services|net|jvm|nginx-config|image-layout) return 0;;esac;;esac
  die PROD_READ_ONLY
}
assert_nonproduction_target(){
  local file name host user auth lan description
  for file in "$CONF_DIR"/servers-*prod.conf; do
    [ -f "$file" ] || continue
    while IFS='|' read -r name host user auth lan description; do
      [ -n "$host" ] || continue
      if [[ "$SRV_HOST" = "$host" || ( -n "$lan" && "$SRV_HOST" = "$lan" ) || ( -n "$SRV_LAN" && ( "$SRV_LAN" = "$host" || ( -n "$lan" && "$SRV_LAN" = "$lan" ) ) ) ]]; then die PROD_TARGET_READ_ONLY; fi
    done < <(config "$file")
  done
}
lookup(){
  identifier "$2"; local rows count; rows=$(config "$1" | awk -F '|' -v key="$2" '$1==key'); count=$(printf '%s\n' "$rows" | awk 'NF{n++}END{print n+0}')
  [ "$count" -eq 1 ] || die "CONFIG_LOOKUP name=$2 matches=$count"; printf '%s\n' "$rows"
}
load_server(){
  local row; row=$(lookup "$CONF_DIR/servers-$1.conf" "$2")
  IFS='|' read -r SRV_NAME SRV_HOST SRV_USER SRV_KEY SRV_LAN SRV_DESC <<< "$row"
  [ -n "$SRV_HOST" ] || die "HOST_ADDRESS_PENDING server=$SRV_NAME"
  [ -n "$SRV_USER" ] && [ -n "$SRV_KEY" ] || die "AUTHENTICATION_PENDING server=$SRV_NAME"
  [[ "$SRV_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ && "$SRV_USER" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] || die INVALID_SSH_CONFIG
  if [[ "$SRV_KEY" = password:* ]]; then
    local profile=${SRV_KEY#password:} variable
    [[ "$profile" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || die INVALID_PASSWORD_PROFILE
    variable="SERVICE_OPS_PASSWORD_$profile"; [ -n "${!variable:-}" ] || die "CREDENTIAL_MISSING variable=$variable; Windows DPAPI credentials require PowerShell"
  else
    SRV_KEY="${SRV_KEY/#\~/$HOME}"; [ -f "$SRV_KEY" ] || die "KEY_MISSING server=$SRV_NAME"
  fi
}
load_service(){
  local row; row=$(lookup "$CONF_DIR/services-$1.conf" "$2")
  IFS='|' read -r SVC_NAME SVC_SERVERS SVC_LOGDIR_TPL SVC_LOGGLOB SVC_DESC SVC_REPO SVC_MODULE SVC_DIR SVC_ARTIFACT SVC_DEPLOY_MODE SVC_KIND SVC_VERIFY_URL SVC_PACKAGE_MANAGER <<< "$row"
  SVC_KIND="${SVC_KIND:-jar}"; [[ "$SVC_KIND" = jar || "$SVC_KIND" = frontend ]] || die INVALID_SERVICE_KIND
  [[ "$SVC_LOGGLOB" != */* && "$SVC_LOGGLOB" != *$'\n'* ]] || die INVALID_LOG_GLOB
  IFS=',' read -ra SERVERS <<< "$SVC_SERVERS"; [ "${#SERVERS[@]}" -gt 0 ] || die EMPTY_SERVER_LIST
  for ref in "${SERVERS[@]}"; do identifier "$ref"; done
}
server_member(){
  [ -n "${1:-}" ] || return 0; identifier "$1"
  local ref; for ref in "${SERVERS[@]}"; do [ "$ref" != "$1" ] || return 0; done
  die "SERVER_NOT_CONFIGURED_FOR_SERVICE server=$1 service=$SVC_NAME"
}
quote(){ local value="${1//\'/\'\\\'\'}"; printf "'%s'" "$value"; }
redact(){ sed -E 's/([aA][uU][tT][hH][oO][rR][iI][zZ][aA][tT][iI][oO][nN]:[[:space:]]*[bB][eE][aA][rR][eE][rR][[:space:]]+)[^[:space:]]+/\1[REDACTED]/g; s/("([pP][aA][sS][sS][wW][oO][rR][dD]|[pP][aA][sS][sS][wW][dD]|[tT][oO][kK][eE][nN]|[sS][eE][cC][rR][eE][tT]|[aA][uU][tT][hH][oO][rR][iI][zZ][aA][tT][iI][oO][nN]|[cC][aA][rR][dD][nN][oO]|[bB][aA][nN][kK][cC][aA][rR][dD]|[aA][cC][cC][oO][uU][nN][tT][nN][oO])"[[:space:]]*:[[:space:]]*")([^"\\]|\\.)*/\1[REDACTED]/g; s/(([pP][aA][sS][sS][wW][oO][rR][dD]|[pP][aA][sS][sS][wW][dD]|[tT][oO][kK][eE][nN]|[sS][eE][cC][rR][eE][tT]|[aA][uU][tT][hH][oO][rR][iI][zZ][aA][tT][iI][oO][nN]|[cC][aA][rR][dD][nN][oO]|[bB][aA][nN][kK][cC][aA][rR][dD]|[aA][cC][cC][oO][uU][nN][tT][nN][oO])[=:][[:space:]]*)[^[:space:],}]+/\1[REDACTED]/g; s#([hH][tT][tT][pP][sS]?://[^?[:space:]"<>]+)\?[^[:space:]"<>]*#\1?[REDACTED-QUERY]#g; s/(^|[^[:alnum:]])[0-9]{17}[0-9Xx]([^[:alnum:]]|$)/\1[REDACTED-ID]\2/g; s/(^|[^[:alnum:]])1[3-9][0-9]{9}([^[:alnum:]]|$)/\1[REDACTED-PHONE]\2/g'; }
prepare_ssh_auth(){
  SSH_OPTIONS=(-o StrictHostKeyChecking=yes -o ConnectTimeout=15)
  if [[ "$SRV_KEY" = password:* ]]; then
    local profile=${SRV_KEY#password:} variable
    [[ "$profile" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || die INVALID_PASSWORD_PROFILE
    variable="SERVICE_OPS_PASSWORD_$profile"
    [ -n "${!variable:-}" ] || die "CREDENTIAL_MISSING variable=$variable"
    ASKPASS_FILE=$(mktemp)
    printf '%s\n' '#!/bin/sh' 'printf '\''%s\n'\'' "$SERVICE_OPS_SSH_PASSWORD"' > "$ASKPASS_FILE"
    chmod 700 "$ASKPASS_FILE"
    export SSH_ASKPASS="$ASKPASS_FILE" SSH_ASKPASS_REQUIRE=force SERVICE_OPS_SSH_PASSWORD="${!variable}"
    SSH_OPTIONS+=(-o BatchMode=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=1)
  else
    SSH_OPTIONS+=(-o BatchMode=yes -i "$SRV_KEY")
  fi
}
ssh_program()(
  assert_task_config
  local program="$1" seconds="$2"; shift 2
  local command='bash -s --' value error code=0
  for value in "$@"; do command+=" $(quote "$value")"; done
  [ "$seconds" -eq 0 ] || command="command -v timeout >/dev/null || { echo 'RESULT QUERY_FAILED reason=MISSING_REMOTE_DEADLINE'; exit 1; }; timeout ${seconds}s $command"
  error=$(mktemp)
  local ASKPASS_FILE=''; trap 'rm -f -- "$error"; [ -z "$ASKPASS_FILE" ] || rm -f -- "$ASKPASS_FILE"' EXIT
  prepare_ssh_auth
  if command -v timeout >/dev/null && [ "$seconds" -gt 0 ]; then
    timeout "$((seconds+5))s" ssh "${SSH_OPTIONS[@]}" "$SRV_USER@$SRV_HOST" "$command" < "$program" 2> "$error" | redact || code=$?
  else
    ssh "${SSH_OPTIONS[@]}" "$SRV_USER@$SRV_HOST" "$command" < "$program" 2> "$error" | redact || code=$?
  fi
  if [ -s "$error" ]; then redact < "$error" >&2; fi; rm -f "$error"
  if [ "${SERVICE_OPS_REMOTE_MUTATION:-}" = 1 ] && { [ "$code" -eq 124 ] || [ "$code" -eq 137 ] || [ "$code" -eq 255 ]; }; then
    printf 'RESULT UNKNOWN server=%s exit=%s inspect_before_retry=true\n' "$SRV_NAME" "$code" >&2; code=75
  elif [ "$code" -eq 255 ]; then printf 'RESULT SSH_FAILED server=%s\n' "$SRV_NAME" >&2
  elif [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; then printf 'RESULT PARTIAL reason=DEADLINE server=%s\n' "$SRV_NAME" >&2; code=2
  elif [ "$code" -ne 0 ] && [ "$code" -ne 2 ]; then printf 'RESULT QUERY_FAILED server=%s exit=%s\n' "$SRV_NAME" "$code" >&2; fi
  return "$code"
)
scp_put()(
  assert_task_config
  local error code=0; error=$(mktemp)
  local ASKPASS_FILE=''; trap 'rm -f -- "$error"; [ -z "$ASKPASS_FILE" ] || rm -f -- "$ASKPASS_FILE"' EXIT
  prepare_ssh_auth
  local runner=(); if command -v timeout >/dev/null; then runner=(timeout 600s); fi
  # OpenSSH 9+ 默认 SFTP 协议不经远端 shell，引号会被当作字面量；改为白名单校验后原样传递
  [[ "$2" =~ ^/[A-Za-z0-9._/-]+$ ]] || { rm -f "$error"; die INVALID_REMOTE_UPLOAD_PATH; }
  "${runner[@]}" scp "${SSH_OPTIONS[@]}" -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$1" "$SRV_USER@$SRV_HOST:$2" 2> "$error" || code=$?
  [ ! -s "$error" ] || redact < "$error" >&2; rm -f "$error"
  if [ "$code" -eq 124 ] || [ "$code" -eq 137 ] || [ "$code" -eq 255 ]; then printf 'RESULT UNKNOWN action=scp server=%s exit=%s\n' "$SRV_NAME" "$code" >&2; return 75; fi
  [ "$code" -eq 0 ] || { printf 'RESULT SSH_FAILED action=scp server=%s exit=%s\n' "$SRV_NAME" "$code" >&2; return "$code"; }
)
query_node(){
  local action="$1" server="$2" pattern="${3:-}" count="${4:-200}" day="${5:-}" context="${6:-0}" start="${7:-}" end="${8:-}" directory
  number "$count" 1 10000; number "$context" 0 100; validate_date "$day"; load_server "$ENV_NAME" "$server"
  directory="${SVC_LOGDIR_TPL//\{svc\}/$SVC_NAME}"; directory="${directory//\{host\}/$SRV_LAN}"
  if [ "$action" = backupgrep ]; then
    directory=$(ops_setting backup_log_dir); [ -n "$directory" ] || die BACKUP_DIRECTORY_REQUIRED
    directory="${directory//\{svc\}/$SVC_NAME}"; directory="${directory//\{host\}/$SRV_LAN}"
  fi
  printf 'EVIDENCE env=%s service=%s server=%s directory=%s window=%s..%s\n' "$ENV_NAME" "$SVC_NAME" "$server" "$directory" "$start" "$end"
  ssh_program "$PLUGIN_ROOT/scripts/remote-query.sh" "$QUERY_TIMEOUT" "$action" "$SVC_NAME" "$directory" "$SVC_LOGGLOB" "$day" "$pattern" "$count" "$context" "$start" "$end" "$QUERY_BYTES" "$QUERY_FILES" "$QUERY_LINES" | redact
}
query_service(){
  local action="$1" filter="$2" pattern="$3" count="$4" day="$5" context="$6" start="${7:-}" end="${8:-}" code=0 node status
  server_member "$filter"
  for node in "${SERVERS[@]}"; do
    [ -z "$filter" ] || [ "$node" = "$filter" ] || continue
    status=0; query_node "$action" "$node" "$pattern" "$count" "$day" "$context" "$start" "$end" || status=$?
    [ "$status" -eq 0 ] || code="$status"
  done
  return "$code"
}
sha(){ if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
repo_path(){
  [ -n "$WS" ] && [ -d "$WS" ] || die WORKSPACE_REQUIRED
  [[ "$SVC_REPO" != /* && "$SVC_REPO" != .. && "$SVC_REPO" != ../* && "$SVC_REPO" != *'/../'* ]] || die INVALID_REPO
  REPO_PATH="$(cd "$WS/$SVC_REPO" && pwd)" || die REPO_NOT_FOUND
  local top current; top=$(git -C "$REPO_PATH" rev-parse --show-toplevel); current="$REPO_PATH"
  if command -v cygpath >/dev/null; then top=$(cygpath -m "$top"); current=$(cygpath -m "$REPO_PATH"); fi
  # monorepo 下 repo 可指向 Git 根内的子目录（如 example-plus），但不得跳出 Git 根
  [ "$top" = "$current" ] || [[ "$current" == "$top"/* ]] || die REPO_ROOT_REQUIRED; REPO_PATH="$current"
}
source_info(){
  COMMIT=$(git -C "$REPO_PATH" rev-parse HEAD); BRANCH=$(git -C "$REPO_PATH" symbolic-ref --quiet --short HEAD || echo DETACHED)
  SOURCE_STATUS=$(git -C "$REPO_PATH" -c core.quotePath=false status --porcelain=v1 --untracked-files=all); DIRTY=clean; [ -z "$SOURCE_STATUS" ] || DIRTY=dirty
  local content diff file hashes='' separator='' fpfile
  diff=$(git -C "$REPO_PATH" -c core.quotePath=false diff --binary HEAD --)
  while IFS= read -r -d '' file; do
    [ -f "$REPO_PATH/$file" ] && [ ! -L "$REPO_PATH/$file" ] || die UNSUPPORTED_UNTRACKED_FILE
    hashes+="$separator$file=$(sha "$REPO_PATH/$file" | tr 'a-f' 'A-F')"; separator='|'
  done < <(git -C "$REPO_PATH" -c core.quotePath=false ls-files --others --exclude-standard -z)
  fpfile=$(mktemp); printf '%s%s%s' "$SOURCE_STATUS" "$diff" "$hashes" > "$fpfile"; SOURCE_FINGERPRINT=$(sha "$fpfile"); rm -f "$fpfile"
}
deploy_config(){
  [[ "$ENV_NAME" = test || "$ENV_NAME" = overseas-test ]] || die PROD_WRITE_FORBIDDEN
  [ "${#SERVERS[@]}" -eq 1 ] || die MULTI_NODE_DEPLOY_UNSUPPORTED
  [ -n "$SVC_REPO" ] && [ -n "$SVC_DIR" ] && [ -n "$SVC_ARTIFACT" ] || die DEPLOY_CONFIG_REQUIRED
  [[ -z "$SVC_MODULE" || "$SVC_MODULE" =~ ^[A-Za-z0-9][A-Za-z0-9_./-]*$ ]] || die INVALID_MODULE
  [[ ! "$SVC_MODULE" =~ (^|/)\.\.?(/|$) ]] || die INVALID_MODULE
  [[ "$SVC_DIR" = /* && "$SVC_DIR" != / && "$SVC_DIR" != *'/../'* ]] || die INVALID_DEPLOY_TARGET; identifier "$SVC_ARTIFACT"
  load_server "$ENV_NAME" "${SERVERS[0]}"; assert_nonproduction_target; SERVICE_STATE="$STATE_DIR/$ENV_NAME/$SVC_NAME"
  TARGET="$SRV_NAME:$SVC_DIR"; [ "$SVC_KIND" != jar ] || TARGET+="/$SVC_ARTIFACT"
}
remote(){
  local action="$1" mutation=0 code=0
  case "$action" in acquire|release|install|restart|rollback) mutation=1;;esac
  task_event "$action" started
  SERVICE_OPS_REMOTE_MUTATION=$mutation ssh_program "$PLUGIN_ROOT/scripts/remote-release.sh" 120 "$action" "$SVC_KIND" "$SVC_DIR" "$SVC_ARTIFACT" "${RELEASE_ID:-}" "${ARTIFACT_SHA:-}" "${REMOTE_UPLOAD:-}" "$SVC_DEPLOY_MODE" "$SVC_VERIFY_URL" "${LOCK_TOKEN:-}" || code=$?
  if [ "$code" -eq 75 ]; then REMOTE_WRITE_UNKNOWN=1; task_event "$action" unknown
  elif [ "$code" -ne 0 ]; then task_event "$action" failed
  else task_event "$action" completed; fi
  return "$code"
}
manifest_get(){
  local count; count=$(awk -F '\t' -v key="$2" '$1==key{n++}END{print n+0}' "$1"); [ "$count" -eq 1 ] || die "INVALID_MANIFEST key=$2"
  awk -F '\t' -v key="$2" '$1==key{print $2}' "$1"
}
manifest_load(){
  local file="$1"; [ -f "$file" ] || die BUILD_RECORD_REQUIRED
  [ "$(manifest_get "$file" format)" = 1 ] && [ "$(manifest_get "$file" env)" = "$ENV_NAME" ] && [ "$(manifest_get "$file" service)" = "$SVC_NAME" ] && [ "$(manifest_get "$file" kind)" = "$SVC_KIND" ] && [ "$(manifest_get "$file" target)" = "$TARGET" ] || die MANIFEST_TARGET_MISMATCH
  RELEASE_ID=$(manifest_get "$file" release_id); release_id "$RELEASE_ID"; ARTIFACT_SHA=$(manifest_get "$file" artifact_sha256); [[ "$ARTIFACT_SHA" =~ ^[a-f0-9]{64}$ ]] || die INVALID_ARTIFACT_HASH
  RELEASE_DIR="$SERVICE_STATE/releases/$RELEASE_ID"; SNAPSHOT="$RELEASE_DIR/artifact.jar"; [ "$SVC_KIND" != frontend ] || SNAPSHOT="$RELEASE_DIR/artifact.tar.gz"
  [ -f "$SNAPSHOT" ] && [ "$(sha "$SNAPSHOT")" = "$ARTIFACT_SHA" ] || die SNAPSHOT_HASH_MISMATCH
}
verify_source(){
  repo_path; source_info
  [ "$(manifest_get "$RELEASE_DIR/manifest.tsv" repo)" = "$REPO_PATH" ] && [ "$(manifest_get "$RELEASE_DIR/manifest.tsv" commit)" = "$COMMIT" ] && [ "$(manifest_get "$RELEASE_DIR/manifest.tsv" branch)" = "$BRANCH" ] && [ "$(manifest_get "$RELEASE_DIR/manifest.tsv" dirty)" = "$DIRTY" ] || die SOURCE_CHANGED_SINCE_BUILD
  [ "$(manifest_get "$RELEASE_DIR/manifest.tsv" source_fingerprint)" = "$SOURCE_FINGERPRINT" ] || die SOURCE_FINGERPRINT_CHANGED
}
write_manifest(){
  local key value
  for key in format env service kind repo branch commit dirty profile release_id artifact_sha256 target created_at source_fingerprint; do
    case "$key" in format)value=1;;env)value=$ENV_NAME;;service)value=$SVC_NAME;;kind)value=$SVC_KIND;;repo)value=$REPO_PATH;;branch)value=$BRANCH;;commit)value=$COMMIT;;dirty)value=$DIRTY;;profile) if [ "$SVC_KIND" = frontend ]; then value=$(ops_setting frontend_build_script); else value=$(ops_setting maven_profile); fi;;release_id)value=$RELEASE_ID;;artifact_sha256)value=$ARTIFACT_SHA;;target)value=$TARGET;;created_at)value=$(date -u '+%Y-%m-%dT%H:%M:%SZ');;source_fingerprint)value=$SOURCE_FINGERPRINT;;esac
    [[ "$value" != *$'\n'* && "$value" != *$'\t'* && "$value" != *$'\r'* ]] || die INVALID_MANIFEST_VALUE; printf '%s\t%s\n' "$key" "$value"
  done > "$1"
}
build(){
  task_event build started
  deploy_config; repo_path; source_info; local before="$COMMIT" before_status="$SOURCE_STATUS" before_fingerprint="$SOURCE_FINGERPRINT"
  local lock_repo="$REPO_PATH" lockfile hash; [[ "${OSTYPE:-}" != msys* ]] || lock_repo=$(printf '%s' "$lock_repo" | tr 'A-Z' 'a-z')
  lockfile=$(mktemp); printf '%s' "$lock_repo" > "$lockfile"; hash=$(sha "$lockfile"); rm -f "$lockfile"
  mkdir -p "$STATE_DIR/build-locks"; BUILD_LOCK="$STATE_DIR/build-locks/$hash.lock"; BUILD_LOCK_TOKEN="build-$$-$(date +%s)-$RANDOM"
  (set -C; printf '%s' "$BUILD_LOCK_TOKEN" > "$BUILD_LOCK") 2>/dev/null || die LOCAL_BUILD_LOCKED
  BUILD_LOCK_HELD=1; trap unlock EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
  RELEASE_ID="$(date +%Y%m%d%H%M%S)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; release_id "$RELEASE_ID"; RELEASE_DIR="$SERVICE_STATE/releases/$RELEASE_ID"; mkdir -p "$RELEASE_DIR"
  rm -f "$SERVICE_STATE/current.tsv"
  local prior_output="$REPO_PATH/$SVC_ARTIFACT"; [ "$SVC_KIND" != jar ] || prior_output="$REPO_PATH/$SVC_MODULE/target/$SVC_ARTIFACT"
  if [ -e "$prior_output" ]; then mkdir -p "$SERVICE_STATE/prebuild-backup/$RELEASE_ID"; mv "$prior_output" "$SERVICE_STATE/prebuild-backup/$RELEASE_ID/"; log "previous build output saved: $SERVICE_STATE/prebuild-backup/$RELEASE_ID"; fi
  if [ "$SVC_KIND" = frontend ]; then
    case "$SVC_PACKAGE_MANAGER" in
      npm) local build_script; build_script=$(ops_setting frontend_build_script); (cd "$REPO_PATH" && HUSKY=0 CI=1 npm ci && npm run "$build_script") || die FRONTEND_BUILD_FAILED;;
      pnpm@*) [[ "$SVC_PACKAGE_MANAGER" =~ ^pnpm@[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || die INVALID_PACKAGE_MANAGER
        local build_script; build_script=$(ops_setting frontend_build_script)
        (cd "$REPO_PATH" && HUSKY=0 CI=1 corepack "$SVC_PACKAGE_MANAGER" install --frozen-lockfile && corepack "$SVC_PACKAGE_MANAGER" run "$build_script") || die FRONTEND_BUILD_FAILED;;
      *) die INVALID_PACKAGE_MANAGER;;
    esac
    [[ "$SVC_ARTIFACT" != .. && "$SVC_ARTIFACT" != . ]] || die INVALID_ARTIFACT_DIRECTORY
    local output="$REPO_PATH/$SVC_ARTIFACT" stage="$RELEASE_DIR/site"; [ -f "$output/index.html" ] || die INDEX_NOT_FOUND
    cp -R "$output" "$stage"; printf '%s\n' "$RELEASE_ID" > "$stage/service-ops-release.txt"
    SNAPSHOT="$RELEASE_DIR/artifact.tar.gz"; tar -czf "$SNAPSHOT" -C "$stage" .
  else
    local profile; profile=$(ops_setting maven_profile)
    local test_flags=(); [ "$(ops_setting run_build_tests)" = true ] || test_flags=(-DskipTests)
    (cd "$REPO_PATH" && mvn -pl "$SVC_MODULE" -am clean package -P "$profile" "${test_flags[@]}") || die MAVEN_BUILD_FAILED
    local output="$REPO_PATH/$SVC_MODULE/target/$SVC_ARTIFACT"; [ -f "$output" ] || die JAR_NOT_FOUND; SNAPSHOT="$RELEASE_DIR/artifact.jar"; cp "$output" "$SNAPSHOT"
  fi
  source_info; [ "$COMMIT" = "$before" ] && [ "$SOURCE_STATUS" = "$before_status" ] && [ "$SOURCE_FINGERPRINT" = "$before_fingerprint" ] || die SOURCE_CHANGED_DURING_BUILD
  ARTIFACT_SHA=$(sha "$SNAPSHOT"); write_manifest "$RELEASE_DIR/manifest.tsv"; printf '%s' "$SOURCE_STATUS" > "$RELEASE_DIR/source.status"
  cp "$RELEASE_DIR/manifest.tsv" "$SERVICE_STATE/current.tsv.new.$RELEASE_ID"; mv -f "$SERVICE_STATE/current.tsv.new.$RELEASE_ID" "$SERVICE_STATE/current.tsv"; log "build release=$RELEASE_ID sha256=$ARTIFACT_SHA snapshot=$SNAPSHOT"
  [ "$(cat "$BUILD_LOCK")" = "$BUILD_LOCK_TOKEN" ] || die BUILD_LOCK_OWNER_CHANGED
  rm -f "$BUILD_LOCK"; BUILD_LOCK_HELD=0
  task_event build completed
}
unlock(){
  local exit_code=$?; trap - EXIT INT TERM
  if [ "${BUILD_LOCK_HELD:-0}" = 1 ] && [ -f "$BUILD_LOCK" ] && [ "$(cat "$BUILD_LOCK")" = "$BUILD_LOCK_TOKEN" ]; then rm -f "$BUILD_LOCK"; fi
  if [ "${REMOTE_WRITE_UNKNOWN:-0}" = 1 ]; then
    echo 'RESULT UNKNOWN lock=retained inspect_before_retry=true' >&2; exit_code=75
  elif [ "${REMOTE_LOCK_HELD:-0}" = 1 ]; then remote release || { echo 'RESULT QUERY_FAILED reason=LOCK_RELEASE_FAILED manual_read_only_check_required=true' >&2; [ "$exit_code" -ne 0 ] || exit_code=1; }; fi
  [ -z "${LOCAL_LOCK:-}" ] || rmdir "$LOCAL_LOCK" 2>/dev/null || true; exit "$exit_code"
}
acquire(){
  mkdir -p "$SERVICE_STATE"; LOCAL_LOCK="$SERVICE_STATE/operation.lock"; mkdir "$LOCAL_LOCK" 2>/dev/null || die LOCAL_OPERATION_LOCKED
  trap unlock EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
  LOCK_TOKEN="op-$(date +%s)-$$-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; remote acquire; REMOTE_LOCK_HELD=1
}
upload(){
  verify_source; remote preflight; REMOTE_UPLOAD="${SVC_DIR%/*}/.service-ops-${SVC_DIR##*/}/upload-$RELEASE_ID-$LOCK_TOKEN"
  task_event transfer started
  local code=0; scp_put "$SNAPSHOT" "$REMOTE_UPLOAD" || code=$?
  if [ "$code" -eq 75 ]; then REMOTE_WRITE_UNKNOWN=1; task_event transfer unknown
  elif [ "$code" -ne 0 ]; then task_event transfer failed
  else task_event transfer completed; fi
  [ "$code" -eq 0 ] || return "$code"
  remote install; REMOTE_UPLOAD=''
}
require_url(){ [ -n "$SVC_VERIFY_URL" ] || die VERIFY_INCOMPLETE_URL_REQUIRED; [[ "$SVC_VERIFY_URL" =~ ^https?:// ]] || die INVALID_VERIFY_URL; }
plan(){ deploy_config; repo_path; source_info; printf 'PLAN kind=%s repo=%s module=%s branch=%s commit=%s dirty=%s target=%s verify_url=%s\n' "$SVC_KIND" "$REPO_PATH" "$SVC_MODULE" "$BRANCH" "$COMMIT" "$DIRTY" "$TARGET" "$SVC_VERIFY_URL" | redact; }
operate(){
  local action="$1" requested="${2:-}"; deploy_config
  case "$action" in
    plan) plan;;build) build;;release-status) remote inspect;;
    all) require_url; plan; remote preflight; acquire; build; upload; remote restart; remote verify;;
    upload) manifest_load "$SERVICE_STATE/current.tsv"; verify_source; remote preflight; acquire; upload;;
    restart) remote preflight; acquire; remote restart;;
    verify) require_url; if [ -n "$requested" ]; then release_id "$requested"; manifest_load "$SERVICE_STATE/releases/$requested/manifest.tsv"; else manifest_load "$SERVICE_STATE/current.tsv"; fi; remote verify;;
    rollback)
      require_url; release_id "$requested"; manifest_load "$SERVICE_STATE/releases/$requested/manifest.tsv"; remote preflight; acquire; remote rollback; remote restart; remote verify
      cp "$RELEASE_DIR/manifest.tsv" "$SERVICE_STATE/current.tsv.new"; mv -f "$SERVICE_STATE/current.tsv.new" "$SERVICE_STATE/current.tsv";;
  esac
}
doctor(){
  local mode="${1:-query}"; [[ "$mode" = query || "$mode" = deploy ]] || die INVALID_DOCTOR_MODE
  [ "$mode" != deploy ] || [[ "$ENV_NAME" = test || "$ENV_NAME" = overseas-test ]] || die PROD_WRITE_FORBIDDEN; command -v ssh >/dev/null || die SSH_NOT_FOUND
  local name refs; while IFS='|' read -r name _; do load_server "$ENV_NAME" "$name"; done < <(config "$CONF_DIR/servers-$ENV_NAME.conf")
  while IFS='|' read -r name _; do load_service "$ENV_NAME" "$name"; for refs in "${SERVERS[@]}"; do lookup "$CONF_DIR/servers-$ENV_NAME.conf" "$refs" >/dev/null; done; done < <(config "$CONF_DIR/services-$ENV_NAME.conf")
  if [ "$mode" = deploy ]; then
    command -v scp >/dev/null || die SCP_NOT_FOUND; command -v git >/dev/null || die GIT_NOT_FOUND
    [ -n "$WS" ] && [ -d "$WS" ] || die WORKSPACE_REQUIRED
    local required
    while IFS='|' read -r name _; do
      load_service "$ENV_NAME" "$name"; [ -n "$SVC_REPO" ] || continue
      if [ "$SVC_KIND" = jar ]; then
        for required in mvn java; do command -v "$required" >/dev/null || die "TOOL_MISSING $required"; done
      else
        for required in node tar curl; do command -v "$required" >/dev/null || die "TOOL_MISSING $required"; done
        case "$SVC_PACKAGE_MANAGER" in
          npm) command -v npm >/dev/null || die NPM_NOT_FOUND;;
          pnpm@*) [[ "$SVC_PACKAGE_MANAGER" =~ ^pnpm@[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$ ]] || die INVALID_PACKAGE_MANAGER; command -v corepack >/dev/null || die COREPACK_NOT_FOUND;;
          *) die INVALID_PACKAGE_MANAGER;;
        esac
      fi
    done < <(config "$CONF_DIR/services-$ENV_NAME.conf")
  fi
  echo "RESULT OK doctor=$mode env=$ENV_NAME"
}
usage(){ echo 'service-ops.sh <domestic|overseas>-<dev|test|prod> <target> <action> [args]; legacy dev/test/prod = domestic; production is read-only'; }
init_python
case "${1:-}" in
  config) shift; exec "$SERVICE_OPS_PYTHON" "$PLUGIN_ROOT/scripts/ops_config.py" "$@";;
  demo) shift; exec "$SERVICE_OPS_PYTHON" "$PLUGIN_ROOT/scripts/demo.py" "$@";;
esac
init_config
if [ "${1:-}" = task ]; then
  shift; task_python="${SERVICE_OPS_PYTHON:-}"
  if [ -z "$task_python" ]; then
    for candidate in python3 python; do
      if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then task_python=$candidate; break; fi
    done
  fi
  [ -n "$task_python" ] || die PYTHON_3_10_REQUIRED
  export SERVICE_OPS_BASH="$BASH"
  if [[ "${OSTYPE:-}" = msys* ]]; then SERVICE_OPS_BASH=$(cygpath -w "$BASH"); fi
  exec "$task_python" "$PLUGIN_ROOT/scripts/task_runtime.py" --engine bash "$@"
fi
[ "$#" -ge 2 ] || { usage; exit 1; }; ENV_NAME=$1; TARGET_NAME=$2; ACTION=${3:-}; shift 2; [ "$#" -eq 0 ] || shift
ENV_NAME=$(scope_name "$ENV_NAME")
assert_scope_action
[ -f "$CONF_DIR/servers-$ENV_NAME.conf" ] && [ -f "$CONF_DIR/services-$ENV_NAME.conf" ] || die CONFIG_MISSING
case "$TARGET_NAME" in
  groups)
    for scope in dev test prod overseas-dev overseas-test overseas-prod; do
      policy=task-authorized; [[ "$scope" != *prod ]] || policy=read-only
      label=$scope; [[ "$scope" = overseas-* ]] || label="domestic-$scope"
      counts=$(config "$CONF_DIR/servers-$scope.conf" | awk -F '|' '{n++;if($2!="" && $3!="" && $4!="")c++}END{printf "registered=%d configured=%d pending=%d",n,c,n-c}')
      printf '%s policy=%s %s\n' "$label" "$policy" "$counts"
    done; exit 0;;
  list) config "$CONF_DIR/services-$ENV_NAME.conf"; exit 0;;servers) config "$CONF_DIR/servers-$ENV_NAME.conf"; exit 0;;doctor) doctor "${ACTION:-query}"; exit 0;;
  trace)
    [ -n "$ACTION" ] || die TRACE_ID_REQUIRED; [[ "$ACTION" =~ ^[A-Za-z0-9._:-]{1,200}$ ]] || die INVALID_TRACE_ID
    list=${1:-}; filter=${2:-}; code=0
    if [ -z "$list" ]; then
      defaults=$("$SERVICE_OPS_PYTHON" -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])))' "$(ops_setting trace_services)")
      for name in $defaults; do if config "$CONF_DIR/services-$ENV_NAME.conf" | awk -F '|' -v key="$name" '$1==key{found=1}END{exit !found}'; then [ -z "$list" ] || list+=,; list+="$name"; fi; done
      [ -n "$list" ] || die DEFAULT_TRACE_SERVICES_NOT_CONFIGURED
    fi
    IFS=',' read -ra names <<< "$list"; for name in "${names[@]}"; do load_service "$ENV_NAME" "$name"; server_member "$filter"; done
    for name in "${names[@]}"; do load_service "$ENV_NAME" "$name"; query_service trace "$filter" "$ACTION" 20 '' 0 || code=$?; done; exit "$code";;
  all-disk|all-ps)
    code=0; while IFS='|' read -r name _; do load_server "$ENV_NAME" "$name"; ssh_program "$PLUGIN_ROOT/scripts/remote-query.sh" "$QUERY_TIMEOUT" "${TARGET_NAME#all-}" '' '' '*.log' '' '' 200 0 '' '' "$QUERY_BYTES" "$QUERY_FILES" "$QUERY_LINES" || code=$?; done < <(config "$CONF_DIR/servers-$ENV_NAME.conf"); exit "$code";;
  nginx-stats)
    identifier "$ACTION"; validate_date "${1:-}"; load_server "$ENV_NAME" "$ACTION"; domain=${2:-}; [[ -z "$domain" || "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || die INVALID_DOMAIN
    ssh_program "$PLUGIN_ROOT/scripts/remote-query.sh" "$QUERY_TIMEOUT" nginx-stats '' "$(ops_setting nginx_log_dir)" "*$domain*access*.log" "${1:-}" '' 20 0 '' '' "$QUERY_BYTES" "$QUERY_FILES" "$QUERY_LINES"; exit $?;;
esac
identifier "$TARGET_NAME"
server_count=$(config "$CONF_DIR/servers-$ENV_NAME.conf" | awk -F '|' -v key="$TARGET_NAME" '$1==key{n++}END{print n+0}'); service_count=$(config "$CONF_DIR/services-$ENV_NAME.conf" | awk -F '|' -v key="$TARGET_NAME" '$1==key{n++}END{print n+0}')
[ "$((server_count+service_count))" -eq 1 ] || die UNKNOWN_OR_AMBIGUOUS_TARGET
if [ "$server_count" -eq 1 ]; then
  load_server "$ENV_NAME" "$TARGET_NAME"
  case "$ACTION" in
    ps|disk|mem|top|services|net|jvm) ssh_program "$PLUGIN_ROOT/scripts/remote-query.sh" "$QUERY_TIMEOUT" "$ACTION" '' '' '*.log' '' "${1:-}" 200 0 '' '' "$QUERY_BYTES" "$QUERY_FILES" "$QUERY_LINES";;
    nginx-config) ssh_program "$PLUGIN_ROOT/scripts/remote-nginx.sh" "$QUERY_TIMEOUT" "$ACTION" '' '' '*.log' '' '' 200 0 '' '' "$QUERY_BYTES" "$QUERY_FILES" "$QUERY_LINES";;
    image-layout) mapfile -t storage_roots < <("$SERVICE_OPS_PYTHON" -c 'import json,sys; sys.stdout.write("\n".join(json.loads(sys.argv[1])))' "$(ops_setting storage_roots)"); ssh_program "$PLUGIN_ROOT/scripts/remote-image-layout.sh" "$QUERY_TIMEOUT" "$ACTION" "${storage_roots[@]}";;
    exec) [[ "$ENV_NAME" != *prod ]] || die PROD_EXEC_FORBIDDEN; assert_nonproduction_target; [ "$#" -ge 1 ] || die EXEC_COMMAND_REQUIRED; temp=$(mktemp); printf '%s\n' "$*" > "$temp"; code=0; SERVICE_OPS_REMOTE_MUTATION=1 ssh_program "$temp" 0 || code=$?; rm -f "$temp"; [ "$code" -eq 0 ] || exit "$code";;
    *) die INVALID_SERVER_ACTION;;
  esac; exit $?
fi
load_service "$ENV_NAME" "$TARGET_NAME"; ACTION=${ACTION:-status}
case "$ACTION" in
  plan|build|upload|restart|verify|all|rollback|release-status) operate "$ACTION" "${1:-}";;
  status|health) query_service "$ACTION" "${1:-}" '' 200 "${2:-}" 0;;
  logs) query_service logs "${2:-${SERVERS[0]}}" '' "${1:-100}" "${3:-}" 0;;
  grep) query_service grep "${3:-${SERVERS[0]}}" "${1:-error}" "${2:-200}" "${4:-}" "${5:-0}";;
  grepall) query_service grep '' "${1:-error}" "${2:-200}" "${3:-}" "${4:-0}";;
  backupgrep) query_service backupgrep "${3:-${SERVERS[0]}}" "${1:-error}" 200 "${2:-}" "${4:-0}";;
  count) query_service count "${2:-${SERVERS[0]}}" "${1:-error}" 10000 "${3:-}" 0;;
  logfiles) query_service logfiles "${1:-${SERVERS[0]}}" '' 20 "${2:-}" 0;;
  logsrange)
    [ "$#" -ge 2 ] || die TIME_RANGE_REQUIRED; start=$1; end=$2
    [ "${#start}" -ne 16 ] || start+=:00; [ "${#end}" -ne 16 ] || end+=:59
    validate_time "$start"; validate_time "$end"; [[ "$start" < "$end" || "$start" = "$end" ]] || die REVERSED_TIME_RANGE
    day=${5:-}; validate_date "$day"
    if [ -n "$day" ]; then [[ "${start:0:10}" = "${end:0:10}" && "$day" = "${start:0:4}${start:5:2}${start:8:2}" ]] || die DATE_WINDOW_MISMATCH; fi
    query_service logsrange "${4:-${SERVERS[0]}}" "${3:-}" 1000 "$day" 0 "$start" "$end";;
  *) die INVALID_SERVICE_ACTION;;
esac
