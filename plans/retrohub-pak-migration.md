# RetroHub → NX Redux Tool Pak (Brick Pro / tg5040)

## Status
- Target: TrimUI Brick Pro (tg5040)
- Created: 2026-10-10
- Source app: `migration-apps/RetroHub/`

## Scope
- Keep RetroHub's bundled runtime intact: `python/`, `vendor/` (patched SDL2),
  `rh/`, `assets/`, `bin/`, `catalog/`, `emus/`, `payload/`, `web/`.
- Wrap as a Tool Pak under `skeleton/SYSTEM/tg5040/paks/Tools/RetroHub.pak/`
  (develop in `workspace/all/retrohub/`, copy at packaging time).
- Adapt `launch.sh` for NX Redux's environment and paths.
- Replace the internal emulator subprocess launcher with a `/tmp/next` write
  + clean exit, so games run through NX Redux's standard launcher (game
  switcher, auto-save, artwork, last-played).
- Kill the orphaned-daemon defect: remove `start_new_session=True` from the
  streamer/gameweb `Popen` calls in `rh/services.py`.
- Keep RetroHub's Pinggy netplay and services (SFTPGo, SSH, ADB, MTP).
- LED/backlight: **out of scope** — `rh/leddaemon.py` and `rh/backlight.py`
  ship untouched, no build/packaging/test steps reference them.

## Decisions & notes
- LED/backlight: out of scope, shipped untouched.
- Netplay: unchanged (port 55435, `/tmp/netplay_*` files).
- Services (SFTPGo, SSH, ADB, MTP): unchanged, but no longer orphaned.
- All other files (assets, python, web, catalog, etc.) copy verbatim.

## Files to touch
| File | Change |
|------|--------|
| `skeleton/SYSTEM/tg5040/paks/Tools/RetroHub.pak/launch.sh` | Adapt for NX Redux env/paths, cleanup on normal exit; keep `--led-daemon` + self-heal |
| `skeleton/SYSTEM/tg5040/paks/Tools/RetroHub.pak/rh/services.py` | Remove `start_new_session=True` (2 sites) |
| `skeleton/SYSTEM/tg5040/paks/Tools/RetroHub.pak/rh/emulators.py` (or `emulator_store.py`) | Subprocess launch → `/tmp/next` write + `sys.exit(0)` |
| `skeleton/SYSTEM/tg5040/paks/Tools/RetroHub.pak/config.json` | New (label/icon/launch) |

## Implementation checklist

- [x] Step 1 — Create pak directory & copy RetroHub into it
- [x] Step 2 — Add `config.json`
- [x] Step 3 — Adapt `launch.sh` (env exports, LD_LIBRARY_PATH, cleanup on exit)
- [x] Step 4 — `rh/services.py`: remove `start_new_session=True` (×2)
 - [x] Step 5 — exit behaviour: `/tmp/next` hand‑off not needed; RetroHub exits cleanly to NX Redux main menu
- [ ] Step 6 — Build: `make build-prebuilts PLATFORM=tg5040` then `make all`
- [ ] Step 7 — Deploy: `make deploy DEVICE=brickpro`

## Step 1 — Pak directory

Create the pak structure. All RetroHub content is copied verbatim.

```sh
cd /home/longnguyen/practice-projects/nx-redux
PAK="skeleton/SYSTEM/tg5040/paks/Tools/RetroHub.pak"
mkdir -p "$PAK"
SRC="migration-apps/RetroHub"

# Copy everything, excluding pycache and the dev-only update scripts
for d in rh assets bin catalog emus payload web python vendor; do
  cp -R "$SRC/$d" "$PAK/"
done
cp "$SRC"/*.py "$PAK/"            # app.py, db.py, gameweb.py, led_daemon.py, streamer.py, yt.py
cp "$SRC"/LICENSE "$SRC"/NOTICE.txt "$PAK/"
rm -f "$PAK"/update_*.py          # dev-only hot-patch scripts, not part of the app
find "$PAK" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
```

## Step 2 — `config.json`

```json
{
    "label": "RetroHub",
    "icon": "icon.png",
    "iconsel": "icon.png",
    "launch": "launch.sh"
}
```

## Step 3 — Adapt `launch.sh`

Keep python discovery, `PYSDL2_DLL_PATH`, self-heal, and the `--led-daemon`
branch unchanged. Add NX Redux env fallbacks, fix library path order, and add
normal-exit cleanup.

### 3a. Env exports (after the `APP="$(pwd)"` line, replacing the existing
`SDCARD_PATH`/`LD_LIBRARY_PATH`/`PYSDL2_DLL_PATH` block)

```sh
# Respect NX Redux-provided vars, with fallbacks for standalone use.
export SDCARD_PATH="${SDCARD_PATH:-/mnt/SDCARD}"
export SYSTEM_PATH="${SYSTEM_PATH:-$SDCARD_PATH/.system}"
export LOGS_PATH="${LOGS_PATH:-$SDCARD_PATH/.userdata/shared/logs}"
export PLATFORM="${PLATFORM:-tg5040}"
export DEVICE="${DEVICE:-brickpro}"
export SHARED_SYSTEM_PATH="${SHARED_SYSTEM_PATH:-$SDCARD_PATH/.system/shared}"
export HOME="${HOME:-$SDCARD_PATH/.userdata/shared}"

# Put NX Redux's system libs first, then RetroHub's own, then firmware.
export LD_LIBRARY_PATH="$SYSTEM_PATH/lib:$SHARED_SYSTEM_PATH/lib:$APP/libs:$SDCARD_PATH/System/lib:/usr/trimui/lib:/usr/lib64:/usr/lib:/lib:$LD_LIBRARY_PATH"
export PYSDL2_DLL_PATH="$APP/libs:/usr/trimui/lib:/usr/lib64:/usr/lib"
```

### 3b. Main-loop cleanup (replace the existing `while true` loop's
`if/elif/else` body)

```sh
while true; do
    rm -f /tmp/launch_game.sh
    "$PY" app.py 2>> "$ERRLOG"
    APP_EXIT_CODE=$?

    if [ -f /tmp/launch_game.sh ]; then
        # Legacy RetroHub internal game launcher (keep for fallback)
        sh /tmp/launch_game.sh
        rm -f /tmp/launch_game.sh
        touch /tmp/stay_alive 2>/dev/null
        if [ -f /tmp/netplay_info.json ] || [ -f /tmp/netplay_tunnel.pid ]; then
            "$PY" -c "from rh.netplay import stop_netplay_tunnel; stop_netplay_tunnel()" 2>/dev/null || true
            pkill -9 -f 'localhost:55435' 2>/dev/null || true
        fi
    elif [ $APP_EXIT_CODE -ne 0 ] && [ -z "$RETROHUB_RECOVERED" ]; then
        # Self-heal on crash (unchanged from original)
        export RETROHUB_RECOVERED=1
        log "App exited with code $APP_EXIT_CODE, attempting self-heal..."
        HOTFIX_URL="https://raw.githubusercontent.com/nguyenxuanhoa493/repohubtool/main/files/rh/modals/__init__.py"
        HOTFIX_DST="$APP/rh/modals/__init__.py"
        HOTFIX_OK=1
        if command -v curl >/dev/null 2>&1; then
            curl -fsSLk --max-time 20 "$HOTFIX_URL" -o "$HOTFIX_DST.tmp" 2>/dev/null && HOTFIX_OK=0
        elif command -v wget >/dev/null 2>&1; then
            wget --no-check-certificate -q -T 20 -O "$HOTFIX_DST.tmp" "$HOTFIX_URL" 2>/dev/null && HOTFIX_OK=0
        fi
        if [ $HOTFIX_OK -eq 0 ] && [ -s "$HOTFIX_DST.tmp" ]; then
            mv -f "$HOTFIX_DST.tmp" "$HOTFIX_DST"
            rm -f "$ERRLOG"
            rm -rf "$APP/rh/__pycache__" "$APP/rh/modals/__pycache__" 2>/dev/null
            log "Self-heal complete, relaunching..."
            continue
        fi
        break
    else
        # Normal exit: clean up transient state, let nextui take over.
        rm -f /tmp/stay_alive
        if [ -f /tmp/netplay_info.json ] || [ -f /tmp/netplay_tunnel.pid ]; then
            "$PY" -c "from rh.netplay import stop_netplay_tunnel; stop_netplay_tunnel()" 2>/dev/null || true
            pkill -9 -f 'localhost:55435' 2>/dev/null || true
        fi
        break
    fi
done
```

## Step 4 — `rh/services.py`

Remove `start_new_session=True` from both daemon spawns so they terminate
with the pak instead of becoming orphans.

```python
# Before:
subprocess.Popen([sys.executable, STREAMER_SCRIPT], stdin=subprocess.DEVNULL,
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                 close_fds=True, start_new_session=True)
subprocess.Popen([sys.executable, GAMEWEB_SCRIPT], stdin=subprocess.DEVNULL,
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                 close_fds=True, start_new_session=True)

# After:
subprocess.Popen([sys.executable, STREAMER_SCRIPT], stdin=subprocess.DEVNULL,
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                 close_fds=True)
subprocess.Popen([sys.executable, GAMEWEB_SCRIPT], stdin=subprocess.DEVNULL,
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                 close_fds=True)
```

## Step 5 — No `/tmp/next` hand-off needed (corrected)

The original plan was wrong: MinUI.pak's launch loop checks `/tmp/nextui_exec`
(for emulator paks), **not** `/tmp/next`. RetroHub's internal game launching
writes `/tmp/launch_game.sh`, which MinUI also **does not** consume. So there is
no working mechanism to hand a game off to the NX Redux launcher from inside a
Tool Pak — and one is not needed, because a Tool Pak is a self‑contained app:

- RetroHub runs its own game/YouTube playback internally.
- When the user quits RetroHub, `launch.sh`'s `while true` loop breaks, the
  script ends, and the user simply returns to the NX Redux main menu.

The existing `launch.sh` already handles this correctly (netplay tunnel stop,
`rm -f /tmp/stay_alive`, no leftover processes). **No code change required** —
Step 5 is a no‑op.

## Step 6 — Build

```sh
cd /home/longnguyen/practice-projects/nx-redux
make build-prebuilts PLATFORM=tg5040    # DONE 2026-10-10 (ffplay, rsync, NDS libSDL2 in workspace/all/prebuilts/output/tg5040/)
make all            # or: make all COMPILE_CORES=true to force core rebuild
```

Output: `releases/NXRedux-<date>-brickpro.zip` and `build/BASE/MinUI-brickpro.zip`.

## Step 7 — Deploy

```sh
make deploy DEVICE=brickpro
```

Requires `adb` and a connected/authorized Brick Pro.

### How the pak reaches the device (build flow)

```
skeleton/SYSTEM/tg5040/paks/Tools/RetroHub.pak/
        │  setup: cp -R ./skeleton ./build        (Makefile line 410)
        ▼
build/SYSTEM/tg5040/paks/Tools/RetroHub.pak/
        │  package: cp -R build/SYSTEM/tg5040/. → PAYLOAD-brickpro/.system/   (line 509)
        │           zip -r MinUI.zip .system .tmp_update Emus tg5040-brickpro (line 541)
        ▼
build/BASE/MinUI-brickpro.zip   →   /mnt/SDCARD/MinUI.zip on the card
        │  boot: boot.sh extracts MinUI.zip once → .system/ tree
        ▼
/mnt/SDCARD/.system/paks/Tools/RetroHub.pak/   (nextui Tools tab picks it up)
```

### Deploy options for a Brick Pro already running NX Redux

**Option A — Full OTA via adb (repo's standard flow, recommended for first install):**

```sh
# prerequisites
command -v adb   # install: sudo apt install -y android-tools-adb
# enable ADB on the device (Settings → Developer → ADB/USB)

# builds BOTH platforms (tg5040 + tg5050), packages, then:
#   adb push build/BASE/MinUI-brickpro.zip /mnt/SDCARD/MinUI.zip && adb shell reboot
make deploy DEVICE=brickpro
```

- First build is slow: it compiles all components in Docker toolchain containers
  (+ emulator cores if `COMPILE_CORES=true`). Prebuilts for tg5040 are already
  built; run `make build-prebuilts PLATFORM=tg5050` too before a full `make deploy`.
- On reboot, `boot.sh` extracts `MinUI.zip` into `.system/` once — RetroHub.pak
  lands at `/mnt/SDCARD/.system/paks/Tools/RetroHub.pak/`.

**Option B — Quick iteration: push only the pak (no rebuild, no reflash):**

```sh
# first time: remove any stale copy so adb push doesn't nest (TESTING.md gotcha)
adb shell 'rm -rf /mnt/SDCARD/.system/paks/Tools/RetroHub.pak'
# push contents, not the dir (a dir push into an existing dir nests it)
adb push skeleton/SYSTEM/tg5040/paks/Tools/RetroHub.pak/* \
    /mnt/SDCARD/.system/paks/Tools/RetroHub.pak/
adb shell chmod 755 /mnt/SDCARD/.system/paks/Tools/RetroHub.pak/launch.sh
# verify (exFAT = no ETXTBSY; a "successful" push can still land wrong)
adb shell md5sum /mnt/SDCARD/.system/paks/Tools/RetroHub.pak/launch.sh
md5sum skeleton/SYSTEM/tg5040/paks/Tools/RetroHub.pak/launch.sh
```

- Tools paks need **no reboot** — relaunch RetroHub from the Tools tab.
- Use this for `launch.sh` / `rh/*.py` edits; the 178 M transfer over adb is
  slow but safe. Re-runnable after any change.

**Option C — Manual flash (no adb at all):**

```sh
make all            # full release zips in releases/
# copy to the SD card root (exFAT), rename, power-cycle:
cp releases/NXRedux-YYYYMMDD-brickpro.zip <SDCARD>/MinUI.zip
```

Then reboot the device; `boot.sh` auto-installs. (Full release zips also carry
BASE/Emus/Roms/etc. — a fresh install, not just the pak.)

### Post-deploy validation

- Tools tab shows **RetroHub** (icon from `icon.png`); open it.
- First launch: `launch.sh` finds the bundled `python/bin/python3`, runs
  `app.py`; log at `/mnt/SDCARD/.userdata/tg5040/logs/RetroHub.txt`
  (or `RetroHub-loi.txt` at card root on fatal errors).
- Web UI `:8888` (gameweb), streamer `:8088`, YouTube session hand-off via
  `/tmp/launch_game.sh` all work **inside** the pak; quitting returns to nextui.
- No stray processes after exit: `adb shell ps w | grep -E 'streamer|gameweb|sftpgo|dropbear'`.

## Validation (on device)

- [ ] RetroHub appears in the **Tools** tab with correct label/icon; launches without crash
- [ ] Web UI reachable at `http://<device_ip>:8090`, streamer at `:8088`
- [ ] ROM store loads, searches, and shows artwork
- [ ] Game launch goes through NX Redux: game starts, and on exit you return to the **RetroHub GUI** (not straight to nextui)
- [ ] Save states / screenshots / last-played tracking work
- [ ] Netplay connects a peer session (optional)
- [ ] SFTPGo / SSH / ADB / MTP start and stop cleanly
- [ ] No orphaned processes after exit (`adb shell ps` → no stray `streamer.py`, `gameweb.py`, `sftpgo`, `dropbear`)

## Post-MVP (optional)

- If you want the package under `Emus/RetroHub.pak` instead of Tools,
  `launch.sh` must accept a ROM argument and drop the GUI.
- Consider a small C helper only if future work requires calling
  `LEDS_setProfile()` from Python.
