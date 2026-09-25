#!/usr/bin/env bash
# Two launches - Metal display link, then classic - each running configs3.
DEV=31C0B213-2EA5-5F00-BC31-4D731B34E6F4
S="$(cd "$(dirname "$0")" && pwd)"
for mode in metal classic; do
  env='{"OS_ACTIVITY_DT_MODE":"enable"}'
  [[ $mode == classic ]] && env='{"OS_ACTIVITY_DT_MODE":"enable","MOM_CLASSIC_DISPLAY_LINK":"1"}'
  xcrun devicectl device process launch --device $DEV --terminate-existing --console -e "$env" \
    com.ethangodt.mittsspike > "$S/sweep3-$mode.log" 2>&1 &
  LOG=$!
  sleep 8
  sed "s/^X-/$mode-/" "$S/configs3.txt" > "$S/configs3-$mode.txt"
  HOLD=30 bash "$S/sweep2.sh" "$S/configs3-$mode.txt"
  kill $LOG 2>/dev/null; wait $LOG 2>/dev/null
done
echo "sweep3 done"
