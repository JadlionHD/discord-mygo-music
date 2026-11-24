// discord-mygo-music: Discord Rich Presence plugin for MyGo Music
// 100% Native Architecture: Zero Node.js, Bun, or Deno required.
// Windows (PowerShell + WinRT), Linux (Python 3 + MPRIS2), macOS (Swift + MediaRemote).

const t = (typeof host !== "undefined" && host.t) ? host.t : (str) => str;
const DEFAULT_CLIENT_ID = "631447533323026432";

let bridgeProcess = null;
let lastSpawnError = null;
let activeBridgePath = null;
const bridgeLogs = [];

function addLog(msg) {
  const ts = new Date().toLocaleTimeString();
  const entry = `[${ts}] ${msg}`;
  bridgeLogs.unshift(entry);
  if (bridgeLogs.length > 30) bridgeLogs.pop();
  console.log(`[discord-mygo-music] ${msg}`);
}

function getNativeConfig() {
  const platform = (typeof host !== "undefined" && host.platform) ? host.platform : "windows";

  if (platform === "windows") {
    return {
      name: "Windows Native Engine",
      runtimeInfo: "PowerShell 5.1+ (.NET NamedPipe & WinRT GSMTC)",
      cmd: "powershell.exe",
      scriptName: "bridge-windows.ps1",
      makeArgs: (scriptPath, clientId) => [
        "-ExecutionPolicy", "Bypass",
        "-NoProfile",
        "-File", scriptPath,
        clientId
      ]
    };
  }

  if (platform === "darwin") {
    return {
      name: "macOS Native Engine",
      runtimeInfo: "Swift & MediaRemote Framework",
      cmd: "swift",
      scriptName: "bridge-macos.swift",
      makeArgs: (scriptPath, clientId) => [scriptPath, clientId]
    };
  }

  // Linux default
  return {
    name: "Linux Native Engine",
    runtimeInfo: "Python 3 & MPRIS2 playerctl",
    cmd: "python3",
    scriptName: "bridge-linux.py",
    makeArgs: (scriptPath, clientId) => [scriptPath, clientId]
  };
}

// Resolve candidate script paths for current platform
function resolveScriptCandidates(scriptName) {
  const platform = (typeof host !== "undefined" && host.platform) ? host.platform : "windows";
  const candidates = [];

  if (platform === "windows") {
    candidates.push(
      `C:\\Users\\Jadlion\\AppData\\Roaming\\MyGo Music\\plugins\\discord-mygo-music-dev\\${scriptName}`,
      `C:\\Users\\Jadlion\\AppData\\Roaming\\MyGo Music\\plugins\\discord-mygo-music\\${scriptName}`,
      `plugins\\discord-mygo-music-dev\\${scriptName}`,
      `plugins\\discord-mygo-music\\${scriptName}`,
      scriptName
    );
  } else if (platform === "darwin") {
    candidates.push(
      `plugins/discord-mygo-music-dev/${scriptName}`,
      `plugins/discord-mygo-music/${scriptName}`,
      scriptName
    );
  } else {
    candidates.push(
      `plugins/discord-mygo-music-dev/${scriptName}`,
      `plugins/discord-mygo-music/${scriptName}`,
      scriptName
    );
  }

  return candidates;
}

async function ensureBridge(force = false) {
  if (bridgeProcess && !force) return;

  addLog("Ensuring Native Discord RPC Bridge is active...");
  const cfg = getNativeConfig();
  const clientId = (host.setting && host.setting("discordClientId")) ? host.setting("discordClientId") : DEFAULT_CLIENT_ID;
  const scriptCandidates = resolveScriptCandidates(cfg.scriptName);

  for (const scriptPath of scriptCandidates) {
    try {
      addLog(`Spawning ${cfg.cmd} with: ${scriptPath}`);
      const args = cfg.makeArgs(scriptPath, clientId);

      const proc = host.spawn(cfg.cmd, args);
      bridgeProcess = proc;
      activeBridgePath = scriptPath;
      lastSpawnError = null;
      addLog(`Native bridge process started successfully!`);

      // Read output stream into log buffer
      (async () => {
        try {
          let line;
          while ((line = await proc.readLine()) !== null) {
            line = line.trim();
            if (line) addLog(line);
          }
        } catch {}
      })();

      proc.wait().then((code) => {
        addLog(`Native bridge process exited with code ${code}.`);
        bridgeProcess = null;
      });
      return;
    } catch (err) {
      if (/allowed|permission/i.test(err.message)) {
        lastSpawnError = "Permission Denied: Allow process execution in Settings > Plugins";
      } else {
        lastSpawnError = `${cfg.cmd}: ${err.message}`;
      }
      addLog(`Spawn failed for ${scriptPath}: ${err.message}`);
    }
  }
}

// Hook called whenever a song is played in MyGo Music
export async function played({ id }) {
  ensureBridge().catch((err) => console.error(`[discord-mygo-music] ${err.message}`));
}

// Home page for status display inside MyGo Music
export async function home() {
  ensureBridge().catch(() => {});
  const cfg = getNativeConfig();
  const clientId = (host.setting && host.setting("discordClientId")) ? host.setting("discordClientId") : DEFAULT_CLIENT_ID;

  const bridgeStatusText = bridgeProcess
    ? `${t("Active via")} ${cfg.name}`
    : lastSpawnError
    ? `Error: ${lastSpawnError}`
    : t("Starting native bridge engine...");

  return {
    title: t("Discord Status"),
    sections: [
      {
        title: t("Sync Status"),
        tracks: [
          {
            id: "diag-status",
            name: t("Bridge Status"),
            artists: [{ id: "", name: bridgeStatusText }],
            album: { id: "", name: bridgeProcess ? "Running" : "Stopped", imageUrl: "" },
            duration: 0,
          },
          {
            id: "diag-runtime",
            name: t("Engine Architecture"),
            artists: [{ id: "", name: `${cfg.name} (Zero Node/Bun/Deno)` }],
            album: { id: "", name: "100% Native", imageUrl: "" },
            duration: 0,
          },
          {
            id: "diag-client",
            name: t("Discord Client ID"),
            artists: [{ id: "", name: clientId }],
            album: { id: "", name: "RPC App", imageUrl: "" },
            duration: 0,
          },
        ],
        albums: [],
        artists: [],
        playlists: [],
      },
    ],
  };
}

// Custom Navigation Page: "debugger"
export async function browse({ page }) {
  if (page === "debugger") {
    if (!bridgeProcess) {
      ensureBridge(true).catch(() => {});
    }

    const cfg = getNativeConfig();
    const clientId = (host.setting && host.setting("discordClientId")) ? host.setting("discordClientId") : DEFAULT_CLIENT_ID;

    const diagTracks = [
      {
        id: "dbg-runtime",
        name: "Native Platform Engine",
        artists: [{ id: "", name: cfg.runtimeInfo }],
        album: { id: "", name: "NATIVE", imageUrl: "" },
        duration: 0,
      },
      {
        id: "dbg-bridge",
        name: "Bridge Background Process",
        artists: [{ id: "", name: bridgeProcess ? `Running (${cfg.cmd})` : `Stopped / ${lastSpawnError || "Not running"}` }],
        album: { id: "", name: bridgeProcess ? "ONLINE" : "OFFLINE", imageUrl: "" },
        duration: 0,
      },
      {
        id: "dbg-path",
        name: "Resolved Script Path",
        artists: [{ id: "", name: activeBridgePath || "Resolving path..." }],
        album: { id: "", name: "Path", imageUrl: "" },
        duration: 0,
      },
      {
        id: "dbg-client",
        name: "Discord Application ID",
        artists: [{ id: "", name: clientId }],
        album: { id: "", name: "Discord", imageUrl: "" },
        duration: 0,
      },
      {
        id: "dbg-permission",
        name: "Process Permission",
        artists: [{ id: "", name: lastSpawnError && /permission|allowed/i.test(lastSpawnError) ? "DENIED: Allow in Settings > Plugins" : "GRANTED (Executable access OK)" }],
        album: { id: "", name: "Security", imageUrl: "" },
        duration: 0,
      },
    ];

    const logTracks = bridgeLogs.length > 0
      ? bridgeLogs.slice(0, 15).map((line, idx) => ({
          id: `dbg-log-${idx}`,
          name: line,
          artists: [{ id: "", name: "Log entry" }],
          album: { id: "", name: `#${idx + 1}`, imageUrl: "" },
          duration: 0,
        }))
      : [
          {
            id: "dbg-log-empty",
            name: "No bridge activity logs yet",
            artists: [{ id: "", name: "Play a song in MyGo Music to trigger presence synchronization." }],
            album: { id: "", name: "Empty", imageUrl: "" },
            duration: 0,
          },
        ];

    return {
      title: "Discord Debugger",
      sections: [
        {
          title: "System Status & Diagnostics",
          tracks: diagTracks,
          albums: [],
          artists: [],
          playlists: [],
        },
        {
          title: "Activity Records / Real-Time Logs (Last 15)",
          tracks: logTracks,
          albums: [],
          artists: [],
          playlists: [],
        },
      ],
    };
  }

  return { title: t("no such page"), sections: [] };
}

// Auto start bridge on plugin load
ensureBridge().catch(() => {});
