#!/bin/sh
# Shared transport for scripts/jm: adb by default, SSH when JM_SSH=user@host is set.
# Sourced scripts need PAK (source dir) and DEST (remote pak dir).
#   remote "<sh command>"   run on the device
#   push <path>...          copy paths relative to $PAK into $DEST (merges, never deletes)

if [ -n "${JM_SSH:-}" ]; then
    command -v ssh >/dev/null || { echo "need ssh"; exit 1; }
    command -v tar >/dev/null || { echo "need tar"; exit 1; }
    # One connection is reused so the password is asked once.
    JM_SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/tmp/jm-ssh-%C -o ControlPersist=120"
    remote() { ssh $JM_SSH_OPTS "$JM_SSH" "$1"; }
    # tar over ssh first (no sftp-server needed); busybox tar may lack -C, then scp.
    push() {
        tar -C "$PAK" -cf - "$@" | remote "tar -C '$DEST' -xf -" && return 0
        echo "tar -C push failed, retrying with cd + tar"
        tar -C "$PAK" -cf - "$@" | remote "cd '$DEST' && tar -xf -" && return 0
        echo "tar push failed, falling back to scp"
        for p in "$@"; do
            scp -O -r $JM_SSH_OPTS "$PAK/$p" "$JM_SSH:$DEST/" ||
                scp -r $JM_SSH_OPTS "$PAK/$p" "$JM_SSH:$DEST/" || return 1
        done
    }
    JM_TRANSPORT="ssh $JM_SSH"
else
    command -v adb >/dev/null || { echo "need adb (or set JM_SSH=root@<device-ip>)"; exit 1; }
    adb get-state >/dev/null 2>&1 || { echo "no adb device (adb devices); or set JM_SSH=root@<device-ip>"; exit 1; }
    remote() { adb shell "$1"; }
    push() {
        for p in "$@"; do
            if [ "$p" = . ]; then
                adb push "$PAK/." "$DEST/"
            elif [ -d "$PAK/$p" ]; then
                adb push "$PAK/$p/." "$DEST/$p/"
            else
                adb push "$PAK/$p" "$DEST/"
            fi
        done
    }
    JM_TRANSPORT="adb"
fi
