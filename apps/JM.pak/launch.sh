#!/bin/sh
# JM (FreeJ2ME + LOVE launcher) for NX Redux. POSIX sh on purpose: /bin/bash is not guaranteed.
# Drop .jar files into Jars/<WxH>/ inside this pak.

GAMEDIR="$(cd "$(dirname "$0")" && pwd)"
LOG="${LOGS_PATH:-$GAMEDIR}/JM.txt"
exec >"$LOG" 2>&1
echo "JM start: $GAMEDIR device=${DEVICE:-?}"

RESUME_FILE="/tmp/jm_resume"
STATE_FILE="/tmp/jm_launcher_state"
echo "$GAMEDIR" > /tmp/jm_dir
rm -f "$RESUME_FILE" "$STATE_FILE" /tmp/jm_launch_p /tmp/jm_launch_w /tmp/jm_launch_h

. "$GAMEDIR/jm_scan.sh"

NX_ORIG_LDLP="${LD_LIBRARY_PATH:-}"
BG_PIDS=""

# exFAT drops the exec bit; harmless where chmod is a no-op.
chmod a+x "$GAMEDIR/launcher/libs/love" "$GAMEDIR/freej2me/sdl_interface" \
    "$GAMEDIR/zulu/bin/java" "$GAMEDIR/zulu/bin/keytool" "$GAMEDIR/zulu/lib/jspawnhelper" \
    "$GAMEDIR/zulu/lib/jexec" 2>/dev/null

cleanup() {
    for p in $BG_PIDS; do kill "$p" 2>/dev/null; done
    rm -f "$GAMEDIR/data/.asoundrc" "$GAMEDIR/freej2me/.asoundrc" /tmp/jm_pipe
}
trap cleanup EXIT INT TERM HUP QUIT

# Keep ALSA on the sink chosen in Settings (audiomon writes this file).
if [ -f "${USERDATA_PATH:-}/.asoundrc" ]; then
    mkdir -p "$GAMEDIR/data"
    cp -f "$USERDATA_PATH/.asoundrc" "$GAMEDIR/data/.asoundrc"
    cp -f "$USERDATA_PATH/.asoundrc" "$GAMEDIR/freej2me/.asoundrc"
fi

echo "1" > /tmp/stay_awake

if command -v sleepmon.elf >/dev/null 2>&1; then
    LD_LIBRARY_PATH="$NX_ORIG_LDLP" sleepmon.elf &
    BG_PIDS="$BG_PIDS $!"
fi

# Frontend caps clocks low and hotplugs cores; the launch loop restores them after exit.
for oc in /sys/devices/system/cpu/cpu[0-9]*/online; do
    echo 1 > "$oc" 2>/dev/null
done
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$pol" ] || continue
    hwmax="$(cat "$pol/cpuinfo_max_freq" 2>/dev/null)"
    echo schedutil > "$pol/scaling_governor" 2>/dev/null
    [ -n "$hwmax" ] && echo "$hwmax" > "$pol/scaling_max_freq" 2>/dev/null
done

# Re-apply volume/brightness after SDL/ALSA init clobbers the mixer.
start_syncsettings() {
    ( sleep 5; LD_LIBRARY_PATH="$NX_ORIG_LDLP" syncsettings.elf 2>/dev/null ) &
    BG_PIDS="$BG_PIDS $!"
}

# The launcher legend is physical (A/B/X/Y), so always use the Nintendo layout.
JM_SDL_PAD="030000005e0400008e02000014010000,TRIMUI Player1,a:b1,b:b0,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b8,leftshoulder:b4,leftstick:b9,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b10,righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b3,y:b2,platform:Linux,"

run_launcher() {
    mkdir -p "$GAMEDIR/data"
    cd "$GAMEDIR/launcher" || exit 1

    HOME="$GAMEDIR/data" \
    XDG_DATA_HOME="$GAMEDIR/data" \
    XDG_CONFIG_HOME="$GAMEDIR/data" \
    SDL_GAMECONTROLLERCONFIG="$JM_SDL_PAD" \
    LOVE_GRAPHICS_USE_OPENGLES=1 \
    LD_LIBRARY_PATH="$GAMEDIR/launcher/libs/libs.aarch64:/usr/trimui/lib:/usr/lib${NX_ORIG_LDLP:+:$NX_ORIG_LDLP}" \
        ./libs/love .
    RET=$?
    echo "launcher exit=$RET"

    [ "$RET" -ne 2 ] && exit "$RET"
}

# GLES1 alias some J2ME/LWJGL paths dlopen; SD is exFAT so copy instead of symlink.
ensure_gles_alias() {
    dest="$GAMEDIR/zulu/lib/libGLES_CM.so"
    [ -e "$dest" ] && return 0
    ls /usr/lib/libGLES_CM.so /usr/trimui/lib/libGLES_CM.so >/dev/null 2>&1 && return 0
    for d in /usr/lib /usr/trimui/lib; do
        for f in "$d"/libGLESv1_CM.so*; do
            [ -f "$f" ] && cp -f "$f" "$dest" && return 0
        done
    done
}

run_j2me() {
    rm -f /tmp/jm_pipe
    mkfifo /tmp/jm_pipe

    ensure_gles_alias

    export HOME="$GAMEDIR/freej2me"
    export XDG_CONFIG_HOME="$HOME/config"
    export TIMIDITY_CFG="$GAMEDIR/freej2me/timidity/timidity.cfg"
    export SDL_GAMECONTROLLERCONFIG="$JM_SDL_PAD"
    export LD_LIBRARY_PATH="$GAMEDIR/zulu/lib:$GAMEDIR/zulu/lib/server:/usr/trimui/lib:/usr/lib${NX_ORIG_LDLP:+:$NX_ORIG_LDLP}"
    export JAVA_TOOL_OPTIONS="-Djava.util.prefs.systemRoot=./java/system -Djava.util.prefs.userRoot=./java/user -Djava.awt.headless=true -Dsun.jnu.encoding=UTF-8 -Dfile.encoding=UTF-8 -Djava.library.path=$GAMEDIR/zulu/lib"

    cd "$GAMEDIR/freej2me" || exit 1
    start_syncsettings

    "$GAMEDIR/zulu/bin/java" \
        -jar "$GAMEDIR/freej2me/freej2me-sdl.jar" \
        "$(cat /tmp/jm_launch_p)" \
        "$(cat /tmp/jm_launch_w)" \
        "$(cat /tmp/jm_launch_h)" \
        100
    echo "java exit=$?"
}

run_scan
extract_missing_thumbnails
extract_missing_info
start_syncsettings

while true; do
    run_launcher

    # Next launcher instance restores its selection.
    touch "$RESUME_FILE"

    run_j2me
done
