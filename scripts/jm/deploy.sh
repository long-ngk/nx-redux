#!/bin/sh
# Push apps/JM.pak to the device. Usage: deploy.sh [--fast] [--logs]
#   --fast  only scripts and Lua (skips the ~100 MB JDK/native payload)
#   --logs  print the pak log after the push
# Transport: adb by default; JM_SSH=root@<device-ip> uses SSH (Settings > Developer > Enable SSH).
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAK="$ROOT/apps/JM.pak"
DEST="${JM_DEST:-/mnt/SDCARD/Tools/JM.pak}"

. "$ROOT/scripts/jm/transport.sh"

fast=0
logs=0
for a in "$@"; do
    case "$a" in
        --fast) fast=1 ;;
        --logs) logs=1 ;;
        *) echo "unknown arg $a"; exit 1 ;;
    esac
done

remote "mkdir -p '$DEST'"
# Pushes merge into the existing pak, so games and thumbnails in Jars/ survive.
if [ "$fast" -eq 1 ]; then
    push launch.sh jm_scan.sh launcher
else
    push .
fi
remote "chmod a+x '$DEST/launch.sh' '$DEST/launcher/libs/love' '$DEST/freej2me/sdl_interface' '$DEST/zulu/bin/java' 2>/dev/null; sync"
echo "pushed to $DEST via $JM_TRANSPORT (open Tools > JM on the device)"

if [ "$logs" -eq 1 ]; then
    remote "cat /mnt/SDCARD/.userdata/tg5040/logs/JM.txt 2>/dev/null || cat '$DEST/JM.txt'"
fi
