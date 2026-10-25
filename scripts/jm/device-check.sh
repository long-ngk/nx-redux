#!/bin/sh
# Report missing shared libraries for every native binary in the JM pak, as seen on the device.
# Transport: adb by default; JM_SSH=root@<device-ip> uses SSH.
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${JM_DEST:-/mnt/SDCARD/Tools/JM.pak}"

. "$ROOT/scripts/jm/transport.sh"

# Shared-library names every ELF in the pak asks for (needs readelf on this machine).
needed=""
if command -v readelf >/dev/null 2>&1; then
    needed="$(find "$ROOT/apps/JM.pak/zulu" "$ROOT/apps/JM.pak/launcher/libs" "$ROOT/apps/JM.pak/freej2me/sdl_interface" -type f \( -name '*.so*' -o -name java -o -name love -o -name sdl_interface \) 2>/dev/null |
        while read -r f; do readelf -d "$f" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'; done | sort -u | tr '\n' ' ')"
else
    echo "(no readelf here: skipping the library-name check; sudo apt install binutils)"
fi

remote "
cd '$DEST' || exit 1
echo \"fw: \$(cat /etc/version 2>/dev/null)\"
echo \"model: \${TRIMUI_MODEL:-unknown}\"
for f in /usr/trimui/lib/libSDL2-2.0.so.0 /usr/lib/libSDL2_ttf-2.0.so.0 /usr/lib/libcurl.so.4 /usr/trimui/lib/libmpg123.so.0; do
    [ -e \"\$f\" ] && echo \"have  \$f\" || echo \"MISSING \$f\"
done
check() {
    echo \"== \$1\"
    LD_TRACE_LOADED_OBJECTS=1 LD_LIBRARY_PATH=\"\$2\" \"\$1\" 2>&1 | grep -E 'not found|error' || echo '   all resolved'
}
check ./launcher/libs/love \"\$PWD/launcher/libs/libs.aarch64:/usr/trimui/lib:/usr/lib\"
check ./freej2me/sdl_interface \"\$PWD/zulu/lib:/usr/trimui/lib:/usr/lib\"
check ./zulu/bin/java \"\$PWD/zulu/lib:\$PWD/zulu/lib/server:/usr/trimui/lib:/usr/lib\"
echo \"== needed libs not found (pak dirs, /usr/trimui/lib, /usr/lib, /lib)\"
miss=0
for n in $needed; do
    found=0
    for d in \"\$PWD/zulu/lib\" \"\$PWD/zulu/lib/server\" \"\$PWD/launcher/libs/libs.aarch64\" /usr/trimui/lib /usr/lib /lib; do
        [ -e \"\$d/\$n\" ] && { found=1; break; }
    done
    [ \"\$found\" = 1 ] || { echo \"MISSING \$n\"; miss=1; }
done
[ \"\$miss\" = 0 ] && echo '   none'
echo \"== GL/EGL/mali libs on the device\"
ls /usr/lib /usr/trimui/lib 2>/dev/null | grep -iE 'gles|egl|mali|libgl' || echo '   (none)'
"
