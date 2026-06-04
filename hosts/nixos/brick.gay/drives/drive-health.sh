#!/bin/bash
POOL="melody"
OUT="/melody/media/drives/drives.json"
mkdir -p "$(dirname "$OUT")"

HEALTH=$(zpool get health "$POOL" -H -o value 2>/dev/null || echo "UNKNOWN")
SIZE=$(zpool get size "$POOL" -H -o value 2>/dev/null || echo "N/A")
ALLOC=$(zpool get allocated "$POOL" -H -o value 2>/dev/null || echo "N/A")
SCRUB=$(zpool status "$POOL" 2>/dev/null | grep "scan:" | sed 's/.*scan: //' | sed 's/ .*//' || echo "never")
ERRORS=$(zpool status "$POOL" 2>/dev/null | grep -c "CKSUM\|READ\|WRITE" || echo "0")

DEVS=$(zpool status -L "$POOL" 2>/dev/null | grep -oP "/dev/sd[a-z]+" | sort -u)
JSON_DRIVES=""
FIRST=true
for DEV in $DEVS; do
  SERIAL=$(smartctl -i "$DEV" 2>/dev/null | grep "Serial Number" | awk '{print $NF}')
  MODEL=$(smartctl -i "$DEV" 2>/dev/null | grep "Device Model" | cut -d: -f2 | sed 's/^ *//')
  TEMP=$(smartctl -A "$DEV" 2>/dev/null | grep -i "Temperature_Celsius" | awk '{print $10}')
  POH=$(smartctl -A "$DEV" 2>/dev/null | grep -i "Power_On_Hours" | awk '{print $10}')
  REALLOC=$(smartctl -A "$DEV" 2>/dev/null | grep -i "Reallocated_Sector_Ct" | awk '{print $10}')
  PENDING=$(smartctl -A "$DEV" 2>/dev/null | grep -i "Current_Pending_Sector" | awk '{print $10}')
  SMART=$(smartctl -H "$DEV" 2>/dev/null | grep "SMART overall-health" | grep -o "PASSED\|FAILED" || echo "N/A")

  if [ "$FIRST" = true ]; then
    FIRST=false
  else
    JSON_DRIVES="$JSON_DRIVES,"
  fi
  JSON_DRIVES="$JSON_DRIVES{\"serial\":\"${SERIAL:-N/A}\",\"model\":\"${MODEL:-N/A}\",\"temp\":\"${TEMP:-N/A}\",\"power_on_hours\":\"${POH:-N/A}\",\"reallocated_sectors\":\"${REALLOC:-0}\",\"pending_sectors\":\"${PENDING:-0}\",\"smart_status\":\"${SMART:-N/A}\"}"
done

UPDATED=$(date '+%Y-%m-%d %H:%M:%S')
cat > "$OUT" << EOJSON
{
  "pool": {
    "name": "$POOL",
    "health": "${HEALTH}",
    "size": "${SIZE}",
    "allocated": "${ALLOC}",
    "scrub": "${SCRUB}",
    "errors": "${ERRORS}"
  },
  "drives": [$JSON_DRIVES],
  "last_updated": "$UPDATED"
}
EOJSON
echo "Written: $OUT"
