#!/usr/bin/env bash
# Like sweep.sh, but each config line is: <label> <json of levers to set>.
# The label is added to the JSON. Each is held for HOLD seconds.
set -u
DEV=31C0B213-2EA5-5F00-BC31-4D731B34E6F4
HOLD=${HOLD:-30}
DIR="$(cd "$(dirname "$0")" && pwd)"
while read -r label json; do
  [[ -z "$label" || "$label" == \#* ]] && continue
  echo "{\"label\":\"$label\",${json#\{}" > "$DIR/control.json"
  echo "$(date +%H:%M:%S) -> $label $json"
  xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer \
    --domain-identifier com.ethangodt.mittsspike \
    --source "$DIR/control.json" --destination Documents/control.json >/dev/null 2>&1 \
    || echo "   copy FAILED"
  sleep "$HOLD"
done < "$1"
echo "$(date +%H:%M:%S) sweep done"
