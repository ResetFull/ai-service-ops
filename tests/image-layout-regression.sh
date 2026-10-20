#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
temp_root=$(cd "${TMPDIR:-/tmp}" && pwd -P)
work=$(mktemp -d "$temp_root/service-ops-image.XXXXXXXX")
cleanup(){
  local resolved; resolved=$(cd "$work" && pwd -P) || return 1
  [[ "$resolved" = "$temp_root"/service-ops-image.* ]] || return 1
  rm -rf -- "$resolved"
}
trap cleanup EXIT
mkdir -p "$work/example-media/2026/10/15" "$work/example-media/private-person"
touch "$work/example-media/2026/10/15/123e4567-e89b-12d3-a456-426614174000.jpg"
touch "$work/example-media/private-person/private-phone-254700000001.png"
bash "$ROOT/scripts/remote-image-layout.sh" image-layout "$work/example-media" "$work/missing-a" "$work/missing-b" "$work/missing-c" > "$work/out"
grep -q 'YYYY/MM/DD | UUID-36 | extension=jpg' "$work/out"
grep -q 'truncated=false' "$work/out"
! grep -q 'private-person\|254700000001\|123e4567-e89b' "$work/out"
for number in $(seq 1 220); do touch "$work/example-media/extra-$number.jpg"; done
bash "$ROOT/scripts/remote-image-layout.sh" image-layout "$work/example-media" > "$work/out"
grep -q 'truncated=true' "$work/out"
echo 'PASS: sampled storage layout, date/UUID classification, filename privacy and sample limit'
