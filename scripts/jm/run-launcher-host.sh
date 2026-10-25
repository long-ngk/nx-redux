#!/bin/sh
# Run the JM LOVE launcher on the host (WSLg) with fake jars; needs `love` (sudo apt install love).
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PAK="$ROOT/apps/JM.pak"
SAMPLE="${JM_SAMPLE_DIR:-/tmp/jm_host_pak}"

command -v love >/dev/null || { echo "need love (sudo apt install love)"; exit 1; }
SH="$(command -v dash || command -v sh)"

# Real pak assets, fake Jars; jm_dir points at the sandbox so config writes stay out of the repo.
rm -rf "$SAMPLE"
mkdir -p "$SAMPLE/Jars/240x320" "$SAMPLE/Jars/320x240" "$SAMPLE/Jars/128x128" "$SAMPLE/Jars/384x288" "$SAMPLE/freej2me" "$SAMPLE/data"
echo 0 > "$SAMPLE/freej2me/graphics.cfg"
for n in "Snake Rivals" "Bounce Tales" "Asphalt Urban GT" "Pocket Tanks" "Tower Bloxx" "Gangstar" "Block Breaker" "Real Football"; do
    : > "$SAMPLE/Jars/320x240/$n.jar"
    printf '%s\n1.0\nHost Test\n' "$n" > "$SAMPLE/Jars/320x240/$n.info"
done
: > "$SAMPLE/Jars/240x320/Portrait Game.jar"

echo "$SAMPLE" > /tmp/jm_dir
rm -f /tmp/jm_resume /tmp/jm_launcher_state /tmp/jm_launch_p /tmp/jm_launch_w /tmp/jm_launch_h
GAMEDIR="$SAMPLE" "$SH" -c '. "$1"; run_scan' _ "$PAK/jm_scan.sh"

cd "$PAK/launcher"
echo "Keys: arrows, Enter=30FPS (A), F2=60FPS (X), Esc=Exit (B), X=Appearance (Y)"
XDG_DATA_HOME="$SAMPLE/data" love . || rc=$?
rc="${rc:-0}"
echo "launcher exit=$rc (2 = game requested)"
[ "$rc" -eq 2 ] && { echo "launch request:"; cat /tmp/jm_launch_p /tmp/jm_launch_w /tmp/jm_launch_h; echo "config:"; cat "$SAMPLE"/freej2me/config/*/game.conf; }
exit 0
