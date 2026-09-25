#!/usr/bin/env bash
# Applies each configuration to the phone over devicectl, holding each for
# HOLD seconds. The app logs [Metrics] lines tagged with the label.
set -u
DEV=31C0B213-2EA5-5F00-BC31-4D731B34E6F4
HOLD=${HOLD:-30}
DIR="$(cd "$(dirname "$0")" && pwd)"  # writes control.json beside itself

apply() {
  local label=$1 cam=$2 unity=$3 tv=$4 lens=$5 pose=$6
  cat > "$DIR/control.json" <<EOF
{"label":"$label","cameraFps":$cam,"unityFps":$unity,"tvOutput":"$tv","lensCorrection":$lens,"pose":$pose,"delayMs":0,"hud":true}
EOF
  echo "$(date +%H:%M:%S) -> $label"
  xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer \
    --domain-identifier com.ethangodt.mittsspike \
    --source "$DIR/control.json" --destination Documents/control.json >/dev/null 2>&1 \
    || echo "   copy FAILED"
  sleep "$HOLD"
}

while read -r label cam unity tv lens pose; do
  [[ -z "$label" || "$label" == \#* ]] && continue
  apply "$label" "$cam" "$unity" "$tv" "$lens" "$pose"
done < "${1:-$DIR/configs.txt}"
echo "$(date +%H:%M:%S) sweep done"
