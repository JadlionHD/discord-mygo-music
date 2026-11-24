# Privacy Policy

**Effective Date:** November 24, 2026  
**Plugin:** Discord Rich Presence for MyGo Music (`discord-mygo-music`)

This plugin is designed with a **privacy-first, local-only architecture**. We believe your music listening habits and personal data belong to you.

---

## 1. Information Processed

When active, the plugin temporarily reads the following playback metadata from MyGo Music and your operating system's native media manager:

- **Track Information**: Song title, artist name(s), album name, and track duration.
- **Playback State**: Current state (Playing, Paused, Stopped) and elapsed playback time (used to synchronize the Discord timeline seekbar).
- **Public Song URL**: If available from online streaming sources (such as YouTube Music, Spotify, NetEase, or Bilibili), the web URL is used to generate the optional `"Listen on {Source}"` action button.
- **Album Artwork URL**: The public HTTP/HTTPS URL of the album art.

> [!NOTE]
> **Local & Offline Files**: If you play local audio files (MP3, FLAC, WAV, etc.) from your computer, local file paths and filenames are **never** transmitted as links. The `"Listen on {Source}"` button is automatically omitted for local and offline tracks.

---

## 2. Where Data is Sent

1. **Local Discord Client (IPC)**:
   - All Rich Presence activity frames are sent directly to the **Discord desktop application installed on your own machine** via local Inter-Process Communication (Windows Named Pipe `\\.\pipe\discord-ipc-*` or Unix Domain Socket on Linux and macOS).
   - The plugin does **not** communicate with Discord's public web APIs directly; Discord handles displaying the status on your profile according to your personal Discord privacy settings.

2. **NetEase Cloud Music API (Fallback Cover Search Only)**:
   - If an online track lacks an album cover in its metadata, the plugin may query `https://music.163.com/api/cloudsearch/pc` with the song title and artist name to retrieve a high-resolution cover image.
   - This query is anonymous: no user tokens, cookies, accounts, IP logging, or unique identifiers are sent.

---

## 3. Telemetry and Analytics

- **Zero Tracking**: We do not collect, store, or transmit any analytics, telemetry, crash reports, or personal identifiers.
- **No Remote Servers**: The plugin does not connect to any proprietary backend, telemetry server, or cloud storage.
- **Volatile Logs Only**: Diagnostic logs shown in the MyGo Music **Debugger** page are stored strictly in temporary in-memory buffers and are completely cleared when MyGo Music is closed.

---

## 4. System Permissions

The plugin requests only the minimum operating system permissions necessary to function:
- **Process Execution**: Spawns your operating system's native runner (`powershell.exe` on Windows, `python3` on Linux, `swift` on macOS) to establish the local IPC connection to Discord.
- **Network Permissions**: Restricted exclusively to public CDN endpoints (`raw.githubusercontent.com` for the default icon and `music.163.com` for fallback artwork).

---

## 5. User Control

- You can disable Discord Rich Presence at any time in **Settings > Plugins** inside MyGo Music.
- You can control who sees your listening activity through your Discord account settings under **User Settings > Activity Privacy**.

---

## 6. Open Source Transparency

This plugin is free, open-source software licensed under the AGPL-3.0 License. All source code is completely transparent and inspectable.
