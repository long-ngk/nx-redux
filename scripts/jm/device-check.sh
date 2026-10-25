#!/bin/sh
# Report missing shared libraries for every native binary in the JM pak, as seen on the device.
# Run from a machine with adb after deploy.sh.
set -eu

DEST="${JM_DEST:-/mnt/SDCARD/Tools/JM.pak}"
command -v adb >/dev/null || { echo "need adb"; exit 1; }

adb shell "
cd '$DEST' || exit 1
echo \"fw: \$(cat /etc/version 2>/dev/null)\"
echo \"model: \${TRIMUI_MODEL:-unknown}\"
for f in /usr/trimui/lib/libSDL2-2.0.so.0 /usr/lib/libSDL2_ttf-2.0.so.0 /usr/lib/libcurl.so.4 /usr/trimui/lib/libmpg123.so.0 /usr/lib/libGLESv1_CM.so /usr/trimui/lib/libGLESv1_CM.so; do
    [ -e \"\$f\" ] && echo \"have  \$f\" || echo \"MISSING \$f\"
done
check() {
    echo \"== \$1\"
    LD_TRACE_LOADED_OBJECTS=1 LD_LIBRARY_PATH=\"\$2\" \"\$1\" 2>&1 | grep -E 'not found|error' || echo '   all resolved'
}
check ./launcher/libs/love \"\$PWD/launcher/libs/libs.aarch64:/usr/trimui/lib:/usr/lib\"
check ./freej2me/sdl_interface \"\$PWD/zulu/lib:/usr/trimui/lib:/usr/lib\"
check ./zulu/bin/java \"\$PWD/zulu/lib:\$PWD/zulu/lib/server:/usr/trimui/lib:/usr/lib\"
for so in zulu/lib/libawt.so zulu/lib/liblwjgl_opengles.so zulu/lib/libm3g.so zulu/lib/libSDL2_mixer-2.0.so.0 launcher/libs/libs.aarch64/liblove-11.5.so; do
    check ./\$so \"\$PWD/zulu/lib:\$PWD/launcher/libs/libs.aarch64:/usr/trimui/lib:/usr/lib\"
done
"
