#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
temp_root=$(cd "${TMPDIR:-/tmp}" && pwd -P)
work=$(mktemp -d "$temp_root/service-ops-nginx.XXXXXXXX")
cleanup(){
  local resolved; resolved=$(cd "$work" && pwd -P) || return 1
  [[ "$resolved" = "$temp_root"/service-ops-nginx.* ]] || return 1
  rm -rf -- "$resolved"
}
trap cleanup EXIT
mkdir -p "$work/conf"
cat > "$work/conf/image.conf" <<'CONF'
server { listen 80; server_name image.example; proxy_set_header Authorization "private-header-value";
  location /example-report/ { alias /data/example-report/test/; }
  proxy_pass http://user:private-url-password@storage:8080/image?token=private-query-value;
  add_header Access-Control-Allow-Origin *;
  ssl_certificate_key /private/secret.key;
}
CONF
sed -e "s|/opt/nginx/conf|$work/conf|g" -e "s|/etc/nginx|$work/missing-a|g" -e "s|/usr/local/nginx/conf|$work/missing-b|g" "$ROOT/scripts/remote-nginx.sh" > "$work/query.sh"
bash "$work/query.sh" nginx-config > "$work/out"
grep -q 'server_name image.example' "$work/out"
grep -q 'alias /data/example-report/test/' "$work/out"
grep -q 'Access-Control-Allow-Origin' "$work/out"
grep -q 'RESULT OK' "$work/out"
! grep -q 'private-header-value\|private-url-password\|private-query-value\|secret.key' "$work/out"
if bash "$work/query.sh" nginx-config '' '' '' '' '' 200 0 '' '' 8 20 2000 > "$work/out"; then
  echo 'FAIL: byte truncation was reported as complete' >&2; exit 1
fi
grep -q 'RESULT PARTIAL' "$work/out"
if bash "$work/query.sh" nginx-config '' '' '' '' '' 200 0 '' '' 16777216 20 1 > "$work/out"; then
  echo 'FAIL: line truncation was reported as complete' >&2; exit 1
fi
grep -q 'RESULT PARTIAL' "$work/out"
echo 'PASS: read-only Nginx mapping, inline secret exclusion, URL redaction and query budgets'
