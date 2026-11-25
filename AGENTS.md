# AGENTS.md — Technical Architecture & AI Developer Guide

This document is the authoritative technical reference for AI assistants and developers maintaining or extending the `discord-mygo-music` plugin.

---

## 1. Core Architecture & Philosophy

- **Zero-Dependency Native First**: The plugin **must not** require or probe for external JavaScript runtimes (no Node.js, Bun, or Deno).
- **Built-in OS Engines**: Each operating system runs a standalone native helper script using pre-installed system binaries:
  - **Windows**: PowerShell 5.1+ (`powershell.exe`) with .NET Framework and WinRT APIs.
  - **Linux**: Python 3 standard library (`python3`, zero pip packages).
  - **macOS**: Swift standard library (`swift`) with Foundation and POSIX APIs.
- **Local IPC Only**: Direct socket/pipe communication with the local Discord client.
- **Strict 3-Platform Parity**: Any bug fix, feature addition, or protocol adjustment made to one platform must be identically implemented across all three (`.ps1`, `.py`, `.swift`).

---

## 2. File Structure & Responsibilities

```text
discord-mygo-music/
├── plugin.json          # MyGo Music plugin manifest (permissions, settings, navigation)
├── index.js             # Host loader: UI rendering, lifecycle orchestration, platform bridge spawner
├── bridge-windows.ps1   # Windows native bridge (PowerShell + WinRT GSMTC + NamedPipe)
├── bridge-linux.py      # Linux native bridge (Python 3 + MPRIS2 + Unix domain socket)
├── bridge-macos.swift   # macOS native bridge (Swift + MediaRemote + Unix domain socket)
├── locales/             # Built-in i18n localization dictionaries (DO NOT MODIFY)
├── LICENSE              # AGPL-3.0 License
├── PRIVACY.md           # User privacy policy (Local-first, zero telemetry)
├── README.md            # Concise, user-facing setup & usage documentation
└── AGENTS.md            # Technical specifications & AI developer guidelines (this file)
```

---

## 3. Platform Implementations

### Windows (`bridge-windows.ps1`)
- **Runtime**: Windows PowerShell 5.1+ (`powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ...`).
- **Discord IPC**: Connects via `System.IO.Pipes.NamedPipeClientStream` to `\\.\pipe\discord-ipc-*` (probes 0–9).
- **Non-blocking Pipe Check**: P/Invokes `kernel32.dll` `PeekNamedPipe` to check available bytes before reading, preventing thread hangs.
- **Media Tracking**: Queries WinRT GSMTC (`Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager`) for 0ms media state detection.
- **Queue Reading**: Reads `session.json` using `System.IO.FileStream` with `FileShare.ReadWrite` to eliminate file locking conflicts when MyGo Music writes to disk.

### Linux (`bridge-linux.py`)
- **Runtime**: Python 3 standard library (`python3`). Zero `pip` packages.
- **Discord IPC**: Connects via `socket.socket(socket.AF_UNIX)` to `$XDG_RUNTIME_DIR/discord-ipc-*` (fallback `/tmp/discord-ipc-*`).
- **Media Tracking**: Queries MPRIS2 metadata via `playerctl` CLI (`playerctl metadata --format ...`).
- **Queue Reading**: Reads `~/.config/MyGo Music/session.json`.

### macOS (`bridge-macos.swift`)
- **Runtime**: Swift interpreter (`swift bridge-macos.swift`).
- **Discord IPC**: Connects via POSIX `sockaddr_un` to `/tmp/discord-ipc-*` (or `$TMPDIR/discord-ipc-*`).
- **Media Tracking**: Uses private framework dynamic linking (`MediaRemote.framework`) or queue inspection.
- **Queue Reading**: Reads `~/Library/Application Support/MyGo Music/session.json`.

---

## 4. Discord IPC Protocol Specifications

### Binary Frame Structure
Every Discord IPC message consists of an **8-byte header** followed by a **UTF-8 JSON body**:
1. `Opcode` (Int32 Little-Endian, 4 bytes):
   - `0`: `HANDSHAKE` (client $\rightarrow$ Discord)
   - `1`: `FRAME` (bidirectional: `READY`, `SET_ACTIVITY`)
   - `2`: `CLOSE` (bidirectional)
   - `3`: `PING` (Discord $\rightarrow$ client)
   - `4`: `PONG` (client $\rightarrow$ Discord)
2. `Length` (Int32 Little-Endian, 4 bytes): Byte length of the JSON payload.
3. `Payload` (Byte array, `Length` bytes): Compact JSON string.

### Handshake Lifecycle & Startup Race Condition Prevention
1. The bridge immediately sends `Opcode 0`: `{"v":1,"client_id":"<ID>"}` upon connection.
2. The bridge **must not** consider the session active until Discord responds with `Opcode 1` containing `"evt":"READY"`.
3. **Critical Rule**: When media is detected before Discord responds with `READY`, store it in `currentTrack`. The moment `READY` is received, immediately dispatch `Update-Activity(currentTrack)`. Do not consume `$lastMetaKey` before handshake completion.

---

## 5. Timeline, Buttons & Artwork Rules

### Timeline Progress Bar Invariance
- Discord renders progress bars client-side based on `timestamps.start` and `timestamps.end`.
- Constantly advancing `timestamps.start` resets the scrubber to `00:00`.
- **Invariant Start Formula**:
  $$\text{startSec} = \text{LastUpdatedTime.ToUnixTimeSeconds()} - \text{Round}(\text{Position})$$
- **Seek Detection**: Only register a manual track seek if:
  $$|\text{newStartSec} - \text{lastStartSec}| \ge 2\text{ seconds}$$

### Action Buttons
1. **Button 1 (`Listen on {Source}`)**:
   - Points to the track's public web URL.
   - Synthesize online URLs if missing but ID is available:
     - `youtube-music` / `ytmusic` $\rightarrow$ `https://music.youtube.com/watch?v={id}`
     - `spotify` / `mygotify` $\rightarrow$ `https://open.spotify.com/track/{id}`
     - `netease` / `163` $\rightarrow$ `https://music.163.com/#/song?id={id}`
     - `bilibili` $\rightarrow$ `https://www.bilibili.com/video/{id}`
   - **Omission Rule**: If the source is `local`, `file`, `offline`, `library`, or lacks an `http://`/`https://` URL, **omit Button 1 entirely**.
2. **Button 2 (`Download MyGo Music`)**:
   - Always present: `https://music.egoist.dev/`.

### Album Art Resolution & Fallback
1. Prefer `details.album.imageUrl` from `session.json`.
2. If missing or null, execute an anonymous query to NetEase Cloud Music API (`https://music.163.com/api/cloudsearch/pc?s={title}+{artist}&type=1&limit=3&offset=0`) to retrieve HD album art.
3. If search fails, fallback to default icon (`https://raw.githubusercontent.com/egoist/mygo-music/main/resources/icon.png`).
4. **Cache Key Requirement**: `$coverUrl` **must** be part of `$lastActivityKey`. When a cover resolves from default to HD, the changed key forces an immediate Discord update.

### Multi-Stage Retry Queue
When a track begins playing, GSMTC signals in 0ms, but `session.json` may flush 50–200ms later.
- If online details or artwork are not resolved on the first tick, schedule retry attempts at backoff intervals: `[150ms, 450ms, 1000ms, 2000ms]`.
- On each retry, reload `session.json` with `forceReload = true` and update the presence if enriched.

---

## 6. MyGo Music Lifecycle & Navigation Requirement

- MyGo Music plugins run within an isolated host environment.
- The entry point `index.js` exports `played({ id })`, `home()`, and `browse({ page })`.
- Because MyGo Music does not automatically execute background scripts on cold app start without user navigation:
  - Users must click the top-left source dropdown menu and select **Discord Rich Presence** (or **Discord Status**) once per app session to trigger `home()`, which spawns the native background bridge.
  - After spawning, the bridge runs independently as a system daemon and monitors GSMTC/MPRIS2 across all sources.

---

## 7. Developer Rules & Working Guidelines

1. **Development Directory**: All development occurs in `discord-mygo-music-dev`. Never modify `discord-mygo-music` (production) unless explicitly instructed by the user to sync.
2. **Locales Protection**: Never modify or delete files inside `locales/` (`en.json`, `en-US.json`, `id.json`, `id-ID.json`).
3. **No External Dependencies**: Never add `npm`, `pip`, or other external package manager dependencies. Standard libraries only.
4. **Single-Instance Mutex**: All native bridges must maintain a PID lock file (`discord-mygo-music.pid` in `%TEMP%` or `/tmp`) to terminate stale instances on startup.

---

## 8. Debug Mode & Discord RPC Schema Sanitization

### Debug Flag & Diagnostic Trace
- **Flags**: All bridges accept `-debug`, `--debug`, `-d`, or the environment variable `DISCORD_RPC_DEBUG=1`.
- **Plugin Setting**: `debugMode` in `plugin.json` passes the `-Debug` / `-debug` flag dynamically when spawned.
- **Verbose Output**:
  - Emits `[discord-mygo-music-debug]` logs detailing WinRT GSMTC/MPRIS2 session discovery, `session.json` queue matches, NetEase artwork searches, and raw `SET_ACTIVITY` frames.
  - Automatically captures and logs Discord RPC errors (`evt: "ERROR"`, Error Code `4000`, etc.).

### Strict Discord RPC Schema Sanitization
Discord RPC rejects payloads with Code `4000` if constraints are violated. All bridges must enforce:
1. **`details` (Title)**: Length must be between 2 and 128 characters (padded if length < 2, truncated to 125 + `...` if > 128).
2. **`state` (Artist)**: Discord **does not allow** an empty string `""`. If the track has no artist or artist is < 2 characters, **omit the `state` key entirely**. If length > 128, truncate to 125 + `...`.
3. **`assets.large_image`**: Must be a valid `http://` or `https://` URL. Local `file:///` URLs from `session.json` must be filtered out and fallback to NetEase search or default icon.
4. **`assets.large_text`**: Length between 2 and 128 characters.
5. **`buttons`**: Maximum 2 buttons. Label length $\le 32$ characters. URL length $\le 512$ characters (must match `^https?://`).

### Graceful Shutdown (Ctrl+C & Process Exit)
All bridges must register interruption signal handlers (`Console.CancelKeyPress` in PowerShell, `SIGINT`/`SIGTERM` in Python and Swift, and `finally` blocks) to dispatch `SET_ACTIVITY` with `activity: null`, flush and close the pipe connection, and remove the PID file so Discord clears presence instantly on exit.
