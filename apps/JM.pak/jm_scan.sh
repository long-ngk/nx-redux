#!/bin/sh
# Jar discovery plus .png/.info extraction for the JM launcher (sourced by launch.sh).
# Needs GAMEDIR; honours JM_UNZIP / JM_UNZIP_KIND (info|7z) overrides for tests.

jm_find_unzip() {
    [ -n "${JM_UNZIP:-}" ] && return 0
    sd="${SDCARD_PATH:-/mnt/SDCARD}"
    if command -v unzip >/dev/null 2>&1; then
        JM_UNZIP=unzip
        JM_UNZIP_KIND=info
    elif [ -x "$sd/.tmp_update/${PLATFORM:-tg5040}/unzip" ]; then
        JM_UNZIP="$sd/.tmp_update/${PLATFORM:-tg5040}/unzip"
        JM_UNZIP_KIND=info
    elif [ -x "$sd/.system/shared/bin/7zzs.aarch64" ]; then
        JM_UNZIP="$sd/.system/shared/bin/7zzs.aarch64"
        JM_UNZIP_KIND=7z
    else
        return 1
    fi
}

jar_read_entry() {
    jm_find_unzip || return 1
    case "${JM_UNZIP_KIND:-info}" in
        7z) "$JM_UNZIP" e -so "$1" "$2" 2>/dev/null ;;
        *)  "$JM_UNZIP" -p "$1" "$2" 2>/dev/null ;;
    esac
}

run_scan() {
    for dim in 128x128:128 240x320:240 320x240:320 384x288:384; do
        find "$GAMEDIR/Jars/${dim%%:*}" -maxdepth 1 -type f -name "*.jar" 2>/dev/null \
            | sort > "/tmp/jar_${dim##*:}"
    done
}

jar_icon_path() {
    manifest="$(jar_read_entry "$1" 'META-INF/MANIFEST.MF')" || return 1
    [ -n "$manifest" ] || return 1

    printf '%s\n' "$manifest" | awk '
        { sub(/\r$/, "") }
        /^ / { line = line substr($0, 2); next }
        { if (line != "") print line; line = $0 }
        END { if (line != "") print line }
    ' | awk '
        {
            key = $0
            sub(/:.*/, "", key)
            key = tolower(key)

            if (key == "midlet-icon") {
                value = $0
                sub(/^[^:]*:[[:space:]]*/, "", value)
                icon = value
            } else if (key == "midlet-1") {
                value = $0
                sub(/^[^:]*:[[:space:]]*/, "", value)
                n = split(value, parts, ",")
                if (n >= 2) fallback = parts[2]
            }
        }
        END {
            if (icon != "") print icon
            else if (fallback != "") print fallback
        }
    ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s#^/##'
}

extract_missing_thumbnails() {
    pending="/tmp/jm_missing_thumbnails.$$"
    : > "$pending"
    total=0

    for list in /tmp/jar_128 /tmp/jar_240 /tmp/jar_320 /tmp/jar_384; do
        [ -f "$list" ] || continue
        while IFS= read -r jar || [ -n "$jar" ]; do
            [ -f "$jar" ] || continue
            [ -s "${jar%.*}.png" ] && continue
            printf '%s\n' "$jar" >> "$pending"
            total=$((total + 1))
        done < "$list"
    done

    if [ "$total" -eq 0 ]; then
        rm -f "$pending"
        return 0
    fi

    echo "[JM] Extracting thumbnails ($total games)..."
    current=0
    extracted=0
    skipped=0

    while IFS= read -r jar || [ -n "$jar" ]; do
        current=$((current + 1))
        thumb="${jar%.*}.png"
        icon="$(jar_icon_path "$jar")"
        success=0

        case "$icon" in
            /*|../*|*/../*|*/..|*\\*) icon='' ;;
        esac
        case "$icon" in
            *.[Pp][Nn][Gg]) ;;
            *) icon='' ;;
        esac

        if [ -n "$icon" ]; then
            tmp="${thumb}.tmp.$$"
            if jar_read_entry "$jar" "$icon" > "$tmp" &&
               [ -s "$tmp" ] &&
               [ "$(od -An -tx1 -N8 "$tmp" 2>/dev/null | tr -d ' \n')" = "89504e470d0a1a0a" ] &&
               mv -f "$tmp" "$thumb"; then
                extracted=$((extracted + 1))
                success=1
            fi
            [ "$success" -eq 1 ] || rm -f "$tmp"
        fi

        [ "$success" -eq 1 ] || skipped=$((skipped + 1))
        echo "[JM] [$current/$total] ${jar##*/} extracted=$extracted skipped=$skipped"
    done < "$pending"

    rm -f "$pending"
    echo "[JM] Thumbnails done: $extracted extracted, $skipped skipped."
}

extract_missing_info() {
    for list in /tmp/jar_128 /tmp/jar_240 /tmp/jar_320 /tmp/jar_384; do
        [ -f "$list" ] || continue
        while IFS= read -r jar || [ -n "$jar" ]; do
            [ -f "$jar" ] || continue
            info="${jar%.*}.info"
            [ -e "$info" ] && continue

            manifest="$(jar_read_entry "$jar" 'META-INF/MANIFEST.MF')" || manifest=''
            tmp="${info}.tmp.$$"

            if printf '%s\n' "$manifest" | awk '
                function emit_line(  k, v) {
                    if (line == "") return
                    k = line
                    sub(/:.*/, "", k)
                    k = tolower(k)
                    if (k == "midlet-name" || k == "midlet-version" || k == "midlet-vendor") {
                        v = line
                        sub(/^[^:]*:[ \t]*/, "", v)
                        if (!(k in found)) {
                            values[k] = v
                            found[k] = 1
                        }
                    }
                }
                { sub(/\r$/, "") }
                /^ / { line = line substr($0, 2); next }
                { emit_line(); line = $0 }
                END {
                    emit_line()
                    print values["midlet-name"]
                    print values["midlet-version"]
                    print values["midlet-vendor"]
                }
            ' > "$tmp"; then
                mv -n "$tmp" "$info" 2>/dev/null || rm -f "$tmp"
            else
                rm -f "$tmp"
            fi
        done < "$list"
    done
}
