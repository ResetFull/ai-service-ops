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
release=20260928120000-aabbccdd; token=test-token
fail(){ echo "FAIL: $*" >&2; exit 1; }
remote(){ bash "$ROOT/scripts/remote-release.sh" "$@"; }
mkdir -p "$work/site" "$work/package"; printf old > "$work/site/index.html"
if remote preflight frontend "$work/site" dist "$release" '' '' none http://localhost "$token" >"$work/out" 2>&1; then fail 'legacy real directory accepted'; fi
grep -q LAYOUT_MIGRATION_REQUIRED "$work/out" || fail 'missing migration evidence'
printf new > "$work/package/index.html"; printf '%s\n' "$release" > "$work/package/service-ops-release.txt"
tar -czf "$work/upload.tar.gz" -C "$work/package" .
sha=$(sha256sum "$work/upload.tar.gz" | awk '{print $1}')
target="$work/live"
if [[ "${OSTYPE:-}" = msys* ]]; then
  export MSYS=winsymlinks:nativestrict
  if ln -s "$work/package" "$work/link-probe" 2>/dev/null && [ -L "$work/link-probe" ]; then
    rm -f "$work/link-probe"
  else
    rm -f "$work/link-probe"
    export MSYS=winsymlinks:lnk
    target="$work/live.lnk"
    echo 'NOTE: MSYS shortcut simulation; native Linux switching is checked separately'
  fi
fi
remote preflight frontend "$target" dist "$release" "$sha" "$work/upload.tar.gz" none http://localhost "$token"
remote acquire frontend "$target" dist "$release" "$sha" '' none '' "$token"
if remote acquire frontend "$target" dist "$release" "$sha" '' none '' another >"$work/out" 2>&1; then fail 'concurrent lock accepted'; fi
grep -q LOCKED "$work/out" || fail 'missing lock evidence'
remote install frontend "$target" dist "$release" "$sha" "$work/upload.tar.gz" none '' "$token"
[ -L "$target" ] && [ "$(cat "$target/index.html")" = new ] || fail 'symlink release failed'
remote release frontend "$target" dist "$release" "$sha" '' none '' "$token"
second=20260928120001-11223344
printf second > "$work/package/index.html"; printf '%s\n' "$second" > "$work/package/service-ops-release.txt"
tar -czf "$work/upload2.tar.gz" -C "$work/package" .; sha2=$(sha256sum "$work/upload2.tar.gz" | awk '{print $1}')
remote acquire frontend "$target" dist "$second" "$sha2" '' none '' "$token"
remote install frontend "$target" dist "$second" "$sha2" "$work/upload2.tar.gz" none '' "$token"
remote rollback frontend "$target" dist "$release" "$sha" '' none '' "$token"
[ "$(cat "$target/index.html")" = new ] || fail 'rollback incorrect'
remote inspect frontend "$target" dist '' '' '' none '' '' > "$work/status"
grep -q "CURRENT release_id=$release" "$work/status" && grep -q "PREVIOUS release_id=$second" "$work/status" || fail 'active/previous records incorrect'
bad=20260928120002-55667788
tar -czf "$work/unsafe.tar.gz" --transform 's#^\./#../#' -C "$work/package" .
badsha=$(sha256sum "$work/unsafe.tar.gz" | awk '{print $1}')
if remote install frontend "$target" dist "$bad" "$badsha" "$work/unsafe.tar.gz" none '' "$token" > "$work/out" 2>&1; then fail 'traversal archive accepted'; fi
[ "$(cat "$target/index.html")" = new ] || fail 'unsafe archive changed active site'
printf corrupt > "$target/index.html"
if remote rollback frontend "$target" dist "$release" "$sha" '' none '' "$token" > "$work/out" 2>&1; then fail 'corrupt release accepted'; fi
grep -q FRONTEND_FILE_HASH_MISMATCH "$work/out" || fail 'missing file hash corruption evidence'
remote release frontend "$target" dist "$release" "$sha" '' none '' "$token"
mkdir "$work/jar"; printf jar > "$work/jar/a.jar"; printf 'exit 13\n' > "$work/jar/restart.sh"
remote acquire jar "$work/jar" a.jar "$release" '' '' script '' "$token"
if remote restart jar "$work/jar" a.jar "$release" '' '' script '' "$token" >"$work/out" 2>&1; then fail 'restart failure hidden'; fi
remote release jar "$work/jar" a.jar "$release" '' '' script '' "$token"
echo 'PASS: Bash remote release behavior'
