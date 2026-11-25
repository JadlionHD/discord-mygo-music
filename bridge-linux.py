#!/usr/bin/env python3
"""
bridge-linux.py - Native Linux Discord Rich Presence Bridge for MyGo Music
100% Native: Zero Node.js, Bun, or Deno required.
Zero external pip packages: standard library only (socket, struct, json, os, sys, time, subprocess, re, urllib).
"""

import os
import sys
import time
import json
import socket
import struct
import subprocess
import re
import signal
import urllib.parse

DEFAULT_CLIENT_ID = "631447533323026432"
IS_DEBUG = (
    "--debug" in sys.argv
    or "-debug" in sys.argv
    or "-d" in sys.argv
    or "-Debug" in sys.argv
    or os.environ.get("DISCORD_RPC_DEBUG") == "1"
)
non_flag_args = [a for a in sys.argv[1:] if not a.startswith("-")]
CLIENT_ID = non_flag_args[0] if len(non_flag_args) > 0 else os.environ.get("DISCORD_CLIENT_ID", DEFAULT_CLIENT_ID)
DEFAULT_ICON = "https://raw.githubusercontent.com/egoist/mygo-music/main/resources/icon.png"
DOWNLOAD_URL = "https://music.egoist.dev/"

def log(msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[{ts}] [discord-mygo-music-native-linux] {msg}", flush=True)

def debug_log(msg):
    if IS_DEBUG:
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        print(f"[{ts}] [discord-mygo-music-debug] {msg}", flush=True)

# -------------------------------------------------------------
# 1. Single Instance Protection
# -------------------------------------------------------------
pid_file = "/tmp/discord-mygo-music.pid"
try:
    if os.path.exists(pid_file):
        with open(pid_file, "r") as f:
            old_pid = int(f.read().strip())
        if old_pid != os.getpid():
            try:
                os.kill(old_pid, signal.SIGTERM)
                log(f"Terminated stale bridge instance (PID {old_pid})")
            except OSError:
                pass
    with open(pid_file, "w") as f:
        f.write(str(os.getpid()))
except Exception:
    pass

log(f"Starting Linux Native Discord RPC Bridge (Client ID: {CLIENT_ID}, Debug: {'ENABLED' if IS_DEBUG else 'DISABLED'})")

# -------------------------------------------------------------
# 2. Session & Track Resolution
# -------------------------------------------------------------
home = os.path.expanduser("~")
config_dir = os.environ.get("XDG_CONFIG_HOME", os.path.join(home, ".config"))
session_path = os.path.join(config_dir, "MyGo Music", "session.json")

cached_session = None
last_session_mtime = 0

settings_path = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")) + "/MyGo Music/settings.json"
cached_active_source = None
last_settings_mtime = 0

def get_active_source(force_reload=False):
    global cached_active_source, last_settings_mtime
    if not os.path.exists(settings_path):
        return None
    try:
        mtime = os.path.getmtime(settings_path)
        if not force_reload and cached_active_source and mtime == last_settings_mtime:
            return cached_active_source
        with open(settings_path, "r", encoding="utf-8") as f:
            content = f.read().strip()
            if content:
                data = json.loads(content)
                if data and data.get("source"):
                    cached_active_source = data["source"]
                    last_settings_mtime = mtime
                    return cached_active_source
    except Exception as e:
        debug_log(f"Error reading settings.json: {e}")
    return cached_active_source

def get_session_data(force_reload=False):
    global cached_session, last_session_mtime
    if not os.path.exists(session_path):
        return None
    try:
        mtime = os.path.getmtime(session_path)
        if not force_reload and cached_session and mtime == last_session_mtime:
            return cached_session
        with open(session_path, "r", encoding="utf-8") as f:
            content = f.read().strip()
            if content:
                cached_session = json.loads(content)
                last_session_mtime = mtime
                return cached_session
    except Exception as e:
        debug_log(f"Error reading session.json: {e}")
    return cached_session

def normalize_text(text):
    if not text:
        return ""
    return re.sub(r"[^\w]", "", text.lower())

def clean_title(text):
    if not text:
        return ""
    cleaned = re.sub(r"\s*[\(\[](feat\.?|ft\.?|official|video|mv|audio|remix|lyrics?|full version).*?[\)\]]", "", text, flags=re.IGNORECASE)
    return re.sub(r"[^\w]", "", cleaned.lower())

def resolve_track_details(title, artist, force_reload=False):
    sess = get_session_data(force_reload)
    if not sess or not isinstance(sess.get("queue"), list) or len(sess["queue"]) == 0:
        return None

    active_source = get_active_source(force_reload)

    n_title = normalize_text(title)
    n_artist = normalize_text(artist)
    c_title = clean_title(title)

    # 1. Check current queue pointer and surrounding indices first (+/- 2 items)
    raw_at = sess.get("at", 0) if isinstance(sess.get("at"), int) else 0
    check_indices = [raw_at, raw_at + 1, raw_at - 1, raw_at + 2, raw_at - 2]
    queue = sess["queue"]

    for test_at in check_indices:
        if test_at < 0:
            continue
        idx = test_at
        if sess.get("shuffle") and isinstance(sess.get("order"), list) and len(sess["order"]) > idx:
            idx = sess["order"][idx]
        if idx < len(queue):
            cur = queue[idx]
            if cur and cur.get("name"):
                cur_n_title = normalize_text(cur["name"])
                cur_c_title = clean_title(cur["name"])
                cur_artists = " ".join([a.get("name", "") for a in cur.get("artists", [])]) if isinstance(cur.get("artists"), list) else ""
                cur_n_artist = normalize_text(cur_artists)

                title_match = (cur_n_title == n_title) or (c_title and cur_c_title == c_title) or \
                              (n_title and n_title in cur_n_title) or (cur_n_title and cur_n_title in n_title)
                artist_match = (not n_artist) or (not cur_n_artist) or (n_artist in cur_n_artist) or (cur_n_artist in n_artist)

                if title_match and artist_match:
                    if not active_source or not cur.get("source") or cur.get("source") == active_source or cur_n_title == n_title:
                        return cur

    # 2. Score candidate matches
    best = None
    best_score = 0
    for t in queue:
        t_name = t.get("name", "")
        t_artists = " ".join([a.get("name", "") for a in t.get("artists", [])]) if isinstance(t.get("artists"), list) else ""
        tn_title = normalize_text(t_name)
        tn_artist = normalize_text(t_artists)
        tc_title = clean_title(t_name)

        has_both_artists = len(n_artist) >= 2 and len(tn_artist) >= 2
        artist_match = (n_artist in tn_artist or tn_artist in n_artist) if has_both_artists else True

        if has_both_artists and not artist_match:
            continue

        source_matches = (not active_source) or (not t.get("source")) or (t.get("source") == active_source)

        score = 0
        if tn_title == n_title and artist_match:
            score = 100 if source_matches else 70
        elif c_title and tc_title == c_title and artist_match:
            score = 90 if source_matches else 65
        elif c_title and (c_title in tc_title or tc_title in c_title) and artist_match:
            score = 80 if source_matches else 55
        elif tn_title == n_title and not has_both_artists:
            score = 70 if source_matches else 50

        if score > best_score:
            best_score = score
            best = t

    return best if best_score >= 65 else None

def synthesize_track_url(source, track_id, title, artist):
    s = (source or "").lower().strip()
    q = urllib.parse.quote(f"{title or ''} {artist or ''}".strip())

    if s in ["youtube-music", "ytmusic", "youtube"]:
        if track_id:
            return f"https://music.youtube.com/watch?v={track_id}"
        if q:
            return f"https://music.youtube.com/search?q={q}"
    elif s in ["spotify", "mygotify"]:
        if track_id:
            return f"https://open.spotify.com/track/{track_id}"
        if q:
            return f"https://open.spotify.com/search/{q}"
    elif "netease" in s or s in ["163", "cloudmusic"]:
        if track_id:
            return f"https://music.163.com/#/song?id={track_id}"
        if q:
            return f"https://music.163.com/#/search/m/?s={q}&type=1"
    elif s == "bilibili":
        if track_id:
            return f"https://www.bilibili.com/video/{track_id}"
        if q:
            return f"https://search.bilibili.com/all?keyword={q}"
    return None

def format_source_label(source, url):
    s = (source or "").lower().strip()
    u = (url or "").strip()

    if s in ["local", "file", "offline", "library", "my-computer"]:
        return None
    if not u or not re.match(r"^https?://", u, re.IGNORECASE):
        return None

    lu = u.lower()
    if "localhost" in lu or "127.0.0.1" in lu or "::1" in lu:
        return None

    # 1. URL domain authority
    if "music.youtube.com" in lu:
        return "YouTube Music"
    if "youtube.com" in lu or "youtu.be" in lu:
        return "YouTube"
    if "spotify.com" in lu:
        return "Spotify"
    if "163.com" in lu or "music.126.net" in lu:
        return "NetEase"
    if "bilibili.com" in lu:
        return "Bilibili"
    if "soundcloud.com" in lu:
        return "SoundCloud"
    if "music.apple.com" in lu:
        return "Apple Music"
    if "bandcamp.com" in lu:
        return "Bandcamp"
    if "deezer.com" in lu:
        return "Deezer"
    if "tidal.com" in lu:
        return "Tidal"
    if "qq.com" in lu:
        return "QQ Music"

    # 2. Source parameter fallback
    if s in ["youtube-music", "ytmusic"]:
        return "YouTube Music"
    if s == "youtube":
        return "YouTube"
    if s in ["spotify", "mygotify"]:
        return "Spotify"
    if "netease" in s or s in ["163", "cloudmusic"]:
        return "NetEase"
    if s == "bilibili":
        return "Bilibili"
    if s == "soundcloud":
        return "SoundCloud"
    if s in ["apple", "applemusic"]:
        return "Apple Music"
    if s == "bandcamp":
        return "Bandcamp"
    if s == "deezer":
        return "Deezer"
    if s == "tidal":
        return "Tidal"
    if "qqmusic" in s or s == "qq":
        return "QQ Music"

    if source and s not in ["web", "stream", "unknown", "http", "https", "mpris", "mediaremote"] and "mygo" not in s:
        clean = re.sub(r"[-_]+", " ", source).strip()
        return clean.title()[:20]

    return None

# -------------------------------------------------------------
# 3. Discord IPC Connection
# -------------------------------------------------------------
def get_ipc_candidates():
    candidates = []
    dirs = [
        os.environ.get("XDG_RUNTIME_DIR"),
        os.environ.get("TMPDIR"),
        os.environ.get("TMP"),
        os.environ.get("TEMP"),
        "/tmp",
    ]
    for d in dirs:
        if d and os.path.isdir(d):
            for i in range(10):
                candidates.append(os.path.join(d, f"discord-ipc-{i}"))
    return candidates

class DiscordIPC:
    def __init__(self, client_id):
        self.client_id = client_id
        self.sock = None
        self.handshaked = False
        self.on_ready = None

    def connect(self):
        for path in get_ipc_candidates():
            if os.path.exists(path):
                try:
                    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    s.settimeout(1.0)
                    s.connect(path)
                    s.setblocking(False)
                    self.sock = s
                    log(f"Connected to Discord IPC: {path}")
                    self.handshake()
                    return True
                except Exception:
                    try:
                        s.close()
                    except Exception:
                        pass
        return False

    def send_frame(self, opcode, payload):
        if not self.sock:
            return False
        try:
            body = json.dumps(payload, separators=(',', ':')).encode("utf-8")
            if opcode == 1 and payload.get("cmd") == "SET_ACTIVITY":
                debug_log(f"Sending SET_ACTIVITY frame: {body.decode('utf-8')}")
            header = struct.pack("<ii", opcode, len(body))
            self.sock.sendall(header + body)
            return True
        except Exception as e:
            log(f"Send frame error: {e}")
            self.close()
            return False

    def handshake(self):
        debug_log(f"Dispatching Discord IPC Handshake (Opcode 0, Client ID: {self.client_id})")
        self.send_frame(0, {"v": 1, "client_id": self.client_id})

    def check_incoming(self):
        if not self.sock:
            return
        try:
            while True:
                header = self.sock.recv(8)
                if not header or len(header) < 8:
                    break
                opcode, length = struct.unpack("<ii", header)
                body = b""
                while len(body) < length:
                    chunk = self.sock.recv(length - len(body))
                    if not chunk:
                        break
                    body += chunk

                try:
                    msg = json.loads(body.decode("utf-8"))
                    if opcode == 1:
                        if msg.get("evt") == "READY":
                            log("Discord RPC Ready!")
                            self.handshaked = True
                            if callable(self.on_ready):
                                self.on_ready()
                        elif msg.get("evt") == "ERROR":
                            err_data = msg.get("data", {})
                            log(f"DISCORD RPC ERROR: Code {err_data.get('code')} - {err_data.get('message')}")
                        else:
                            debug_log(f"Discord Frame (Opcode 1): {msg}")
                    elif opcode == 3:
                        debug_log("Received PING, replying PONG")
                        self.send_frame(4, msg)
                    elif opcode == 2:
                        log("Discord closed connection")
                        self.close()
                        break
                except Exception:
                    pass
        except (BlockingIOError, InterruptedError):
            pass
        except Exception as e:
            log(f"IPC socket read error: {e}")
            self.close()

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None
        self.handshaked = False

# -------------------------------------------------------------
# 4. Media Monitor (MPRIS2 playerctl & session.json)
# -------------------------------------------------------------
def query_playerctl():
    try:
        cmd = ["playerctl", "metadata", "--format", "{{playerName}}\t{{status}}\t{{position}}\t{{mpris:length}}\t{{title}}\t{{artist}}\t{{album}}\t{{mpris:artUrl}}"]
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=1.0)
        if res.returncode == 0 and res.stdout.strip():
            lines = res.stdout.strip().split("\n")
            for line in lines:
                parts = line.split("\t")
                if len(parts) >= 6:
                    player, status, pos_str, len_str, title, artist = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
                    album = parts[6] if len(parts) > 6 else ""
                    art_url = parts[7] if len(parts) > 7 else ""

                    if "mygo" in player.lower() or "egoist" in player.lower():
                        pos = float(pos_str) / 1000000.0 if pos_str.isdigit() else 0.0
                        dur = float(len_str) / 1000000.0 if len_str.isdigit() else 0.0
                        now_sec = int(time.time())
                        start_sec = now_sec - int(round(pos))
                        debug_log(f"MPRIS2 matched MyGo: \"{title}\" by \"{artist}\" ({status})")
                        return {
                            "source": player,
                            "title": title,
                            "artist": artist,
                            "album": album,
                            "status": status,
                            "position": pos,
                            "duration": dur,
                            "startTime": start_sec,
                            "endTime": (start_sec + int(dur)) if dur > 0 else 0,
                            "url": None,
                            "imageUrl": art_url or None,
                        }
    except Exception:
        pass
    return None

def query_session_fallback():
    sess = get_session_data(False)
    if sess and isinstance(sess.get("queue"), list) and len(sess["queue"]) > 0:
        idx = sess.get("at", 0) if isinstance(sess.get("at"), int) else 0
        if sess.get("shuffle") and isinstance(sess.get("order"), list) and len(sess["order"]) > idx:
            idx = sess["order"][idx]
        if idx < len(sess["queue"]):
            cur = sess["queue"][idx]
            if cur and cur.get("name"):
                artists = ", ".join([a.get("name", "") for a in cur.get("artists", [])]) if isinstance(cur.get("artists"), list) else ""
                dur = float(cur.get("duration", 0)) / 1000.0
                pos = float(sess.get("position", 0)) / 1000.0
                now_sec = int(time.time())
                start_sec = now_sec - int(round(pos))
                return {
                    "source": cur.get("source", "MyGo Music"),
                    "title": cur.get("name"),
                    "artist": artists,
                    "album": cur.get("album", {}).get("name", ""),
                    "status": "Playing",
                    "position": pos,
                    "duration": dur,
                    "startTime": start_sec,
                    "endTime": (start_sec + int(dur)) if dur > 0 else 0,
                    "url": cur.get("url"),
                    "imageUrl": cur.get("album", {}).get("imageUrl"),
                }
    return None

# -------------------------------------------------------------
# 5. Activity Dispatcher
# -------------------------------------------------------------
ipc = DiscordIPC(CLIENT_ID)
last_activity_key = ""
last_meta_key = ""
last_start_sec = 0
missing_count = 0
active_track_key = ""
active_start_time = 0
current_track = None
retry_delays = [0.2, 0.5, 1.0, 2.0, 4.0, 8.0]
retry_attempt = 0
pending_retry_time = 0
last_track_obj = None

def update_activity(track):
    global last_activity_key, active_track_key, active_start_time, current_track
    global pending_retry_time, last_track_obj, retry_attempt

    current_track = track

    if not ipc.handshaked:
        debug_log(f"Handshake not complete yet; cached track \"{track.get('title') if track else ''}\"")
        return

    if not track or track.get("status") == "Stopped":
        if last_activity_key != "__cleared":
            ipc.send_frame(1, {
                "cmd": "SET_ACTIVITY",
                "args": {"pid": os.getpid(), "activity": None},
                "nonce": str(time.time()),
            })
            last_activity_key = "__cleared"
            active_track_key = ""
            active_start_time = 0
            pending_retry_time = 0
            retry_attempt = 0
            log("Presence cleared (playback stopped)")
        return

    is_paused = track.get("status") == "Paused"
    pos_sec = int(track.get("position", 0))
    dur_sec = int(track.get("duration", 0))
    now_sec = int(time.time())

    track_key = f"{track.get('title')}|{track.get('artist')}"
    start_sec = track.get("startTime", 0)

    if not start_sec and not is_paused:
        if active_track_key == track_key and active_start_time > 0 and abs(now_sec - pos_sec - active_start_time) < 3:
            start_sec = active_start_time
        else:
            start_sec = now_sec - pos_sec

    if not is_paused and start_sec > 0:
        active_track_key = track_key
        active_start_time = start_sec
    elif is_paused:
        active_track_key = track_key

    # Cross-reference with session.json and active settings source
    details = resolve_track_details(track.get("title"), track.get("artist"), False)
    active_source = get_active_source(False)

    if details:
        debug_log(f"Matched session queue item: \"{details.get('name')}\" (Source: {details.get('source')})")
    else:
        debug_log(f"No session.json queue match for \"{track.get('title')}\" by \"{track.get('artist')}\" (Active source: {active_source})")

    if dur_sec == 0 and details and details.get("duration", 0) > 0:
        dur_sec = int(details["duration"] / 1000)

    end_sec = track.get("endTime", 0)
    if not end_sec and dur_sec > 0 and start_sec > 0:
        end_sec = start_sec + dur_sec

    song_url = track.get("url") or (details.get("url") if details else None)
    song_source = details.get("source") if details else None
    if not song_source and active_source:
        song_source = active_source
    elif not song_source and track.get("source") and "mygo" not in track.get("source", "").lower():
        song_source = track["source"]

    # Synthesize URL if missing using details.id or search query
    if not song_url and song_source:
        song_id = details.get("id") if details else None
        song_url = synthesize_track_url(song_source, song_id, track.get("title"), track.get("artist"))
        if song_url:
            debug_log(f"Synthesized {song_source} URL: {song_url}")

    source_label = format_source_label(song_source, song_url)

    # Artwork resolution with online fallback search
    raw_cover = track.get("imageUrl") or (details.get("album", {}).get("imageUrl") if details else None)
    cover_url = None
    if raw_cover and re.match(r"^https?://", raw_cover):
        cover_url = raw_cover
    elif raw_cover:
        debug_log(f"Filtered out local/non-HTTP cover URL: {raw_cover}")

    if not cover_url or not re.match(r"^https?://", cover_url):
        debug_log("Using default icon for cover art")
        cover_url = DEFAULT_ICON

    # Schedule multi-stage background retry if online details, direct track URL, or real cover not found immediately
    has_direct_url = bool(song_url and re.search(r"watch\?v=|/track/|/song\?id=|/video/", song_url))
    if not details or not has_direct_url or cover_url == DEFAULT_ICON:
        if retry_attempt < len(retry_delays):
            pending_retry_time = time.time() + retry_delays[retry_attempt]
            last_track_obj = track
            debug_log(f"Scheduled retry stage {retry_attempt + 1} in {retry_delays[retry_attempt]}s")

    key = f"{track.get('title')}|{track.get('artist')}|{track.get('album')}|{track.get('status')}|{is_paused}|{start_sec}|{source_label}|{song_url}|{cover_url}"
    if key == last_activity_key:
        return

    # Discord RPC Payload Sanitization (Strict Schema Compliance)
    title_str = str(track.get("title") or "")
    if len(title_str) < 2:
        title_str = f"{title_str} "
    if len(title_str) > 128:
        title_str = title_str[:125] + "..."
        debug_log(f"Title truncated to 128 characters: {title_str}")

    artist_str = str(track.get("artist") or "")
    state_str = f"{artist_str} (Paused)" if (is_paused and artist_str) else ("Paused" if is_paused else artist_str)

    header_name = f"{artist_str} - {title_str}" if artist_str else title_str
    if len(header_name) > 128:
        header_name = header_name[:125] + "..."

    activity = {
        "type": 2,
        "name": header_name,
        "details": title_str,
    }

    # Discord rejects empty state (""). Omit if empty or < 2 characters
    if state_str and len(state_str.strip()) >= 2:
        if len(state_str) > 128:
            state_str = state_str[:125] + "..."
        activity["state"] = state_str
    else:
        debug_log("Omitted state property (artist empty or < 2 characters to satisfy Discord validation)")

    large_text = str(track.get("album") or title_str)
    if len(large_text) > 128:
        large_text = large_text[:125] + "..."
    if len(large_text) < 2:
        large_text = f"{large_text} "

    activity["assets"] = {
        "large_image": cover_url,
        "large_text": large_text,
        "small_image": DEFAULT_ICON,
        "small_text": "MyGo Music (Paused)" if is_paused else "MyGo Music",
    }

    if not is_paused and start_sec > 0:
        activity["timestamps"] = {"start": start_sec}
        if end_sec > start_sec:
            activity["timestamps"]["end"] = end_sec

    # buttons: max 2 buttons, label <= 32 chars, url <= 512 chars (must be http/https)
    buttons = []
    if source_label and song_url and re.match(r"^https?://", song_url) and len(song_url) <= 512:
        b_label = f"Listen on {source_label}"
        if len(b_label) > 32:
            b_label = b_label[:32]
        buttons.append({"label": b_label, "url": song_url})
    buttons.append({"label": "Download MyGo Music", "url": DOWNLOAD_URL})

    activity["buttons"] = buttons
    activity["metadata"] = {"button_urls": [b["url"] for b in buttons]}

    frame = {
        "cmd": "SET_ACTIVITY",
        "args": {
            "pid": os.getpid(),
            "activity": activity,
        },
        "nonce": str(time.time()),
    }

    if ipc.send_frame(1, frame):
        last_activity_key = key
        btn_desc = f"[{source_label} + Download]" if source_label else "[Download only]"
        cov_desc = "[Cover: OK]" if cover_url != DEFAULT_ICON else "[Cover: Default]"
        log(f"Updated Discord Presence: \"{title_str}\" {('by ' + artist_str + ' ') if artist_str else ''}(Status: {track.get('status')}) {btn_desc} {cov_desc}")

def on_ipc_ready():
    global last_activity_key
    last_activity_key = ""
    if current_track:
        debug_log("Handshake finished, immediately updating queued track")
        update_activity(current_track)

ipc.on_ready = on_ipc_ready

# -------------------------------------------------------------
# 6. Graceful Shutdown & Cleanup Handler
# -------------------------------------------------------------
is_stopping = False

def cleanup(signum=None, frame=None):
    global is_stopping
    if is_stopping:
        return
    is_stopping = True

    log("Shutting down Linux Native Bridge (clearing Discord presence)...")
    try:
        if ipc and ipc.sock:
            ipc.send_frame(1, {
                "cmd": "SET_ACTIVITY",
                "args": {"pid": os.getpid(), "activity": None},
                "nonce": str(time.time()),
            })
            time.sleep(0.06)
            ipc.close()
    except Exception:
        pass
    try:
        if os.path.exists(pid_file):
            os.remove(pid_file)
    except Exception:
        pass
    log("Bridge shutdown complete.")
    if signum is not None:
        sys.exit(0)

signal.signal(signal.SIGINT, cleanup)
signal.signal(signal.SIGTERM, cleanup)

# -------------------------------------------------------------
# 7. Main Loop
# -------------------------------------------------------------
log("Native Linux Bridge active. Monitoring MPRIS2 and Discord IPC...")

try:
    while True:
        if not ipc.sock:
            ipc.connect()

        ipc.check_incoming()

        found = query_playerctl()
        if not found:
            found = query_session_fallback()

        if found and found.get("title"):
            missing_count = 0
            meta_key = f"{found.get('title')}|{found.get('artist')}|{found.get('album')}|{found.get('status')}"
            seek_changed = abs(found.get("startTime", 0) - last_start_sec) >= 2
            state_changed = meta_key != last_meta_key

            if state_changed or (found.get("status") == "Playing" and seek_changed):
                last_meta_key = meta_key
                last_start_sec = found.get("startTime", 0)
                retry_attempt = 0
                update_activity(found)
        else:
            missing_count += 1
            if missing_count >= 3 and last_meta_key != "__stopped":
                last_meta_key = "__stopped"
                last_start_sec = 0
                retry_attempt = 0
                debug_log(f"No media detected after {missing_count} ticks, clearing presence")
                update_activity(None)

        # Asynchronous retry for enriched details & cover
        if pending_retry_time > 0 and time.time() >= pending_retry_time:
            pending_retry_time = 0
            retry_attempt += 1
            if last_track_obj and last_meta_key != "__stopped":
                fresh_details = resolve_track_details(last_track_obj.get("title"), last_track_obj.get("artist"), True)
                if fresh_details:
                    log(f"Enriched track details and artwork from session for \"{last_track_obj.get('title')}\"")
                    last_activity_key = ""
                    update_activity(last_track_obj)
                elif retry_attempt < len(retry_delays):
                    pending_retry_time = time.time() + retry_delays[retry_attempt]
                    debug_log(f"Rescheduled retry stage {retry_attempt + 1} in {retry_delays[retry_attempt]}s")

        time.sleep(0.3)
finally:
    cleanup()
