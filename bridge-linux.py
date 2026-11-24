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
import urllib.request
import urllib.parse

DEFAULT_CLIENT_ID = "631447533323026432"
CLIENT_ID = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DISCORD_CLIENT_ID", DEFAULT_CLIENT_ID)
DEFAULT_ICON = "https://raw.githubusercontent.com/egoist/mygo-music/main/resources/icon.png"
DOWNLOAD_URL = "https://music.egoist.dev/"
cover_cache = {}

def log(msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[{ts}] [discord-mygo-music-native-linux] {msg}", flush=True)

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

log(f"Starting Linux Native Discord RPC Bridge (Client ID: {CLIENT_ID})")

# -------------------------------------------------------------
# 2. Session & Track Resolution
# -------------------------------------------------------------
home = os.path.expanduser("~")
config_dir = os.environ.get("XDG_CONFIG_HOME", os.path.join(home, ".config"))
session_path = os.path.join(config_dir, "MyGo Music", "session.json")

cached_session = None
last_session_mtime = 0

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
    except Exception:
        pass
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

def search_cover(title, artist):
    if not title:
        return None
    cache_key = f"{title}|{artist}"
    if cache_key in cover_cache:
        return cover_cache[cache_key]

    try:
        query = urllib.parse.quote(f"{title} {artist}".strip())
        url = f"https://music.163.com/api/cloudsearch/pc?s={query}&type=1&limit=3&offset=0"
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36",
            "Referer": "https://music.163.com/",
        })
        with urllib.request.urlopen(req, timeout=2.5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            songs = data.get("result", {}).get("songs", [])
            if songs and len(songs) > 0:
                song = songs[0]
                pic = (song.get("al") or song.get("album") or {}).get("picUrl")
                if pic:
                    pic = re.sub(r"^http://", "https://", pic)
                    cover_cache[cache_key] = pic
                    return pic
    except Exception:
        pass

    cover_cache[cache_key] = None
    return None

def resolve_track_details(title, artist, force_reload=False):
    sess = get_session_data(force_reload)
    if not sess or not isinstance(sess.get("queue"), list) or len(sess["queue"]) == 0:
        return None

    n_title = normalize_text(title)
    n_artist = normalize_text(artist)
    c_title = clean_title(title)

    # 1. Check current queue pointer
    idx = sess.get("at", 0) if isinstance(sess.get("at"), int) else 0
    if sess.get("shuffle") and isinstance(sess.get("order"), list) and len(sess["order"]) > idx:
        idx = sess["order"][idx]

    queue = sess["queue"]
    if idx < len(queue):
        cur = queue[idx]
        if cur and cur.get("name"):
            cur_n_title = normalize_text(cur["name"])
            cur_c_title = clean_title(cur["name"])
            if cur_n_title == n_title or (c_title and cur_c_title == c_title):
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

        score = 0
        artist_matches = (not n_artist) or (n_artist in tn_artist) or (tn_artist in n_artist)

        if tn_title == n_title and artist_matches:
            score = 100
        elif c_title and tc_title == c_title and artist_matches:
            score = 90
        elif tn_title == n_title:
            score = 80
        elif c_title and tc_title == c_title:
            score = 75
        elif c_title and (c_title in tc_title or tc_title in c_title) and artist_matches:
            score = 60

        if score > best_score:
            best_score = score
            best = t

    return best if best_score >= 60 else None

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

    if "music.youtube.com" in lu or s in ["youtube-music", "ytmusic"]:
        return "YouTube Music"
    if "youtube.com" in lu or "youtu.be" in lu or s == "youtube":
        return "YouTube"
    if "spotify.com" in lu or s in ["spotify", "mygotify"]:
        return "Spotify"
    if "163.com" in lu or "netease" in s or s in ["163", "cloudmusic"]:
        return "NetEase"
    if "bilibili.com" in lu or s == "bilibili":
        return "Bilibili"
    if "soundcloud.com" in lu or s == "soundcloud":
        return "SoundCloud"
    if "music.apple.com" in lu or s in ["apple", "applemusic"]:
        return "Apple Music"
    if "bandcamp.com" in lu or s == "bandcamp":
        return "Bandcamp"
    if "deezer.com" in lu or s == "deezer":
        return "Deezer"
    if "tidal.com" in lu or s == "tidal":
        return "Tidal"
    if "qq.com" in lu or "qqmusic" in s or s == "qq":
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
            header = struct.pack("<ii", opcode, len(body))
            self.sock.sendall(header + body)
            return True
        except Exception as e:
            log(f"Send frame error: {e}")
            self.close()
            return False

    def handshake(self):
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
                    if opcode == 1 and msg.get("evt") == "READY":
                        log("Discord RPC Ready!")
                        self.handshaked = True
                        if callable(self.on_ready):
                            self.on_ready()
                    elif opcode == 3:
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
retry_delays = [0.15, 0.45, 1.0, 2.0]
retry_attempt = 0
pending_retry_time = 0
last_track_obj = None

def update_activity(track):
    global last_activity_key, active_track_key, active_start_time, current_track
    global pending_retry_time, last_track_obj, retry_attempt

    current_track = track

    if not ipc.handshaked:
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

    # Cross-reference with session.json
    details = resolve_track_details(track.get("title"), track.get("artist"))
    if dur_sec == 0 and details and details.get("duration", 0) > 0:
        dur_sec = int(details["duration"] / 1000)

    end_sec = track.get("endTime", 0)
    if not end_sec and dur_sec > 0 and start_sec > 0:
        end_sec = start_sec + dur_sec

    song_url = track.get("url") or (details.get("url") if details else None)
    song_source = details.get("source") if details else None
    if not song_source and track.get("source") and "mygo" not in track.get("source", "").lower():
        song_source = track["source"]

    # Synthesize URL if missing
    if not song_url and details and details.get("id"):
        s = (song_source or "").lower()
        t_id = details["id"]
        if s in ["youtube-music", "ytmusic", "youtube"]:
            song_url = f"https://music.youtube.com/watch?v={t_id}"
        elif s in ["spotify", "mygotify"]:
            song_url = f"https://open.spotify.com/track/{t_id}"
        elif "netease" in s or s in ["163", "cloudmusic"]:
            song_url = f"https://music.163.com/#/song?id={t_id}"
        elif s == "bilibili":
            song_url = f"https://www.bilibili.com/video/{t_id}"

    source_label = format_source_label(song_source, song_url)

    # Artwork resolution with online fallback search
    cover_url = track.get("imageUrl") or (details.get("album", {}).get("imageUrl") if details else None)
    if not cover_url:
        cover_url = search_cover(track.get("title"), track.get("artist"))
    if not cover_url:
        cover_url = DEFAULT_ICON

    # Schedule background retry if details or cover not resolved yet
    if not is_paused and (not details or not song_url or cover_url == DEFAULT_ICON):
        if retry_attempt < len(retry_delays):
            pending_retry_time = time.time() + retry_delays[retry_attempt]
            last_track_obj = track

    key = f"{track.get('title')}|{track.get('artist')}|{track.get('album')}|{track.get('status')}|{is_paused}|{start_sec}|{source_label}|{song_url}|{cover_url}"
    if key == last_activity_key:
        return

    header_name = f"{track.get('artist')} - {track.get('title')}" if track.get("artist") else track.get("title")

    activity = {
        "type": 2,
        "name": header_name,
        "details": track.get("title"),
        "state": f"{track.get('artist')} (Paused)" if is_paused else track.get("artist"),
        "assets": {
            "large_image": cover_url,
            "large_text": track.get("album") or track.get("title"),
            "small_image": DEFAULT_ICON,
            "small_text": "MyGo Music (Paused)" if is_paused else "MyGo Music",
        },
    }

    if not is_paused and start_sec > 0:
        activity["timestamps"] = {"start": start_sec}
        if end_sec > start_sec:
            activity["timestamps"]["end"] = end_sec

    buttons = []
    if source_label and song_url and re.match(r"^https?://", song_url):
        buttons.append({"label": f"Listen on {source_label}", "url": song_url})
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
        log(f"Updated Discord Presence: \"{track.get('title')}\" by {track.get('artist')} ({track.get('status')}) {btn_desc} {cov_desc}")

def on_ipc_ready():
    global last_activity_key
    last_activity_key = ""
    if current_track:
        update_activity(current_track)

ipc.on_ready = on_ipc_ready

# -------------------------------------------------------------
# 6. Main Loop
# -------------------------------------------------------------
log("Native Linux Bridge active. Monitoring MPRIS2 and Discord IPC...")

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

    time.sleep(0.3)
