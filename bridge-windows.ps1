# bridge-windows.ps1 - Native Windows Discord Rich Presence Bridge for MyGo Music
# 100% Native: Zero Node.js, Bun, or Deno required.
# Uses: Windows PowerShell 5.1+, .NET NamedPipeClientStream, and WinRT GSMTC.

param(
  [Parameter(Position = 0)]
  [string]$ClientId = "631447533323026432",
  [Parameter(Position = 1)]
  [string]$Flag = ""
)

$ErrorActionPreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Determine if debug mode is active via parameters, environment, or args
$script:isDebug = $false
if ($ClientId -match '(?i)^[/-]{1,2}(debug|d)$') {
  $script:isDebug = $true
  $ClientId = "631447533323026432"
}
if ($Flag -match '(?i)^[/-]{1,2}(debug|d)$') {
  $script:isDebug = $true
}
foreach ($a in $args) {
  if ($a -match '(?i)^[/-]{1,2}(debug|d)$') {
    $script:isDebug = $true
  } elseif ($a -match '^\d{17,20}$') {
    $ClientId = $a
  }
}
if ($env:DISCORD_RPC_DEBUG -eq "1" -or ($PSBoundParameters -and $PSBoundParameters.ContainsKey('Debug'))) {
  $script:isDebug = $true
}

$DEFAULT_ICON = "https://raw.githubusercontent.com/egoist/mygo-music/main/resources/icon.png"
$DOWNLOAD_URL = "https://music.egoist.dev/"
$script:debugTickCount = 0

function Write-Log([string]$msg) {
  $ts = [DateTime]::UtcNow.ToString("o")
  [Console]::WriteLine("[$ts] [discord-mygo-music-native] $msg")
}

function Write-DebugLog([string]$msg) {
  if ($script:isDebug) {
    $ts = [DateTime]::UtcNow.ToString("o")
    [Console]::WriteLine("[$ts] [discord-mygo-music-debug] $msg")
  }
}

Write-Log "Starting Windows Native Discord RPC Bridge (Client ID: $ClientId, Debug: $(if ($script:isDebug) {'ENABLED'} else {'DISABLED'}))"

# -------------------------------------------------------------
# 1. Single Instance Protection (via PID file in %TEMP%)
# -------------------------------------------------------------
$pidFile = Join-Path $env:TEMP "discord-mygo-music.pid"
try {
  if (Test-Path $pidFile) {
    $oldPidStr = (Get-Content $pidFile -Raw).Trim()
    $oldPid = 0
    if ([int]::TryParse($oldPidStr, [ref]$oldPid) -and $oldPid -ne $PID) {
      $oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
      if ($oldProc) {
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        Write-Log "Terminated stale bridge instance (PID $oldPid)"
      }
    }
  }
  Set-Content -Path $pidFile -Value "$PID" -Encoding ASCII
} catch {}

# -------------------------------------------------------------
# 2. Native Win32 NamedPipe Support (kernel32 PeekNamedPipe)
# -------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class PipeNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool PeekNamedPipe(
        SafePipeHandle hNamedPipe,
        byte[] lpBuffer,
        uint nBufferSize,
        IntPtr lpBytesRead,
        out uint lpTotalBytesAvail,
        IntPtr lpBytesLeftThisMessage);
}
"@ -ErrorAction SilentlyContinue

# -------------------------------------------------------------
# 3. WinRT GSMTC Setup
# -------------------------------------------------------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows, ContentType=WindowsRuntime]
$propsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows, ContentType=WindowsRuntime]
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 } |
  Select-Object -First 1

function Await-Op($op, $t) {
  return $asTask.MakeGenericMethod(@($t)).Invoke($null, @($op)).GetAwaiter().GetResult()
}

$gsmtcMgr = $null
try {
  $gsmtcMgr = Await-Op ($managerType.GetMethod('RequestAsync').Invoke($null, @())) $managerType
  Write-DebugLog "Initialized WinRT GSMTC session manager"
} catch {
  Write-Log "Warning: Could not initialize WinRT GSMTC session manager: $($_.Exception.Message)"
}

# -------------------------------------------------------------
# 4. Session & Track Helpers (Non-locking FileShare)
# -------------------------------------------------------------
$sessionPath = Join-Path $env:APPDATA "MyGo Music\session.json"
$settingsPath = Join-Path $env:APPDATA "MyGo Music\settings.json"
$script:cachedSession = $null
$script:lastSessionMtime = 0
$script:cachedActiveSource = $null
$script:lastSettingsMtime = 0

function Get-ActiveSource([bool]$forceReload = $false) {
  if (-not (Test-Path $settingsPath)) { return $null }
  try {
    $item = Get-Item $settingsPath -ErrorAction SilentlyContinue
    if (-not $item) { return $script:cachedActiveSource }
    $mtime = $item.LastWriteTimeUtc.Ticks
    if (-not $forceReload -and $script:cachedActiveSource -and $mtime -eq $script:lastSettingsMtime) {
      return $script:cachedActiveSource
    }

    $fs = [System.IO.FileStream]::new($settingsPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
    $raw = $sr.ReadToEnd()
    $sr.Dispose()
    $fs.Dispose()

    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $parsed = $raw | ConvertFrom-Json
      if ($parsed -is [array] -and $parsed.Count -gt 0) { $parsed = $parsed[0] }
      if ($parsed -and $parsed.source) {
        $srcVal = if ($parsed.source -is [array]) { $parsed.source[0] } else { $parsed.source }
        $script:cachedActiveSource = [string]$srcVal
        $script:lastSettingsMtime = $mtime
        return $script:cachedActiveSource
      }
    }
  } catch {
    Write-DebugLog "Error reading settings.json: $($_.Exception.Message)"
  }
  return $script:cachedActiveSource
}

function Get-SessionData([bool]$forceReload = $false) {
  if (-not (Test-Path $sessionPath)) { return $null }
  try {
    $item = Get-Item $sessionPath
    $mtime = $item.LastWriteTimeUtc.Ticks
    if (-not $forceReload -and $script:cachedSession -and $mtime -eq $script:lastSessionMtime) {
      return $script:cachedSession
    }

    $fs = [System.IO.FileStream]::new($sessionPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
    $raw = $sr.ReadToEnd()
    $sr.Dispose()
    $fs.Dispose()

    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $parsed = $raw | ConvertFrom-Json
      if ($parsed -is [array] -and $parsed.Count -gt 0) { $parsed = $parsed[0] }
      $script:cachedSession = $parsed
      $script:lastSessionMtime = $mtime
      return $parsed
    }
  } catch {
    Write-DebugLog "Error reading session.json: $($_.Exception.Message)"
  }
  return $script:cachedSession
}

function Normalize-Text([string]$str) {
  if (-not $str) { return "" }
  return ($str.ToLower() -replace '[^\p{L}\p{N}]', '')
}

function Clean-Title([string]$str) {
  if (-not $str) { return "" }
  $cleaned = $str.ToLower() -replace '\s*[\(\[](feat\.?|ft\.?|official|video|mv|audio|remix|lyrics?|full version).*?[\)\]]', ''
  return ($cleaned -replace '[^\p{L}\p{N}]', '')
}

function Resolve-TrackDetails([string]$title, [string]$artist, [bool]$forceReload = $false) {
  $sess = Get-SessionData $forceReload
  if (-not $sess -or -not $sess.queue -or $sess.queue.Count -eq 0) { return $null }

  $activeSource = Get-ActiveSource $forceReload

  $nTitle = Normalize-Text $title
  $nArtist = Normalize-Text $artist
  $cTitle = Clean-Title $title

  # 1. Check current queue pointer and surrounding indices first (+/- 2 items)
  if ($sess -is [array] -and $sess.Count -gt 0) { $sess = $sess[0] }
  $rawAt = 0
  if ($sess.at -ne $null) {
    try {
      $firstAt = if ($sess.at -is [array]) { $sess.at[0] } else { $sess.at }
      $rawAt = [int]$firstAt
    } catch {
      $rawAt = 0
    }
  }
  [int]$baseAt = [int]$rawAt
  $checkIndices = @($baseAt, ($baseAt + 1), ($baseAt - 1), ($baseAt + 2), ($baseAt - 2))

  foreach ($testAt in $checkIndices) {
    if ($testAt -lt 0) { continue }
    $idx = $testAt
    if ($sess.shuffle -and $sess.order -and $sess.order.Count -gt $idx) {
      $idx = [int]$sess.order[$idx]
    }
    if ($idx -lt $sess.queue.Count) {
      $cur = $sess.queue[$idx]
      if ($cur -and $cur.name) {
        $curNTitle = Normalize-Text $cur.name
        $curCTitle = Clean-Title $cur.name
        $curArtists = if ($cur.artists) { ($cur.artists | ForEach-Object { $_.name }) -join " " } else { "" }
        $curNArtist = Normalize-Text $curArtists

        $titleMatch = ($curNTitle -eq $nTitle) -or ($cTitle -and $curCTitle -eq $cTitle) -or
                      ($nTitle -and $curNTitle.Contains($nTitle)) -or ($curNTitle -and $nTitle.Contains($curNTitle))
        $artistMatch = (-not $nArtist -or -not $curNArtist -or $curNArtist.Contains($nArtist) -or $nArtist.Contains($curNArtist))

        if ($titleMatch -and $artistMatch) {
          # If active source is known, prefer track with matching source or exact title
          if (-not $activeSource -or -not $cur.source -or $cur.source -eq $activeSource -or $curNTitle -eq $nTitle) {
            return $cur
          }
        }
      }
    }
  }

  # 2. Queue scoring search
  $best = $null
  $bestScore = 0

  foreach ($t in $sess.queue) {
    if (-not $t.name) { continue }
    $tArtists = if ($t.artists) { ($t.artists | ForEach-Object { $_.name }) -join " " } else { "" }
    $tnTitle = Normalize-Text $t.name
    $tnArtist = Normalize-Text $tArtists
    $tcTitle = Clean-Title $t.name

    # Artist compatibility: if both exist, they must share tokens or substrings
    $hasBothArtists = ($nArtist.Length -ge 2 -and $tnArtist.Length -ge 2)
    $artistMatch = if ($hasBothArtists) {
      $tnArtist.Contains($nArtist) -or $nArtist.Contains($tnArtist)
    } else {
      $true
    }

    # Reject immediately if both tracks have an artist and they don't match
    if ($hasBothArtists -and -not $artistMatch) {
      continue
    }

    # Source compatibility check: prefer matching active source
    $sourceMatches = (-not $activeSource -or -not $t.source -or $t.source -eq $activeSource)

    $score = 0
    if ($tnTitle -eq $nTitle -and $artistMatch) {
      $score = if ($sourceMatches) { 100 } else { 70 }
    } elseif ($cTitle -and $tcTitle -eq $cTitle -and $artistMatch) {
      $score = if ($sourceMatches) { 90 } else { 65 }
    } elseif ($cTitle -and ($tcTitle.Contains($cTitle) -or $cTitle.Contains($tcTitle)) -and $artistMatch) {
      $score = if ($sourceMatches) { 80 } else { 55 }
    } elseif ($tnTitle -eq $nTitle -and -not $hasBothArtists) {
      $score = if ($sourceMatches) { 70 } else { 50 }
    }

    if ($score -gt $bestScore) {
      $bestScore = $score
      $best = $t
    }
  }

  if ($bestScore -ge 65) { return $best }
  return $null
}

function Synthesize-TrackUrl([string]$source, [string]$id, [string]$title, [string]$artist) {
  $s = ($source + "").ToLower().Trim()
  $q = [System.Uri]::EscapeDataString(("$title $artist").Trim())

  if ($s -in @("youtube-music", "ytmusic", "youtube")) {
    if ($id) { return "https://music.youtube.com/watch?v=$id" }
    if ($q) { return "https://music.youtube.com/search?q=$q" }
  } elseif ($s -in @("spotify", "mygotify")) {
    if ($id) { return "https://open.spotify.com/track/$id" }
    if ($q) { return "https://open.spotify.com/search/$q" }
  } elseif ($s.Contains("netease") -or $s -in @("163", "cloudmusic")) {
    if ($id) { return "https://music.163.com/#/song?id=$id" }
    if ($q) { return "https://music.163.com/#/search/m/?s=$q&type=1" }
  } elseif ($s -eq "bilibili") {
    if ($id) { return "https://www.bilibili.com/video/$id" }
    if ($q) { return "https://search.bilibili.com/all?keyword=$q" }
  }
  return $null
}

function Format-SourceLabel([string]$source, [string]$url) {
  $s = ($source + "").ToLower().Trim()
  $u = ($url + "").Trim()

  if ($s -in @("local", "file", "offline", "library", "my-computer")) {
    return $null
  }

  if (-not $u -or -not ($u -match '^https?://')) {
    return $null
  }

  $lu = $u.ToLower()
  if ($lu.Contains("localhost") -or $lu.Contains("127.0.0.1") -or $lu.Contains("::1")) {
    return $null
  }

  # 1. URL domain is the highest authority
  if ($lu.Contains("music.youtube.com")) {
    return "YouTube Music"
  }
  if ($lu.Contains("youtube.com") -or $lu.Contains("youtu.be")) {
    return "YouTube"
  }
  if ($lu.Contains("spotify.com")) {
    return "Spotify"
  }
  if ($lu.Contains("163.com") -or $lu.Contains("music.126.net")) {
    return "NetEase"
  }
  if ($lu.Contains("bilibili.com")) {
    return "Bilibili"
  }
  if ($lu.Contains("soundcloud.com")) {
    return "SoundCloud"
  }
  if ($lu.Contains("music.apple.com")) {
    return "Apple Music"
  }
  if ($lu.Contains("bandcamp.com")) {
    return "Bandcamp"
  }
  if ($lu.Contains("deezer.com")) {
    return "Deezer"
  }
  if ($lu.Contains("tidal.com")) {
    return "Tidal"
  }
  if ($lu.Contains("qq.com")) {
    return "QQ Music"
  }

  # 2. Source parameter fallback
  if ($s -in @("youtube-music", "ytmusic")) {
    return "YouTube Music"
  }
  if ($s -eq "youtube") {
    return "YouTube"
  }
  if ($s -in @("spotify", "mygotify")) {
    return "Spotify"
  }
  if ($s.Contains("netease") -or $s -in @("163", "cloudmusic")) {
    return "NetEase"
  }
  if ($s -eq "bilibili") {
    return "Bilibili"
  }
  if ($s -eq "soundcloud") {
    return "SoundCloud"
  }
  if ($s -in @("apple", "applemusic")) {
    return "Apple Music"
  }
  if ($s -eq "bandcamp") {
    return "Bandcamp"
  }
  if ($s -eq "deezer") {
    return "Deezer"
  }
  if ($s -eq "tidal") {
    return "Tidal"
  }
  if ($s.Contains("qqmusic") -or $s -eq "qq") {
    return "QQ Music"
  }

  if ($source -and -not ($s -in @("web", "stream", "unknown", "http", "https", "mpris", "mediaremote")) -and -not ($s -match 'mygo')) {
    $clean = ($source -replace '[-_]+', ' ').Trim()
    if ($clean.Length -gt 20) { $clean = $clean.Substring(0, 20) }
    return (Get-Culture).TextInfo.ToTitleCase($clean)
  }

  return $null
}

# -------------------------------------------------------------
# 5. Discord IPC Management
# -------------------------------------------------------------
$script:pipe = $null
$script:isHandshaked = $false
$script:lastActivityKey = ""
$script:activeTrackKey = ""
$script:activeStartTime = 0
$script:currentTrack = $null
$script:retryDelays = @(200, 500, 1000, 2000, 4000, 8000)
$script:retryAttempt = 0
$script:pendingRetryTime = 0
$script:lastTrackObj = $null

function Connect-DiscordPipe {
  for ($i = 0; $i -lt 10; $i++) {
    $name = "discord-ipc-$i"
    try {
      $p = New-Object System.IO.Pipes.NamedPipeClientStream(".", $name, [System.IO.Pipes.PipeDirection]::InOut)
      $p.Connect(350)
      Write-Log "Connected to Discord NamedPipe ($name)"
      return $p
    } catch {}
  }
  return $null
}

function Send-DiscordFrame([int]$opcode, $obj) {
  if (-not $script:pipe -or -not $script:pipe.IsConnected) { return $false }
  try {
    $json = $obj | ConvertTo-Json -Compress -Depth 10
    if ($opcode -eq 1 -and $obj.cmd -eq "SET_ACTIVITY") {
      Write-DebugLog "Sending SET_ACTIVITY frame: $json"
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $writer = New-Object System.IO.BinaryWriter($script:pipe)
    $writer.Write([int32]$opcode)
    $writer.Write([int32]$bytes.Length)
    $writer.Write($bytes)
    $writer.Flush()
    return $true
  } catch {
    Write-Log "Failed to write frame: $($_.Exception.Message)"
    return $false
  }
}

function Handshake-Discord {
  $payload = @{
    v = 1
    client_id = $ClientId
  }
  Write-DebugLog "Dispatching Discord IPC Handshake (Opcode 0, Client ID: $ClientId)"
  return (Send-DiscordFrame 0 $payload)
}

function Check-IncomingPipe {
  if (-not $script:pipe -or -not $script:pipe.IsConnected) { return }

  try {
    $avail = [uint32]0
    $ok = [PipeNative]::PeekNamedPipe($script:pipe.SafePipeHandle, $null, 0, [IntPtr]::Zero, [ref]$avail, [IntPtr]::Zero)
    if (-not $ok) {
      Write-Log "Discord NamedPipe disconnected."
      $script:pipe.Dispose()
      $script:pipe = $null
      $script:isHandshaked = $false
      return
    }

    while ($avail -ge 8) {
      $reader = New-Object System.IO.BinaryReader($script:pipe)
      $opcode = $reader.ReadInt32()
      $len = $reader.ReadInt32()
      $avail -= 8

      $respJson = ""
      if ($len -gt 0) {
        $bodyBytes = $reader.ReadBytes($len)
        $avail -= [uint32]$len
        $respJson = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
      }

      if ($opcode -eq 1) {
        if ($respJson.Contains('"READY"')) {
          Write-Log "Discord RPC Ready!"
          $script:isHandshaked = $true
          $script:lastActivityKey = ""
          # Immediately dispatch current active track upon handshake
          if ($script:currentTrack) {
            Write-DebugLog "Handshake finished, immediately updating queued track"
            Update-Activity $script:currentTrack
          }
        } elseif ($respJson.Contains('"evt":"ERROR"') -or $respJson.Contains('"evt": "ERROR"')) {
          try {
            $errObj = $respJson | ConvertFrom-Json
            Write-Log "DISCORD RPC ERROR: Code $($errObj.data.code) - $($errObj.data.message)"
          } catch {
            Write-Log "DISCORD RPC ERROR: $respJson"
          }
        } else {
          Write-DebugLog "Discord Frame (Opcode 1): $respJson"
        }
      } elseif ($opcode -eq 3) {
        # PING -> PONG
        Write-DebugLog "Received PING, replying PONG"
        Send-DiscordFrame 4 ($respJson | ConvertFrom-Json)
      } elseif ($opcode -eq 2) {
        Write-Log "Discord closed connection."
        $script:pipe.Dispose()
        $script:pipe = $null
        $script:isHandshaked = $false
        return
      }
    }
  } catch {
    Write-Log "Error reading pipe: $($_.Exception.Message)"
    try { $script:pipe.Dispose() } catch {}
    $script:pipe = $null
    $script:isHandshaked = $false
  }
}

function Update-Activity($track) {
  $script:currentTrack = $track

  if (-not $script:isHandshaked) {
    Write-DebugLog "Handshake not complete yet; cached track `"$($track.Title)`""
    return
  }

  if (-not $track -or $track.Status -eq "Stopped") {
    if ($script:lastActivityKey -ne "__cleared") {
      $clearFrame = @{
        cmd = "SET_ACTIVITY"
        args = @{
          pid = $PID
          activity = $null
        }
        nonce = [Guid]::NewGuid().ToString()
      }
      Send-DiscordFrame 1 $clearFrame
      $script:lastActivityKey = "__cleared"
      $script:activeTrackKey = ""
      $script:activeStartTime = 0
      $script:lastTrackObj = $null
      $script:pendingRetryTime = 0
      $script:retryAttempt = 0
      Write-Log "Presence cleared (playback stopped)"
    }
    return
  }

  $isPaused = $track.Status -eq "Paused"
  $posSec = if ($track.Position -ge 0) { [long][Math]::Floor($track.Position) } else { 0 }
  $durSec = if ($track.Duration -gt 0) { [long][Math]::Floor($track.Duration) } else { 0 }
  $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

  $trackKey = "$($track.Title)|$($track.Artist)"
  $startSec = if ($track.StartTime -gt 0) { [long]$track.StartTime } else { 0 }

  if ($startSec -eq 0 -and -not $isPaused) {
    if ($script:activeTrackKey -eq $trackKey -and $script:activeStartTime -gt 0 -and [Math]::Abs($nowSec - $posSec - $script:activeStartTime) -lt 3) {
      $startSec = $script:activeStartTime
    } else {
      $startSec = $nowSec - $posSec
    }
  }

  if (-not $isPaused -and $startSec -gt 0) {
    $script:activeTrackKey = $trackKey
    $script:activeStartTime = $startSec
  } elseif ($isPaused) {
    $script:activeTrackKey = $trackKey
  }

  # Cross-reference with session.json and active settings source
  $details = Resolve-TrackDetails $track.Title $track.Artist $false
  $activeSource = Get-ActiveSource $false

  if ($details) {
    Write-DebugLog "Matched session queue item: `"$($details.name)`" (Source: $($details.source))"
  } else {
    Write-DebugLog "No session.json queue match for `"$($track.Title)`" by `"$($track.Artist)`" (Active source: $activeSource)"
  }

  if ($durSec -eq 0 -and $details -and $details.duration -gt 0) {
    $durSec = [long][Math]::Floor($details.duration / 1000)
  }

  $endSec = if ($track.EndTime -gt $startSec) { [long]$track.EndTime } elseif ($durSec -gt 0 -and $startSec -gt 0) { [long]($startSec + $durSec) } else { 0 }

  $songUrl = if ($track.Url) { $track.Url } elseif ($details -and $details.url) { $details.url } else { $null }
  $songSource = if ($details -and $details.source) {
    $details.source
  } elseif ($activeSource) {
    $activeSource
  } elseif ($track.Source -and -not ($track.Source -match '(?i)mygo|egoist|windows')) {
    $track.Source
  } else {
    $null
  }

  # If songUrl is missing, synthesize using details.id OR title/artist search fallback
  if (-not $songUrl -and $songSource) {
    $songId = if ($details -and $details.id) { $details.id } else { $null }
    $songUrl = Synthesize-TrackUrl $songSource $songId $track.Title $track.Artist
    if ($songUrl) {
      Write-DebugLog "Synthesized $songSource URL: $songUrl"
    }
  }

  $sourceLabel = Format-SourceLabel $songSource $songUrl

  # Artwork resolution with online fallback search
  # Discord ONLY accepts http:// or https:// URLs. Discard local file:/// paths.
  $rawCover = if ($track.ImageUrl) { $track.ImageUrl } elseif ($details -and $details.album -and $details.album.imageUrl) { $details.album.imageUrl } else { $null }
  $coverUrl = $null
  if ($rawCover -and ($rawCover -match '^https?://')) {
    $coverUrl = $rawCover
  } elseif ($rawCover) {
    Write-DebugLog "Filtered out local/non-HTTP cover URL: $rawCover"
  }

  if (-not $coverUrl -or -not ($coverUrl -match '^https?://')) {
    Write-DebugLog "Using default icon for cover art"
    $coverUrl = $DEFAULT_ICON
  }

  # Schedule multi-stage background retry if online details, direct track URL, or real cover not found immediately
  $hasDirectUrl = ($songUrl -and ($songUrl -match 'watch\?v=|/track/|/song\?id=|\/video\/'))
  if (-not $details -or -not $hasDirectUrl -or $coverUrl -eq $DEFAULT_ICON) {
    if ($script:retryAttempt -lt $script:retryDelays.Count) {
      $delay = $script:retryDelays[$script:retryAttempt]
      $script:pendingRetryTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $delay
      $script:lastTrackObj = $track
      Write-DebugLog "Scheduled retry stage $($script:retryAttempt + 1) in ${delay}ms"
    }
  }

  # Key includes $coverUrl so any cover resolution immediately triggers an update
  $key = "$($track.Title)|$($track.Artist)|$($track.Album)|$($track.Status)|$([string]$isPaused)|$startSec|$sourceLabel|$songUrl|$coverUrl"
  if ($key -eq $script:lastActivityKey) { return }

  # Discord RPC Payload Sanitization (Strict Schema Compliance)
  # details: length 2-128 chars
  $titleStr = [string]$track.Title
  if ($titleStr.Length -lt 2) {
    $titleStr = "$titleStr "
  }
  if ($titleStr.Length -gt 128) {
    $titleStr = $titleStr.Substring(0, 125) + "..."
    Write-DebugLog "Title truncated to 128 characters: $titleStr"
  }

  # state: length 2-128 chars. Discord REJECTS empty state ("") with Code 4000. Omit if empty.
  $artistStr = [string]$track.Artist
  $stateStr = if ($isPaused) {
    if ($artistStr) { "$artistStr (Paused)" } else { "Paused" }
  } else {
    $artistStr
  }

  $headerName = if ($artistStr) { "$artistStr - $titleStr" } else { $titleStr }
  if ($headerName.Length -gt 128) { $headerName = $headerName.Substring(0, 125) + "..." }

  $activity = @{
    type = 2
    name = $headerName
    details = $titleStr
  }

  if ($stateStr -and $stateStr.Trim().Length -ge 2) {
    if ($stateStr.Length -gt 128) { $stateStr = $stateStr.Substring(0, 125) + "..." }
    $activity.state = $stateStr
  } else {
    Write-DebugLog "Omitted state property (artist empty or < 2 characters to satisfy Discord validation)"
  }

  $largeText = if ($track.Album) { [string]$track.Album } else { $titleStr }
  if ($largeText.Length -gt 128) { $largeText = $largeText.Substring(0, 125) + "..." }
  if ($largeText.Length -lt 2) { $largeText = "$largeText " }

  $activity.assets = @{
    large_image = $coverUrl
    large_text = $largeText
    small_image = $DEFAULT_ICON
    small_text = if ($isPaused) { "MyGo Music (Paused)" } else { "MyGo Music" }
  }

  if (-not $isPaused -and $startSec -gt 0) {
    $ts = @{ start = $startSec }
    if ($endSec -gt $startSec) {
      $ts.end = $endSec
    }
    $activity.timestamps = $ts
  }

  # buttons: max 2 buttons, label <= 32 chars, url <= 512 chars (must be http/https)
  $buttons = @()
  if ($sourceLabel -and $songUrl -and ($songUrl -match '^https?://') -and $songUrl.Length -le 512) {
    $bLabel = "Listen on $sourceLabel"
    if ($bLabel.Length -gt 32) { $bLabel = $bLabel.Substring(0, 32) }
    $buttons += @{
      label = $bLabel
      url = $songUrl
    }
  }
  $buttons += @{
    label = "Download MyGo Music"
    url = $DOWNLOAD_URL
  }

  $activity.buttons = $buttons
  $activity.metadata = @{
    button_urls = ($buttons | ForEach-Object { $_.url })
  }

  $frame = @{
    cmd = "SET_ACTIVITY"
    args = @{
      pid = $PID
      activity = $activity
    }
    nonce = [Guid]::NewGuid().ToString()
  }

  if (Send-DiscordFrame 1 $frame) {
    $script:lastActivityKey = $key
    $btnDesc = if ($sourceLabel) { "[$sourceLabel + Download]" } else { "[Download only]" }
    $covDesc = if ($coverUrl -ne $DEFAULT_ICON) { "[Cover: OK]" } else { "[Cover: Default]" }
    $artDesc = if ($artistStr) { "by $artistStr " } else { "" }
    Write-Log "Updated Discord Presence: `"$titleStr`" $artDesc(Status: $($track.Status)) $btnDesc $covDesc"
  }
}

# -------------------------------------------------------------
# 6. Graceful Shutdown & Cleanup Handler
# -------------------------------------------------------------
$script:isStopping = $false

function Stop-Bridge {
  if ($script:isStopping) { return }
  $script:isStopping = $true

  Write-Log "Shutting down Windows Native Bridge (clearing Discord presence)..."
  try {
    if ($script:pipe -and $script:pipe.IsConnected) {
      $clearFrame = @{
        cmd = "SET_ACTIVITY"
        args = @{
          pid = $PID
          activity = $null
        }
        nonce = [Guid]::NewGuid().ToString()
      }
      Send-DiscordFrame 1 $clearFrame | Out-Null
      Start-Sleep -Milliseconds 60
      $script:pipe.Flush()
      $script:pipe.Dispose()
      $script:pipe = $null
    }
  } catch {}

  try {
    $pidFile = Join-Path $env:TEMP "discord-mygo-music.pid"
    if (Test-Path $pidFile) {
      Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    }
  } catch {}
  Write-Log "Bridge shutdown complete."
}

try {
  $cancelHandler = [ConsoleCancelEventHandler]{
    param($sender, $e)
    Stop-Bridge
  }
  [Console]::add_CancelKeyPress($cancelHandler)
} catch {}

try {
  $onExit = { Stop-Bridge }
  $null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action $onExit -ErrorAction SilentlyContinue
} catch {}

# -------------------------------------------------------------
# 7. Main Polling Loop
# -------------------------------------------------------------
$lastMetaKey = ""
$lastStartSec = 0
$fallbackStartSec = 0
$missingCount = 0

Write-Log "Native Windows Bridge active. Polling GSMTC and Discord IPC..."

try {
  while ($true) {
    # 1. Maintain Discord Connection
    if (-not $script:pipe -or -not $script:pipe.IsConnected) {
      $script:pipe = Connect-DiscordPipe
      if ($script:pipe) {
        Handshake-Discord | Out-Null
      }
    }

    # 2. Check incoming Discord messages
    Check-IncomingPipe

    # 3. Query WinRT GSMTC for active media
    $found = $null
    if ($gsmtcMgr) {
      try {
        $sessions = $gsmtcMgr.GetSessions()
        if ($script:isDebug -and ($script:debugTickCount % 15 -eq 0)) {
          $activeNames = if ($sessions) { ($sessions | ForEach-Object { $_.SourceAppUserModelId }) -join ", " } else { "None" }
          Write-DebugLog "WinRT GSMTC tick: $($sessions.Count) active sessions [$activeNames]"
        }
        $script:debugTickCount++

        foreach ($s in $sessions) {
          $src = [string]$s.SourceAppUserModelId
          if ($src -match '(?i)mygo|egoist') {
            $p = $s.GetPlaybackInfo()
            $props = Await-Op ($s.TryGetMediaPropertiesAsync()) $propsType
            $tl = $s.GetTimelineProperties()

            $pos = [double]$tl.Position.TotalSeconds
            $dur = [double]$tl.EndTime.TotalSeconds
            $currMetaKey = "$($props.Title)|$($props.Artist)|$($props.AlbumTitle)|$($p.PlaybackStatus)"
            $hasLastUpdated = ($tl.LastUpdatedTime -and $tl.LastUpdatedTime.Year -ge 2020)

            if ($hasLastUpdated) {
              $startSec = [long]($tl.LastUpdatedTime.ToUnixTimeSeconds() - [Math]::Round($pos))
            } else {
              if ($fallbackStartSec -eq 0 -or $currMetaKey -ne $lastMetaKey) {
                $fallbackStartSec = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [Math]::Round($pos))
              }
              $startSec = $fallbackStartSec
            }

            Write-DebugLog "GSMTC matched MyGo: `"$($props.Title)`" by `"$($props.Artist)`" (Status: $($p.PlaybackStatus), Pos: ${pos}s, Dur: ${dur}s)"

            $found = [PSCustomObject]@{
              Source    = $src
              Title     = [string]$props.Title
              Artist    = [string]$props.Artist
              Album     = [string]$props.AlbumTitle
              Status    = [string]$p.PlaybackStatus
              Position  = $pos
              Duration  = $dur
              StartTime = $startSec
              EndTime   = if ($dur -gt 0) { [long]($startSec + $dur) } else { 0 }
              Url       = $null
              ImageUrl  = $null
            }
            break
          }
        }
      } catch {
        Write-DebugLog "GSMTC query error: $($_.Exception.Message)"
      }
    }

    # 4. Fallback: if GSMTC didn't find session, check session.json directly
    if (-not $found -or -not $found.Title) {
      $sess = Get-SessionData
      if ($sess -and $sess.queue -and $sess.queue.Count -gt 0) {
        $idx = if ($sess.at -ne $null) { [int]$sess.at } else { 0 }
        if ($sess.shuffle -and $sess.order -and $sess.order.Count -gt $idx) {
          $idx = [int]$sess.order[$idx]
        }
        if ($idx -lt $sess.queue.Count) {
          $cur = $sess.queue[$idx]
          if ($cur -and $cur.name) {
            $isMyGoRunning = [bool](Get-Process -Name "MyGo Music" -ErrorAction SilentlyContinue)
            $item = Get-Item $sessionPath -ErrorAction SilentlyContinue
            # If MyGo Music is running, accept session.json if updated within 300 seconds
            $isRecent = $item -and ($item.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddSeconds(-300))
            if ($isMyGoRunning -and $isRecent) {
              Write-DebugLog "Active MyGo process detected; using session.json fallback for `"$($cur.name)`""
              $artists = if ($cur.artists) { ($cur.artists | ForEach-Object { $_.name }) -join ", " } else { "" }
              $dur = if ($cur.duration) { [double]($cur.duration / 1000) } else { 0 }
              $pos = if ($sess.position) { [double]($sess.position / 1000) } else { 0 }
              $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
              $startSec = [long]($nowSec - [Math]::Round($pos))

              $found = [PSCustomObject]@{
                Source    = if ($cur.source) { $cur.source } else { "MyGo Music" }
                Title     = [string]$cur.name
                Artist    = $artists
                Album     = if ($cur.album) { [string]$cur.album.name } else { "" }
                Status    = "Playing"
                Position  = $pos
                Duration  = $dur
                StartTime = $startSec
                EndTime   = if ($dur -gt 0) { [long]($startSec + $dur) } else { 0 }
                Url       = if ($cur.url) { $cur.url } else { $null }
                ImageUrl  = if ($cur.album -and $cur.album.imageUrl) { $cur.album.imageUrl } else { $null }
              }
            }
          }
        }
      }
    }

    # 5. Process media update
    if ($found -and $found.Title) {
      $missingCount = 0
      $metaKey = "$($found.Title)|$($found.Artist)|$($found.Album)|$($found.Status)"
      $seekChanged = [Math]::Abs($found.StartTime - $lastStartSec) -ge 2
      $stateChanged = $metaKey -ne $lastMetaKey

      if ($stateChanged -or ($found.Status -eq 'Playing' -and $seekChanged)) {
        $lastMetaKey = $metaKey
        $lastStartSec = $found.StartTime
        $script:retryAttempt = 0 # Reset retry attempts for new track
        Update-Activity $found
      }
    } else {
      $missingCount++
      if ($missingCount -ge 3 -and $lastMetaKey -ne '__stopped') {
        $lastMetaKey = '__stopped'
        $lastStartSec = 0
        $fallbackStartSec = 0
        $script:retryAttempt = 0
        Write-DebugLog "No media detected after $missingCount ticks, clearing presence"
        Update-Activity $null
      }
    }

    # 6. Check asynchronous retry for enriched session details & album covers
    if ($script:pendingRetryTime -gt 0 -and [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -ge $script:pendingRetryTime) {
      $script:pendingRetryTime = 0
      $script:retryAttempt++
      if ($script:lastTrackObj -and $lastMetaKey -ne '__stopped') {
        $freshDetails = Resolve-TrackDetails $script:lastTrackObj.Title $script:lastTrackObj.Artist $true
        if ($freshDetails) {
          Write-Log "Enriched track details and artwork from session for `"$($script:lastTrackObj.Title)`""
          $script:lastActivityKey = "" # Force re-send with newly enriched details/cover
          Update-Activity $script:lastTrackObj
        } elseif ($script:retryAttempt -lt $script:retryDelays.Count) {
          # Reschedule next retry if still not written to disk yet
          $delay = $script:retryDelays[$script:retryAttempt]
          $script:pendingRetryTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $delay
          Write-DebugLog "Rescheduled retry stage $($script:retryAttempt + 1) in ${delay}ms"
        }
      }
    }

    Start-Sleep -Milliseconds 300
  }
} finally {
  Stop-Bridge
}
