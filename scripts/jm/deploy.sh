#!/bin/sh
# Push apps/JM.pak to the device. Usage: deploy.sh [--fast] [--logs] [--logs-only]
#   --fast       only scripts and Lua (skips the ~100 MB JDK/native payload)
#   --logs       print the device logs after the push
#   --logs-only  print the device logs and exit without pushing
# Transport: adb by default; JM_SSH=root@<device-ip> uses SSH (Settings > Developer > Enable SSH).
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAK="$ROOT/apps/JM.pak"
DEST="${JM_DEST:-/mnt/SDCARD/Tools/JM.pak}"

. "$ROOT/scripts/jm/transport.sh"

fast=0
logs=0
logs_only=0
for a in "$@"; do
    case "$a" in
        --fast) fast=1 ;;
        --logs) logs=1 ;;
        --logs-only) logs=1; logs_only=1 ;;
        *) echo "unknown arg $a"; exit 1 ;;
    esac
done

print_logs() {
    echo "===== JM.txt ====="
    remote "cat /mnt/SDCARD/.userdata/tg5040/logs/JM.txt 2>/dev/null || cat '$DEST/JM.txt' 2>/dev/null || echo '(no JM.txt: enable Settings > Developer > Debug logging and rerun the app)'"
    echo "===== freej2me/logs ====="
    remote "for f in '$DEST'/freej2me/logs/*; do [ -f \"\$f\" ] && { echo \"-- \$f\"; tail -n 80 \"\$f\"; }; done; true"
}

if [ "$logs_only" -eq 1 ]; then
    print_logs
    exit 0
fi

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
    print_logs
fi
