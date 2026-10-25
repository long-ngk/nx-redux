#!/bin/sh
# Push apps/JM.pak to the device over adb. Usage: deploy.sh [--fast] [--logs]
#   --fast  only scripts and Lua (skips the ~100 MB JDK/native payload)
#   --logs  print the pak log after the push
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAK="$ROOT/apps/JM.pak"
DEST="${JM_DEST:-/mnt/SDCARD/Tools/JM.pak}"

command -v adb >/dev/null || { echo "need adb"; exit 1; }
adb get-state >/dev/null 2>&1 || { echo "no adb device (adb devices)"; exit 1; }

fast=0
logs=0
for a in "$@"; do
    case "$a" in
        --fast) fast=1 ;;
        --logs) logs=1 ;;
        *) echo "unknown arg $a"; exit 1 ;;
    esac
done

adb shell "mkdir -p '$DEST'"
if [ "$fast" -eq 1 ]; then
    adb push "$PAK/launch.sh" "$PAK/jm_scan.sh" "$DEST/"
    adb push "$PAK/launcher/." "$DEST/launcher/"
else
    # Trailing /. merges into the existing pak, so games and thumbnails in Jars/ survive.
    adb push "$PAK/." "$DEST/"
fi
adb shell "chmod a+x '$DEST/launch.sh' '$DEST/launcher/libs/love' '$DEST/freej2me/sdl_interface' '$DEST/zulu/bin/java' 2>/dev/null; sync"
echo "pushed to $DEST (open Tools > JM on the device)"

if [ "$logs" -eq 1 ]; then
    adb shell "cat /mnt/SDCARD/.userdata/tg5040/logs/JM.txt 2>/dev/null || cat '$DEST/JM.txt'"
fi
