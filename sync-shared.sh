#!/bin/bash

case "${SHARED_FOLDER:-0}" in
  1|true|yes) ;;
  *) exit 0 ;;
esac

if [ ! -d /shared ]; then
  echo "SHARED_FOLDER=1 but /shared is not mounted"
  exit 1
fi

POLL_INTERVAL="${SHARED_FOLDER_INTERVAL:-2}"
STAMP=/tmp/sync-stamp
PREV_STAMP=/tmp/sync-stamp-prev
MANIFEST=/tmp/sync-manifest

echo "Waiting for ADB device..."
adb wait-for-device

COMPLETED=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
while [ "$COMPLETED" != "1" ]; do
  sleep 3
  COMPLETED=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
done

echo "Device ready. Setting up /sdcard/shared..."
adb root
adb shell "mkdir -p /sdcard/shared"
find /shared -type f | sort > "$MANIFEST"
touch "$STAMP"

echo "Watching /shared for new files (polling every ${POLL_INTERVAL}s)..."

while true; do
  sleep "$POLL_INTERVAL"

  cp "$STAMP" "$PREV_STAMP"
  touch "$STAMP"

  find /shared -newer "$PREV_STAMP" -mindepth 1 -type d | while IFS= read -r dirpath; do
    relative="${dirpath#/shared/}"
    adb shell "mkdir -p '/sdcard/shared/$relative'" 2>/dev/null
  done

  find /shared -newer "$PREV_STAMP" -type f | while IFS= read -r filepath; do
    relative="${filepath#/shared/}"
    echo "PUSH $relative"
    adb push "$filepath" "/sdcard/shared/$relative" 2>/dev/null
  done

  NEW_MANIFEST=$(mktemp)
  find /shared -type f | sort > "$NEW_MANIFEST"
  diff "$MANIFEST" "$NEW_MANIFEST" | grep '^< ' | sed 's/^< //' | while IFS= read -r filepath; do
    relative="${filepath#/shared/}"
    echo "DELETE $relative"
    adb shell "rm -f '/sdcard/shared/$relative'" 2>/dev/null
  done
  mv "$NEW_MANIFEST" "$MANIFEST"
done
