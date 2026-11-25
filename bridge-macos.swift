#!/usr/bin/env swift
// bridge-macos.swift - Native macOS Discord Rich Presence Bridge for MyGo Music
// 100% Native: Zero Node.js, Bun, or Deno required.
// Uses macOS Foundation & POSIX Unix Domain Sockets.

import Foundation

let defaultClientId = "631447533323026432"
let isDebug = CommandLine.arguments.contains("--debug")
    || CommandLine.arguments.contains("-debug")
    || CommandLine.arguments.contains("-d")
    || CommandLine.arguments.contains("-Debug")
    || ProcessInfo.processInfo.environment["DISCORD_RPC_DEBUG"] == "1"

let nonFlagArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
let clientId = nonFlagArgs.first ?? (ProcessInfo.processInfo.environment["DISCORD_CLIENT_ID"] ?? defaultClientId)
let defaultIcon = "https://raw.githubusercontent.com/egoist/mygo-music/main/resources/icon.png"
let downloadUrl = "https://music.egoist.dev/"
var coverCache: [String: String] = [:]

func logMessage(_ msg: String) {
    let formatter = ISO8601DateFormatter()
    let ts = formatter.string(from: Date())
    print("[\(ts)] [discord-mygo-music-native-macos] \(msg)")
    fflush(stdout)
}

func debugLog(_ msg: String) {
    guard isDebug else { return }
    let formatter = ISO8601DateFormatter()
    let ts = formatter.string(from: Date())
    print("[\(ts)] [discord-mygo-music-debug] \(msg)")
    fflush(stdout)
}

logMessage("Starting macOS Native Discord RPC Bridge (Client ID: \(clientId), Debug: \(isDebug ? "ENABLED" : "DISABLED"))")

// Single Instance via /tmp/discord-mygo-music.pid
let pidFile = "/tmp/discord-mygo-music.pid"
if let oldPidStr = try? String(contentsOfFile: pidFile, encoding: .utf8),
   let oldPid = Int32(oldPidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
   oldPid != getpid() {
    kill(oldPid, SIGTERM)
    logMessage("Terminated stale bridge instance (PID \(oldPid))")
}
try? "\(getpid())".write(toFile: pidFile, atomically: true, encoding: .utf8)

// Session path
let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
let sessionPath = "\(homeDir)/Library/Application Support/MyGo Music/session.json"

func getSessionData() -> [String: Any]? {
    guard FileManager.default.fileExists(atPath: sessionPath),
          let data = try? Data(contentsOf: URL(fileURLWithPath: sessionPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json
}

func searchCover(title: String, artist: String) -> String? {
    let key = "\(title)|\(artist)"
    if let cached = coverCache[key] { return cached }

    guard let query = "\(title) \(artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://music.163.com/api/cloudsearch/pc?s=\(query)&type=1&limit=3&offset=0") else {
        return nil
    }

    debugLog("Querying NetEase HD cover fallback: \(url.absoluteString)")

    var request = URLRequest(url: url)
    request.timeoutInterval = 2.5
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36", forHTTPHeaderField: "User-Agent")
    request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")

    let semaphore = DispatchSemaphore(value: 0)
    var foundPic: String?

    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
        defer { semaphore.signal() }
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]],
              let first = songs.first else { return }

        let album = (first["al"] as? [String: Any]) ?? (first["album"] as? [String: Any])
        if var pic = album?["picUrl"] as? String {
            if pic.hasPrefix("http://") {
                pic = "https://" + pic.dropFirst(7)
            }
            foundPic = pic
        }
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 2.5)

    if let pic = foundPic {
        coverCache[key] = pic
        debugLog("Resolved NetEase HD cover: \(pic)")
        return pic
    }
    coverCache[key] = nil
    return nil
}

func formatSourceLabel(source: String?, url: String?) -> String? {
    let s = (source ?? "").lowercased().trimmingCharacters(in: .whitespaces)
    let u = (url ?? "").trimmingCharacters(in: .whitespaces)

    if ["local", "file", "offline", "library", "my-computer"].contains(s) {
        return nil
    }
    guard !u.isEmpty, u.hasPrefix("http") else { return nil }
    let lu = u.lowercased()
    if lu.contains("localhost") || lu.contains("127.0.0.1") || lu.contains("::1") { return nil }

    if lu.contains("music.youtube.com") || s == "youtube-music" || s == "ytmusic" { return "YouTube Music" }
    if lu.contains("youtube.com") || lu.contains("youtu.be") || s == "youtube" { return "YouTube" }
    if lu.contains("spotify.com") || s == "spotify" || s == "mygotify" { return "Spotify" }
    if lu.contains("163.com") || s.contains("netease") || s == "163" || s == "cloudmusic" { return "NetEase" }
    if lu.contains("bilibili.com") || s == "bilibili" { return "Bilibili" }
    if lu.contains("soundcloud.com") || s == "soundcloud" { return "SoundCloud" }
    if lu.contains("music.apple.com") || s == "apple" || s == "applemusic" { return "Apple Music" }
    if lu.contains("bandcamp.com") || s == "bandcamp" { return "Bandcamp" }
    if lu.contains("deezer.com") || s == "deezer" { return "Deezer" }
    if lu.contains("tidal.com") || s == "tidal" { return "Tidal" }
    if lu.contains("qq.com") || s.contains("qqmusic") || s == "qq" { return "QQ Music" }

    if let src = source, !["web", "stream", "unknown", "http", "https", "mpris", "mediaremote"].contains(s), !s.contains("mygo") {
        let clean = src.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression).capitalized
        return String(clean.prefix(20))
    }
    return nil
}

// MediaRemote API dynamic binding
typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void

var mrGetInfo: MRMediaRemoteGetNowPlayingInfoFunction?

if let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) {
    if let symRegister = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications"),
       let symGetInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
        let registerNotifications = unsafeBitCast(symRegister, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
        mrGetInfo = unsafeBitCast(symGetInfo, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
        registerNotifications(DispatchQueue.global())
        logMessage("MediaRemote framework initialized successfully.")
    }
}

// Unix domain socket connection to Discord
func getIpcCandidates() -> [String] {
    var candidates: [String] = []
    let envDirs = [
        ProcessInfo.processInfo.environment["TMPDIR"],
        ProcessInfo.processInfo.environment["TMP"],
        "/tmp"
    ].compactMap { $0 }

    for dir in envDirs {
        for i in 0..<10 {
            candidates.append("\(dir)/discord-ipc-\(i)")
        }
    }
    return candidates
}

class DiscordIPC {
    var fd: Int32 = -1
    var isReady = false
    let appId: String
    var onReady: (() -> Void)?

    init(appId: String) {
        self.appId = appId
    }

    func connect() -> Bool {
        for path in getIpcCandidates() {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathLen = path.utf8.count
            guard pathLen < MemoryLayout.size(ofValue: addr.sun_path) else { continue }
            _ = path.withCString { strncpy(&addr.sun_path.0, $0, pathLen) }

            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { continue }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, addrLen)
                }
            }

            if res == 0 {
                var flags = fcntl(s, F_GETFL, 0)
                _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
                self.fd = s
                logMessage("Connected to Discord IPC: \(path)")
                handshake()
                return true
            }
            close(s)
        }
        return false
    }

    func handshake() {
        debugLog("Dispatching Discord IPC Handshake (Opcode 0, Client ID: \(appId))")
        sendFrame(opcode: 0, payload: ["v": 1, "client_id": appId])
    }

    func sendFrame(opcode: Int32, payload: [String: Any]) {
        guard fd >= 0,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }

        if opcode == 1, let cmd = payload["cmd"] as? String, cmd == "SET_ACTIVITY",
           let jsonStr = String(data: data, encoding: .utf8) {
            debugLog("Sending SET_ACTIVITY frame: \(jsonStr)")
        }

        var op = opcode.littleEndian
        var len = Int32(data.count).littleEndian

        var packet = Data()
        packet.append(UnsafeBufferPointer(start: &op, count: 1))
        packet.append(UnsafeBufferPointer(start: &len, count: 1))
        packet.append(data)

        _ = packet.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress, packet.count)
        }
    }

    func checkIncoming() {
        guard fd >= 0 else { return }
        var header = [Int32](repeating: 0, count: 2)
        let r = Darwin.read(fd, &header, 8)
        if r == 8 {
            let opcode = Int32(littleEndian: header[0])
            let length = Int(Int32(littleEndian: header[1]))
            if length > 0 {
                var buf = [UInt8](repeating: 0, count: length)
                _ = Darwin.read(fd, &buf, length)
                if let str = String(bytes: buf, encoding: .utf8) {
                    if opcode == 1 {
                        if str.contains("\"READY\"") {
                            logMessage("Discord RPC Ready!")
                            isReady = true
                            onReady?()
                        } else if str.contains("\"evt\":\"ERROR\"") || str.contains("\"evt\": \"ERROR\"") {
                            logMessage("DISCORD RPC ERROR: \(str)")
                        } else {
                            debugLog("Discord Frame (Opcode 1): \(str)")
                        }
                    } else if opcode == 3, let msg = try? JSONSerialization.jsonObject(with: Data(buf)) as? [String: Any] {
                        debugLog("Received PING, replying PONG")
                        sendFrame(opcode: 4, payload: msg)
                    }
                }
            }
        } else if r == 0 {
            close(fd)
            fd = -1
            isReady = false
        }
    }
}

let ipc = DiscordIPC(appId: clientId)
var lastActivityKey = ""
var lastMetaKey = ""
var lastStartSec: Int64 = 0
var currentTrackData: [String: Any]?

func dispatchTrack(_ cur: [String: Any], sess: [String: Any]) {
    currentTrackData = cur

    guard ipc.isReady else {
        debugLog("Handshake not ready yet, cached track data")
        return
    }

    var name = cur["name"] as? String ?? ""
    if name.count < 2 {
        name = "\(name) "
    }
    if name.count > 128 {
        name = String(name.prefix(125)) + "..."
        debugLog("Title truncated to 128 characters: \(name)")
    }

    var artistStr = ""
    if let artists = cur["artists"] as? [[String: Any]] {
        artistStr = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
    }
    if artistStr.count > 128 {
        artistStr = String(artistStr.prefix(125)) + "..."
    }

    let albumStr = (cur["album"] as? [String: Any])?["name"] as? String ?? ""
    let durMs = cur["duration"] as? Double ?? 0
    let durSec = Int64(durMs / 1000.0)
    let posMs = sess["position"] as? Double ?? 0
    let posSec = Int64(posMs / 1000.0)
    let nowSec = Int64(Date().timeIntervalSince1970)
    let startSec = nowSec - posSec

    var songUrl = cur["url"] as? String
    let source = cur["source"] as? String ?? "MyGo Music"

    if (songUrl == nil || songUrl!.isEmpty), let id = cur["id"] as? String {
        let s = source.lowercased()
        if s == "youtube-music" || s == "ytmusic" || s == "youtube" {
            songUrl = "https://music.youtube.com/watch?v=\(id)"
        } else if s == "spotify" || s == "mygotify" {
            songUrl = "https://open.spotify.com/track/\(id)"
        } else if s.contains("netease") || s == "163" || s == "cloudmusic" {
            songUrl = "https://music.163.com/#/song?id=\(id)"
        } else if s == "bilibili" {
            songUrl = "https://www.bilibili.com/video/\(id)"
        }
    }

    let sourceLabel = formatSourceLabel(source: source, url: songUrl)

    // Artwork resolution: discard non-http (file:///) URLs
    let rawCover = (cur["album"] as? [String: Any])?["imageUrl"] as? String
    var coverUrl: String?
    if let raw = rawCover, raw.hasPrefix("http://") || raw.hasPrefix("https://") {
        coverUrl = raw
    } else if let raw = rawCover {
        debugLog("Filtered out local/non-HTTP cover URL: \(raw)")
    }

    if coverUrl == nil || coverUrl!.isEmpty {
        debugLog("Querying NetEase cover search fallback for \"\(name)\" by \"\(artistStr)\"...")
        coverUrl = searchCover(title: name, artist: artistStr)
    }
    if coverUrl == nil || coverUrl!.isEmpty || (!coverUrl!.hasPrefix("http://") && !coverUrl!.hasPrefix("https://")) {
        debugLog("Falling back to default icon for cover art")
        coverUrl = defaultIcon
    }

    let activityKey = "\(name)|\(artistStr)|\(albumStr)|\(startSec)|\(sourceLabel ?? "none")|\(songUrl ?? "none")|\(coverUrl ?? defaultIcon)"
    if activityKey == lastActivityKey { return }

    var buttons: [[String: String]] = []
    if let sl = sourceLabel, let u = songUrl, u.hasPrefix("http") && u.count <= 512 {
        var label = "Listen on \(sl)"
        if label.count > 32 { label = String(label.prefix(32)) }
        buttons.append(["label": label, "url": u])
    }
    buttons.append(["label": "Download MyGo Music", "url": downloadUrl])

    var largeText = albumStr.isEmpty ? name : albumStr
    if largeText.count > 128 { largeText = String(largeText.prefix(125)) + "..." }
    if largeText.count < 2 { largeText = "\(largeText) " }

    var activity: [String: Any] = [
        "type": 2,
        "name": artistStr.isEmpty ? name : "\(artistStr) - \(name)",
        "details": name,
        "assets": [
            "large_image": coverUrl ?? defaultIcon,
            "large_text": largeText,
            "small_image": defaultIcon,
            "small_text": "MyGo Music"
        ],
        "timestamps": [
            "start": startSec,
            "end": durSec > 0 ? (startSec + durSec) : (startSec + 180)
        ],
        "buttons": buttons,
        "metadata": ["button_urls": buttons.map { $0["url"] ?? "" }]
    ]

    // Discord rejects empty state (""). Omit if empty or < 2 characters
    if !artistStr.trimmingCharacters(in: .whitespaces).isEmpty && artistStr.count >= 2 {
        activity["state"] = artistStr
    } else {
        debugLog("Omitted state property (artist empty or < 2 characters to satisfy Discord validation)")
    }

    ipc.sendFrame(opcode: 1, payload: [
        "cmd": "SET_ACTIVITY",
        "args": ["pid": getpid(), "activity": activity],
        "nonce": UUID().uuidString
    ])

    lastActivityKey = activityKey
    let btnDesc = sourceLabel != nil ? "[\(sourceLabel!) + Download]" : "[Download only]"
    let covDesc = coverUrl != defaultIcon ? "[Cover: OK]" : "[Cover: Default]"
    logMessage("Updated Discord Presence: \"\(name)\" \(!artistStr.isEmpty ? "by \(artistStr) " : "")(Playing) \(btnDesc) \(covDesc)")
}

ipc.onReady = {
    lastActivityKey = ""
    debugLog("Discord RPC Ready handler triggered")
    if let sess = getSessionData(),
       let queue = sess["queue"] as? [[String: Any]], !queue.isEmpty {
        var idx = sess["at"] as? Int ?? 0
        if let shuffle = sess["shuffle"] as? Bool, shuffle,
           let order = sess["order"] as? [Int], order.count > idx {
            idx = order[idx]
        }
        if idx < queue.count {
            dispatchTrack(queue[idx], sess: sess)
        }
    }
}

// Graceful Shutdown & Cleanup Handler
var isStopping = false
func cleanup() {
    guard !isStopping else { return }
    isStopping = true
    logMessage("Shutting down macOS Native Bridge (clearing Discord presence)...")
    if ipc.fd >= 0 {
        ipc.sendFrame(opcode: 1, payload: [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": getpid(), "activity": NSNull()],
            "nonce": UUID().uuidString
        ])
        usleep(60000)
        close(ipc.fd)
        ipc.fd = -1
    }
    try? FileManager.default.removeItem(atPath: pidFile)
    logMessage("Bridge shutdown complete.")
    exit(0)
}

let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigIntSource.setEventHandler { cleanup() }
sigIntSource.resume()

let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigTermSource.setEventHandler { cleanup() }
sigTermSource.resume()

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

logMessage("Native macOS Bridge active. Polling media updates...")

while true {
    if ipc.fd < 0 {
        _ = ipc.connect()
    }
    ipc.checkIncoming()

    if let sess = getSessionData(),
       let queue = sess["queue"] as? [[String: Any]], !queue.isEmpty {
        var idx = sess["at"] as? Int ?? 0
        if let shuffle = sess["shuffle"] as? Bool, shuffle,
           let order = sess["order"] as? [Int], order.count > idx {
            idx = order[idx]
        }

        if idx < queue.count {
            let cur = queue[idx]
            let name = cur["name"] as? String ?? ""
            var artistStr = ""
            if let artists = cur["artists"] as? [[String: Any]] {
                artistStr = artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
            }
            let albumStr = (cur["album"] as? [String: Any])?["name"] as? String ?? ""
            let posMs = sess["position"] as? Double ?? 0
            let posSec = Int64(posMs / 1000.0)
            let nowSec = Int64(Date().timeIntervalSince1970)
            let startSec = nowSec - posSec

            let metaKey = "\(name)|\(artistStr)|\(albumStr)|Playing"
            let seekChanged = abs(startSec - lastStartSec) >= 2

            if (metaKey != lastMetaKey || seekChanged) && !name.isEmpty {
                lastMetaKey = metaKey
                lastStartSec = startSec
                dispatchTrack(cur, sess: sess)
            }
        }
    }

    Thread.sleep(forTimeInterval: 0.3)
}
