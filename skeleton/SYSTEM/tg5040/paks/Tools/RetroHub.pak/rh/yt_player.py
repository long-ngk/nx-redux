# -*- coding: utf-8 -*-
"""YouTube standalone player launcher for RetroHub on TrimUI devices."""

import http.server
import os
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.request

SDCARD_PATH = os.environ.get("SDCARD_PATH", "/mnt/SDCARD")
APP_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG_FILE = os.path.join(SDCARD_PATH, "RetroHub-yt.log")
TEMP_LOG = "/tmp/retrohub_yt.log"
ERR_MARKER = "/tmp/yt_last_error.txt"


def log(msg: str):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] [rh.yt_player] {msg}"
    if __name__ == "__main__":
        print(line, flush=True)
    try:
        with open(TEMP_LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def record_error(err: str):
    log(f"ERROR: {err}")
    try:
        with open(ERR_MARKER, "w", encoding="utf-8") as f:
            f.write(err)
    except Exception:
        pass


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_proxy_class(target_cdn_url: str):
    class StreamingProxy(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):
            pass

        def do_HEAD(self):
            ctx = ssl._create_unverified_context()
            headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
            for h in ("Range", "range", "Accept", "accept"):
                if h in self.headers:
                    headers[h] = self.headers[h]

            req = urllib.request.Request(target_cdn_url, headers=headers)
            try:
                with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
                    self.send_response(resp.status)
                    for k, v in resp.headers.items():
                        if k.lower() in ("content-type", "content-length", "content-range", "accept-ranges"):
                            self.send_header(k, v)
                    self.end_headers()
            except Exception:
                pass

        def do_GET(self):
            ctx = ssl._create_unverified_context()
            headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}
            for h in ("Range", "range", "Accept", "accept"):
                if h in self.headers:
                    headers[h] = self.headers[h]

            req = urllib.request.Request(target_cdn_url, headers=headers)
            try:
                with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
                    self.send_response(resp.status)
                    for k, v in resp.headers.items():
                        if k.lower() in ("content-type", "content-length", "content-range", "accept-ranges"):
                            self.send_header(k, v)
                    self.end_headers()
                    # Increase buffer chunk to 128KB for fast high-throughput streaming
                    while True:
                        chunk = resp.read(131072)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
            except Exception:
                # Client closed socket or seeked
                pass

    return StreamingProxy


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


_STREAM_CACHE_FILE = "/tmp/yt_stream_cache.json"
_STREAM_CACHE = {}
_YTDLP_READY = False
_YTDLP_LOCK = threading.Lock()


def _load_stream_cache():
    global _STREAM_CACHE
    if os.path.exists(_STREAM_CACHE_FILE):
        try:
            with open(_STREAM_CACHE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    now = time.time()
                    for k, v in data.items():
                        if isinstance(v, list) and len(v) >= 3 and v[2] > now:
                            _STREAM_CACHE[k] = (v[0], v[1], v[2])
        except Exception:
            pass


def _save_stream_cache():
    try:
        now = time.time()
        to_save = {k: list(v) for k, v in _STREAM_CACHE.items() if len(v) >= 3 and v[2] > now}
        with open(_STREAM_CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump(to_save, f)
    except Exception:
        pass


def ensure_ytdlp_ready():
    """Giai nen bin/yt-dlp vao bo nho RAM (/tmp/ytdlp_cache) de import tuc thi."""
    global _YTDLP_READY
    if _YTDLP_READY:
        return True
    _load_stream_cache()
    with _YTDLP_LOCK:
        if _YTDLP_READY:
            return True
        try:
            unzip_dir = "/tmp/ytdlp_cache"
            ytdlp_zip = os.path.join(APP_DIR, "bin", "yt-dlp")
            if not os.path.exists(ytdlp_zip):
                for c in [
                    os.path.join(SDCARD_PATH, "Apps", "RetroHub", "bin", "yt-dlp"),
                    os.path.join(SDCARD_PATH, ".retrohub", "bin", "yt-dlp"),
                ]:
                    if os.path.exists(c):
                        ytdlp_zip = c
                        break

            if os.path.exists(ytdlp_zip):
                if not os.path.exists(os.path.join(unzip_dir, "yt_dlp")):
                    import zipfile
                    os.makedirs(unzip_dir, exist_ok=True)
                    with zipfile.ZipFile(ytdlp_zip, "r") as z:
                        z.extractall(unzip_dir)
                if unzip_dir not in sys.path:
                    sys.path.insert(0, unzip_dir)
            else:
                if ytdlp_zip not in sys.path:
                    sys.path.insert(0, ytdlp_zip)

            import yt_dlp
            _YTDLP_READY = True
            log("yt-dlp da san sang trong bo nho RAM.")
            return True
        except Exception as e:
            log(f"Loi chuan bi yt-dlp: {e}")
            return False


def extract_stream_fast(video_id: str) -> tuple:
    """Lay truc tiep link stream tu cache neu co, neu chua co thi goi yt-dlp toi uu."""
    now = time.time()
    if not _STREAM_CACHE:
        _load_stream_cache()
    if video_id in _STREAM_CACHE:
        cached_url, cached_title, cached_exp = _STREAM_CACHE[video_id]
        if now < cached_exp:
            log(f"Lay link tu cache hop le cho video: {video_id}")
            return cached_url, cached_title

    return extract_stream_url(video_id)


def extract_stream_url(video_id: str) -> tuple:
    """Trích xuất stream URL định dạng MP4 360p progressive (format 18) bằng yt-dlp tối ưu."""
    ensure_ytdlp_ready()
    try:
        import yt_dlp
    except ImportError:
        record_error("Khong tim thay module yt-dlp!")
        return None, None

    yt_url = f"https://www.youtube.com/watch?v={video_id}"
    log(f"Dang phan tich video qua yt-dlp: {yt_url}")

    ydl_opts = {
        "format": "18/b[ext=mp4]/best",
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "nocheckcertificate": True,
        "skip_download": True,
        "check_formats": False,
        "lazy_playlist": True,
        "no_color": True,
        "extractor_args": {
            "youtube": {
                "player_client": ["android"],
                "skip": ["dash", "hls", "translated_subs", "comments", "subtitles"]
            }
        },
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(yt_url, download=False)
            stream_url = info.get("url")
            title = info.get("title", video_id)
            log(f"Phan tich thanh cong qua yt-dlp: '{title}', format: {info.get('format')}")
            if stream_url:
                _STREAM_CACHE[video_id] = (stream_url, title, time.time() + 10800)
                _save_stream_cache()
            return stream_url, title
    except Exception as e:
        record_error(f"Loi khi trich xuat link video tu YouTube: {e}")
        return None, None


def resolve_retroarch_and_ffmpeg():
    """Find RetroArch binary and FFMPEG core across multiple standard paths."""
    ra_candidates = [
        os.path.join(SDCARD_PATH, "RetroArch", "ra64.trimui"),
        os.path.join(SDCARD_PATH, "RetroArch", "ra32.trimui"),
        os.path.join(SDCARD_PATH, "RetroArch", "retroarch"),
        os.path.join(SDCARD_PATH, "System", "bin", "retroarch"),
        "/usr/bin/retroarch",
    ]
    ra_bin = None
    ra_dir = os.path.join(SDCARD_PATH, "RetroArch")
    for c in ra_candidates:
        if os.path.exists(c):
            ra_bin = c
            ra_dir = os.path.dirname(c)
            break

    ffmpeg_candidates = [
        os.path.join(SDCARD_PATH, "Emus", "FFMPEG", "ffmpeg_libretro.so"),
        os.path.join(SDCARD_PATH, "RetroArch", ".retroarch", "cores", "ffmpeg_libretro.so"),
        os.path.join(SDCARD_PATH, "RetroArch", "cores", "ffmpeg_libretro.so"),
        os.path.join(SDCARD_PATH, "Emus", "MEDIA", "ffmpeg_libretro.so"),
        "/usr/lib/libretro/ffmpeg_libretro.so",
        "/usr/trimui/lib/libretro/ffmpeg_libretro.so",
    ]
    ffmpeg_core = None
    for c in ffmpeg_candidates:
        if os.path.exists(c):
            ffmpeg_core = c
            break

    return ra_bin, ra_dir, ffmpeg_core


def resolve_ffplay():
    """ffplay bundled with NX Redux (same binary its Media Player uses)."""
    shared = os.environ.get("SHARED_SYSTEM_PATH") or os.path.join(SDCARD_PATH, ".system", "shared")
    for c in (os.path.join(shared, "bin", "ffplay"), "/usr/bin/ffplay"):
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def load_quality() -> int:
    import json
    try:
        with open(os.path.join(APP_DIR, "settings.json"), "r", encoding="utf-8") as f:
            q = int(json.load(f).get("yt_quality", 360))
    except Exception:
        return 360
    return q if q in (360, 480, 720) else 360


def _ffplay_cmd(ffplay_bin, title, src, audio_only=False):
    cmd = [ffplay_bin, "-fs", "-autoexit", "-loglevel", "error", "-sn",
           "-framedrop", "-fast", "-skip_loop_filter", "all", "-skip_idct", "noref"]
    # ffplay aborts on an option the input never consumes, yet still exits 0.
    if src.startswith("http"):
        cmd += ["-user_agent", "Mozilla/5.0"]
    cmd += ["-window_title", title]
    if audio_only:
        cmd.append("-nodisp")
    return cmd + ["-i", src]


_MAX_FREQ = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"


def _read_max_freq():
    try:
        with open(_MAX_FREQ, "r") as f:
            return f.read().strip()
    except OSError:
        return None


def _write_max_freq(khz):
    try:
        with open(_MAX_FREQ, "w") as f:
            f.write(str(khz))
    except OSError:
        pass


def extract_dash_streams(video_id: str, height: int):
    """{video, audio, title, duration} (yt-dlp format dicts) for H.264 up to `height` plus m4a audio, or None.

    Only the tv_embedded client hands out these separate streams; the android
    client used for 360p serves just the muxed format 18.
    """
    ensure_ytdlp_ready()
    try:
        import yt_dlp
    except ImportError:
        return None
    opts = {
        "format": f"bv[vcodec^=avc1][height<={height}]+ba[ext=m4a]",
        "quiet": True, "no_warnings": True, "noplaylist": True, "no_color": True,
        "nocheckcertificate": True, "skip_download": True,
        "extractor_args": {"youtube": {"player_client": ["tv_embedded"]}},
    }
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=False)
    except Exception as e:
        log(f"Khong lay duoc luong {height}p: {e}")
        return None
    fmts = info.get("requested_formats") or []
    if len(fmts) != 2 or not all(f.get("url") for f in fmts):
        return None
    v, a = fmts
    log(f"Phan tich thanh cong: '{info.get('title')}', format: {v.get('format_id')}+{a.get('format_id')} - "
        f"{v.get('width')}x{v.get('height')}")
    return {"video": v, "audio": a, "title": info.get("title", video_id), "duration": info.get("duration") or 0}


DASH_MPD = "/tmp/yt_dash.mpd"


def _read_head(url: str, n: int = 131072) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Range": f"bytes=0-{n - 1}"})
    with urllib.request.urlopen(req, context=ssl._create_unverified_context(), timeout=20) as resp:
        return resp.read()


def _mp4_index(buf: bytes):
    """(init_end, timescale, first_segment_offset, [(size, duration)]) from moov+sidx at the head of a DASH mp4, or None."""
    pos, init_end, sidx = 0, 0, None
    while pos + 8 <= len(buf):
        size, typ = struct.unpack(">I4s", buf[pos:pos + 8])
        hdr = 8
        if size == 1:
            size = struct.unpack(">Q", buf[pos + 8:pos + 16])[0]
            hdr = 16
        if size < hdr:
            break
        if typ == b"moov":
            init_end = pos + size
        elif typ == b"sidx":
            body = buf[pos + hdr:pos + size]
            timescale = struct.unpack(">I", body[8:12])[0]
            if body[0] == 0:
                first, off = struct.unpack(">I", body[16:20])[0], 20
            else:
                first, off = struct.unpack(">Q", body[20:28])[0], 28
            count = struct.unpack(">H", body[off + 2:off + 4])[0]
            off += 4
            refs = []
            for _ in range(count):
                word, dur, _sap = struct.unpack(">III", body[off:off + 12])
                if word >> 31:
                    return None
                refs.append((word & 0x7FFFFFFF, dur))
                off += 12
            sidx = (timescale, pos + size + first, refs)
        elif typ in (b"moof", b"mdat"):
            break
        pos += size
    if not init_end or not sidx or not sidx[2]:
        return None
    return (init_end,) + sidx


def _segment_list(port: int, name: str, idx) -> str:
    init_end, timescale, start, refs = idx
    # dashdec seeks assuming equal-length segments, so give it the mean rather than the first.
    mean = max(1, round(sum(d for _, d in refs) / len(refs)))
    url = f"http://127.0.0.1:{port}/{name}"
    rows = [f'<SegmentList timescale="{timescale}" duration="{mean}">',
            f'<Initialization sourceURL="{url}" range="0-{init_end - 1}"/>']
    off = start
    for size, _dur in refs:
        rows.append(f'<SegmentURL media="{url}" mediaRange="{off}-{off + size - 1}"/>')
        off += size
    rows.append("</SegmentList>")
    return "\n".join(rows)


def _dash_manifest(got: dict, ports, idx_v, idx_a) -> str:
    v, a = got["video"], got["audio"]
    dur = float(got["duration"])
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" type="static" mediaPresentationDuration="PT{dur:.3f}S" minBufferTime="PT2S">
<Period duration="PT{dur:.3f}S">
<AdaptationSet id="0" contentType="video" mimeType="video/mp4" segmentAlignment="true" startWithSAP="1">
<Representation id="v" bandwidth="{int((v.get('tbr') or 1500) * 1000)}" codecs="{v['vcodec']}" width="{v['width']}" height="{v['height']}" frameRate="{int(v.get('fps') or 25)}">
{_segment_list(ports[0], 'v.mp4', idx_v)}
</Representation>
</AdaptationSet>
<AdaptationSet id="1" contentType="audio" mimeType="audio/mp4" segmentAlignment="true" startWithSAP="1">
<Representation id="a" bandwidth="{int((a.get('tbr') or 128) * 1000)}" codecs="{a['acodec']}" audioSamplingRate="{int(a.get('asr') or 44100)}">
{_segment_list(ports[1], 'a.m4a', idx_a)}
</Representation>
</AdaptationSet>
</Period>
</MPD>
"""


def play_dash(video_id: str, height: int, ffplay_bin: str):
    """Play separate video+audio via a local DASH manifest so ffplay can seek. None means unavailable."""
    got = extract_dash_streams(video_id, height)
    if not got:
        return None
    title = got["title"]
    servers, prev_freq = [], None
    try:
        ports = []
        for f in (got["video"], got["audio"]):
            srv = ThreadedHTTPServer(("127.0.0.1", find_free_port()), make_proxy_class(f["url"]))
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            servers.append(srv)
            ports.append(srv.server_address[1])
        idx_v = _mp4_index(_read_head(got["video"]["url"]))
        idx_a = _mp4_index(_read_head(got["audio"]["url"]))
        if not idx_v or not idx_a:
            log("Khong doc duoc chi muc sidx cua luong DASH.")
            return None
        with open(DASH_MPD, "w", encoding="utf-8") as f:
            f.write(_dash_manifest(got, ports, idx_v, idx_a))
        env = os.environ.copy()
        env["HOME"] = env.get("USERDATA_PATH") or env.get("HOME", "/root")
        # Same range Media Player.pak asks for; the launcher's default cap is too low for 720p software decode.
        prev_freq = _read_max_freq()
        _write_max_freq(2000000)
        subprocess.call("echo 1 > /tmp/stay_awake 2>/dev/null", shell=True)
        cmd = _ffplay_cmd(ffplay_bin, title, DASH_MPD)
        log(f"Command: {' '.join(cmd)}")
        started = time.time()
        res = subprocess.run(cmd, env=env)
        log(f"ffplay exit code: {res.returncode}")
        if time.time() - started < 3:
            return None
        return res.returncode == 0
    except Exception as e:
        log(f"Loi khi phat video {height}p, quay lai 360p: {e}")
        return None
    finally:
        for s in servers:
            try:
                s.shutdown()
                s.server_close()
            except Exception:
                pass
        if prev_freq:
            _write_max_freq(prev_freq)
        subprocess.call(f"rm -f /tmp/stay_awake {DASH_MPD} 2>/dev/null", shell=True)


def play_video(video_id: str, direct_stream_url: str = None, direct_title: str = None,
               audio_only: bool = False):
    # Reset error marker
    if os.path.exists(ERR_MARKER):
        try:
            os.remove(ERR_MARKER)
        except Exception:
            pass

    log(f"==================================================")
    log(f"Bat dau phat YouTube video ID: {video_id}")

    quality = load_quality()
    if quality > 360 and not direct_stream_url and not audio_only and not resolve_retroarch_and_ffmpeg()[0]:
        ffplay_bin = resolve_ffplay()
        if ffplay_bin:
            played = play_dash(video_id, quality, ffplay_bin)
            if played is not None:
                return played
            log(f"Khong co luong {quality}p, quay lai 360p.")

    if direct_stream_url:
        stream_url = direct_stream_url
        title = direct_title or video_id
        log(f"Su dung stream URL da trich xuat san tu app (Bo qua buoc phan tich).")
    elif audio_only:
        from .yt import resolve_audio_stream
        stream_url, title = resolve_audio_stream(video_id)
        if not stream_url:
            log("Khong lay duoc luong audio-only, fallback sang video.")
            stream_url, title = extract_stream_fast(video_id)
        else:
            log("Dung luong audio-only (chi phat tieng).")
    else:
        stream_url, title = extract_stream_fast(video_id)

    if not stream_url:
        log("Huy phat video vi khong lay duoc link.")
        return False

    # 1. Local HTTP streaming bridge
    proxy_server = None
    play_url = stream_url

    if stream_url.startswith("https://"):
        try:
            port = 8899
            try:
                proxy_server = ThreadedHTTPServer(("127.0.0.1", port), make_proxy_class(stream_url))
            except Exception:
                port = find_free_port()
                proxy_server = ThreadedHTTPServer(("127.0.0.1", port), make_proxy_class(stream_url))

            t = threading.Thread(target=proxy_server.serve_forever, daemon=True)
            t.start()
            play_url = f"http://127.0.0.1:{port}/stream.mp4"
            log(f"Da khoi dong Streaming Proxy bridge tai: {play_url}")
        except Exception as e:
            log(f"Khong the bat Streaming Proxy, dung link goc: {e}")
            play_url = stream_url

    # 2. Tao cau hinh bo phim dieu khien & OSD cho RetroArch
    ra_override_path = "/tmp/ra_yt_override.cfg"
    ra_override_content = """# RetroArch Media Controls & OSD Override for YouTube Streaming
# Tat hotkey enable de cac nut phan cung hoat dong truc tiep ngay lap tuc
input_enable_hotkey_btn = "nul"
input_enable_hotkey = "nul"

# Phim A (btn 1): Tam dung / Tiep tuc phat (Pause / Resume)
input_pause_toggle_btn = "1"
input_pause_toggle = "p"

# Phim B (btn 0): Thoat video ngay lap tuc, quay ve RetroHub
input_exit_emulator_btn = "0"
input_exit_emulator = "escape"

# Phim X (btn 3): Mo Menu RetroArch (Quick Menu)
input_menu_toggle_btn = "3"
input_menu_toggle_gamepad_combo = "4"

# Phim Y (btn 2): Tua nhanh (Fast forward)
input_toggle_fast_forward_btn = "2"
input_hold_fast_forward_btn = "2"

# Phim Start (btn 6): Tam dung / Tiep tuc
input_player1_start_btn = "6"

# Cho phep can Analog Trai hoat dong nhu D-Pad de tua video muot ma
input_player1_analog_dpad_mode = "1"

# Mapping D-Pad cho ffmpeg core (13=Left: -10s, 14=Right: +10s, 12=Down: -60s, 11=Up: +60s)
input_player1_b_btn = "0"
input_player1_a_btn = "1"
input_player1_y_btn = "2"
input_player1_x_btn = "3"
input_player1_select_btn = "4"
input_player1_start_btn = "6"
input_player1_l_btn = "9"
input_player1_r_btn = "10"
input_player1_up_btn = "11"
input_player1_down_btn = "12"
input_player1_left_btn = "13"
input_player1_right_btn = "14"

# Phim L / R (btn 9 / 10): Giam / Tang am luong
input_volume_up_btn = "10"
input_volume_down_btn = "9"

# Cau hinh OSD (On-Screen Display) ro net mau Cyan
video_font_enable = "true"
video_message_pos_x = "0.050000"
video_message_pos_y = "0.060000"
video_message_color = "00f6f6"
video_font_size = "32.000000"
notification_show_fast_forward = "true"
fps_show = "false"
input_driver = "sdl2"
input_joypad_driver = "sdl2"
"""
    if audio_only:
        ra_override_content += (
            '\n# Audio-only: tat xuat hinh de tiet kiem pin\n'
            'video_driver = "null"\n'
        )
    try:
        with open(ra_override_path, "w", encoding="utf-8") as f:
            f.write(ra_override_content)
        ffmpeg_cfg_dir = os.path.join(SDCARD_PATH, "RetroArch", ".retroarch", "config", "FFmpeg")
        if os.path.exists(ffmpeg_cfg_dir):
            with open(os.path.join(ffmpeg_cfg_dir, "FFmpeg.cfg"), "w", encoding="utf-8") as f:
                f.write(ra_override_content)
    except Exception as e:
        log(f"Loi khi ghi override config: {e}")

    # 3. Xac dinh trinh phat RetroArch va FFMPEG Core
    ra_bin, ra_dir, ffmpeg_core = resolve_retroarch_and_ffmpeg()
    emu_dir = os.path.dirname(ffmpeg_core) if ffmpeg_core else os.path.join(SDCARD_PATH, "Emus", "FFMPEG")

    success = False
    saved_bl = None
    try:
        if ra_bin and ffmpeg_core and os.path.exists(ra_bin) and os.path.exists(ffmpeg_core):
            log(f"Khoi chay RetroArch: {ra_bin}, Core: {ffmpeg_core}")
            # CPU boost
            for sh_f in ("cpufreq.sh", "cpuswitch.sh"):
                p = os.path.join(emu_dir, sh_f)
                if os.path.exists(p):
                    subprocess.call(["sh", p])

            env = os.environ.copy()
            env["HOME"] = ra_dir
            env["LD_LIBRARY_PATH"] = f"/mnt/SDCARD/System/lib:/usr/trimui/lib:{os.path.join(ra_dir, 'lib')}:" + env.get("LD_LIBRARY_PATH", "")
            cmd = [
                ra_bin,
                "--appendconfig=" + ra_override_path,
                "-L", ffmpeg_core,
                play_url,
            ]
            log(f"Command: {' '.join(cmd)}")
            if audio_only:
                try:
                    from . import backlight
                    saved_bl = backlight.screen_off()
                    log("Audio-only: da tat man hinh." if saved_bl else
                        "Audio-only: khong tim thay dieu khien den nen.")
                except Exception as e:
                    log(f"Audio-only: loi tat man hinh: {e}")
            subprocess.call("echo 1 > /tmp/stay_awake 2>/dev/null", shell=True)
            res = subprocess.run(cmd, cwd=ra_dir, env=env)
            subprocess.call("rm -f /tmp/stay_awake 2>/dev/null", shell=True)
            log(f"RetroArch exit code: {res.returncode}")
            success = (res.returncode == 0)

        elif resolve_ffplay():
            ffplay_bin = resolve_ffplay()
            log(f"Khong co RetroArch, dung ffplay: {ffplay_bin}")
            env = os.environ.copy()
            env["HOME"] = env.get("USERDATA_PATH") or env.get("HOME", "/root")
            cmd = _ffplay_cmd(ffplay_bin, title or video_id, play_url, audio_only)
            log(f"Command: {' '.join(cmd)}")
            subprocess.call("echo 1 > /tmp/stay_awake 2>/dev/null", shell=True)
            res = subprocess.run(cmd, env=env)
            subprocess.call("rm -f /tmp/stay_awake 2>/dev/null", shell=True)
            log(f"ffplay exit code: {res.returncode}")
            success = (res.returncode == 0)

        else:
            msg = "Hệ thống chưa cài RetroArch hoặc core FFMPEG!"
            log(msg)
            record_error(msg)
            return False

    except Exception as e:
        record_error(f"Loi khi thuc thi trinh phat video: {e}")
        return False

    finally:
        if saved_bl is not None:
            try:
                from . import backlight
                backlight.screen_on(saved_bl)
                log("Audio-only: da bat lai man hinh.")
            except Exception:
                pass
        if proxy_server:
            try:
                proxy_server.shutdown()
                proxy_server.server_close()
                log("Da dong Streaming Proxy bridge.")
            except Exception:
                pass
        for tmp_f in (ra_override_path, "/tmp/yt_stream_info.json", "/tmp/stay_awake"):
            try:
                if os.path.exists(tmp_f):
                    os.remove(tmp_f)
            except Exception:
                pass

    log(f"Hoan tat phien phat video.")
    return success


def run_session(session_path: str):
    """Play a queue of videos in order, advancing automatically.

    Runs inside the handoff process: the app has already exited, so this owns
    the whole viewing session until the queue ends or the user exits early.
    """
    from . import playback
    from .player import get_backend

    sess = playback.load_session_file(session_path)
    if not sess or not sess.queue:
        log("Session rong hoac khong doc duoc, khong co gi de phat.")
        return

    backend = get_backend()
    log(f"Bat dau phien phat: {len(sess.queue)} video, bat dau tu #{sess.index + 1}")

    while True:
        v = sess.current()
        if not v:
            break

        vid = v.get("id")
        dur = playback.duration_seconds(v.get("duration"))
        start = playback.resume_position(vid, dur)
        if start > 0 and not backend.capabilities.get("seek_absolute"):
            start = 0.0  # backend cannot seek yet; stored position is display-only

        sess.state = "playing"
        playback.save_session_file(session_path, sess)
        log(f"Phat [{sess.index + 1}/{len(sess.queue)}]: {v.get('title', vid)}")

        t0 = time.time()
        try:
            ok = backend.play(v, start=start, audio_only=sess.audio_only,
                              duration=dur, session=sess)
        except Exception as e:
            record_error(f"Loi phat video {vid}: {e}")
            ok = False
        elapsed = time.time() - t0

        playback.add_watched(v, elapsed)
        if dur > 0:
            pos = min(elapsed, float(dur))
            if (dur - pos) < playback.RESUME_TAIL:
                playback.clear_progress(vid)
            elif pos >= playback.RESUME_MIN_POS:
                playback.set_progress(vid, pos, dur, v.get("title", ""), v.get("channel", ""))
        else:
            playback.set_progress(vid, elapsed, 0, v.get("title", ""), v.get("channel", ""))

        # A natural end means we played at least the video's duration (minus a
        # small margin). Anything shorter means the user exited early.
        # Khong biet thoi luong thi coi nhu ket thuc khi da phat du lau, neu khong
        # ca hang doi se dung sau video dau tien.
        ended = (dur > 0 and elapsed >= (dur - 5)) or (dur <= 0 and elapsed >= 30)
        if not ended:
            log("Nguoi dung thoat giua video hoac phat loi, ket thuc phien.")
            break
        if not sess.advance():
            log("Het hang doi.")
            break
        playback.save_session_file(session_path, sess)

    sess.state = "idle"
    playback.save_session_file(session_path, sess)
    log("Ket thuc phien phat.")


if __name__ == "__main__":
    import argparse
    import json

    parser = argparse.ArgumentParser(description="RetroHub YouTube Player")
    parser.add_argument("video_id", nargs="?", default=None, help="YouTube Video ID or URL")
    parser.add_argument("--session", default=None, help="Play a saved playback session (queue)")
    parser.add_argument("--stream-url", default=None, help="Pre-extracted direct stream URL")
    parser.add_argument("--title", default=None, help="Video title")
    parser.add_argument("--info-file", default=None, help="Path to JSON file with stream info")

    args = parser.parse_args()

    if args.session:
        run_session(args.session)
        sys.exit(0)

    v_id = (args.video_id or "").strip()
    if not v_id:
        parser.error("video_id is required when --session is not given")
    if "v=" in v_id:
        v_id = v_id.split("v=")[1].split("&")[0]
    elif "youtu.be/" in v_id:
        v_id = v_id.split("youtu.be/")[1].split("?")[0]

    s_url = args.stream_url
    s_title = args.title

    if args.info_file and os.path.exists(args.info_file):
        try:
            with open(args.info_file, "r", encoding="utf-8") as f:
                inf = json.load(f)
            if isinstance(inf, dict):
                s_url = inf.get("stream_url") or s_url
                s_title = inf.get("title") or s_title
                v_id = inf.get("video_id") or v_id
        except Exception as e:
            log(f"Loi doc info file {args.info_file}: {e}")

    play_video(v_id, direct_stream_url=s_url, direct_title=s_title)
