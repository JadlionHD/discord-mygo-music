# bridge-windows.ps1 - Native Windows Discord Rich Presence Bridge for MyGo Music
# 100% Native: Zero Node.js, Bun, or Deno required.
# Uses: Windows PowerShell 5.1+, .NET NamedPipeClientStream, and WinRT GSMTC.

param(
  [string]$ClientId = "631447533323026432"
)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$DEFAULT_ICON = "https://raw.githubusercontent.com/egoist/mygo-music/main/resources/icon.png"
$DOWNLOAD_URL = "https://music.egoist.dev/"
$coverCache = @{}

function Write-Log([string]$msg) {
  $ts = [DateTime]::UtcNow.ToString("o")
  [Console]::WriteLine("[$ts] [discord-mygo-music-native] $msg")
}

Write-Log "Starting Windows Native Discord RPC Bridge (Client ID: $ClientId)"

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
} catch {
  Write-Log "Warning: Could not initialize WinRT GSMTC session manager: $($_.Exception.Message)"
}

# -------------------------------------------------------------
# 4. Session & Track Helpers (Non-locking FileShare)
# -------------------------------------------------------------
$sessionPath = Join-Path $env:APPDATA "MyGo Music\session.json"
$script:cachedSession = $null
$script:lastSessionMtime = 0

function Get-SessionData([bool]$forceReload = $false) {
  if (-not (Test-Path $sessionPath)) { return $null }
  try {
    $item = Get-Item $sessionPath
    $mtime = $item.LastWriteTimeUtc.Ticks
    if (-not $forceReload -and $script:cachedSession -and $mtime -eq $script:lastSessionMtime) {
      return $script:cachedSession
    }

    # Open with FileShare.ReadWrite to prevent locking conflicts when MyGo Music writes
    $fs = [System.IO.FileStream]::new($sessionPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
    $raw = $sr.ReadToEnd()
    $sr.Dispose()
    $fs.Dispose()

    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $parsed = $raw | ConvertFrom-Json
      $script:cachedSession = $parsed
      $script:lastSessionMtime = $mtime
      return $parsed
    }
  } catch {}
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

function Search-Cover([string]$title, [string]$artist) {
  if (-not $title) { return $null }
  $cacheKey = "$title|$artist"
  if ($script:coverCache.ContainsKey($cacheKey)) {
    return $script:coverCache[$cacheKey]
  }

  try {
    $query = [System.Uri]::EscapeDataString("$title $artist".Trim())
    $url = "https://music.163.com/api/cloudsearch/pc?s=$query&type=1&limit=3&offset=0"
    $req = [System.Net.WebRequest]::Create($url)
    $req.Timeout = 2500
    $req.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36"
    $req.Referer = "https://music.163.com/"
    
    $resp = $req.GetResponse()
    $stream = $resp.GetResponseStream()
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
    $json = $reader.ReadToEnd() | ConvertFrom-Json
    $reader.Dispose()
    $stream.Dispose()
    $resp.Dispose()

    if ($json -and $json.result -and $json.result.songs -and $json.result.songs.Count -gt 0) {
      $song = $json.result.songs[0]
      $pic = if ($song.al -and $song.al.picUrl) { $song.al.picUrl } elseif ($song.album -and $song.album.picUrl) { $song.album.picUrl } else { $null }
      if ($pic) {
        $pic = $pic -replace '^http://', 'https://'
        $script:coverCache[$cacheKey] = $pic
        return $pic
      }
    }
  } catch {}

  $script:coverCache[$cacheKey] = $null
  return $null
}

function Resolve-TrackDetails([string]$title, [string]$artist, [bool]$forceReload = $false) {
  $sess = Get-SessionData $forceReload
  if (-not $sess -or -not $sess.queue -or $sess.queue.Count -eq 0) { return $null }

  $nTitle = Normalize-Text $title
  $nArtist = Normalize-Text $artist
  $cTitle = Clean-Title $title

  # 1. Check current queue pointer first
  $idx = if ($sess.at -ne $null) { [int]$sess.at } else { 0 }
  if ($sess.shuffle -and $sess.order -and $sess.order.Count -gt $idx) {
    $idx = [int]$sess.order[$idx]
  }
  if ($idx -lt $sess.queue.Count) {
    $cur = $sess.queue[$idx]
    if ($cur -and $cur.name) {
      $curNTitle = Normalize-Text $cur.name
      $curCTitle = Clean-Title $cur.name
      if ($curNTitle -eq $nTitle -or ($cTitle -and $curCTitle -eq $cTitle)) {
        return $cur
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

    $score = 0
    if ($tnTitle -eq $nTitle -and (-not $nArtist -or $tnArtist.Contains($nArtist) -or $nArtist.Contains($tnArtist))) {
      $score = 100
    } elseif ($cTitle -and $tcTitle -eq $cTitle -and (-not $nArtist -or $tnArtist.Contains($nArtist) -or $nArtist.Contains($tnArtist))) {
      $score = 90
    } elseif ($tnTitle -eq $nTitle) {
      $score = 80
    } elseif ($cTitle -and $tcTitle -eq $cTitle) {
      $score = 75
    } elseif ($cTitle -and ($tcTitle.Contains($cTitle) -or $cTitle.Contains($tcTitle))) {
      if ($nArtist -and ($tnArtist.Contains($nArtist) -or $nArtist.Contains($tnArtist))) {
        $score = 60
      }
    }

    if ($score -gt $bestScore) {
      $bestScore = $score
      $best = $t
    }
  }

  if ($bestScore -ge 60) { return $best }
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

  if ($lu.Contains("music.youtube.com") -or $s -in @("youtube-music", "ytmusic")) {
    return "YouTube Music"
  }
  if ($lu.Contains("youtube.com") -or $lu.Contains("youtu.be") -or $s -eq "youtube") {
    return "YouTube"
  }
  if ($lu.Contains("spotify.com") -or $s -in @("spotify", "mygotify")) {
    return "Spotify"
  }
  if ($lu.Contains("163.com") -or $s.Contains("netease") -or $s -in @("163", "cloudmusic")) {
    return "NetEase"
  }
  if ($lu.Contains("bilibili.com") -or $s -eq "bilibili") {
    return "Bilibili"
  }
  if ($lu.Contains("soundcloud.com") -or $s -eq "soundcloud") {
    return "SoundCloud"
  }
  if ($lu.Contains("music.apple.com") -or $s -in @("apple", "applemusic")) {
    return "Apple Music"
  }
  if ($lu.Contains("bandcamp.com") -or $s -eq "bandcamp") {
    return "Bandcamp"
  }
  if ($lu.Contains("deezer.com") -or $s -eq "deezer") {
    return "Deezer"
  }
  if ($lu.Contains("tidal.com") -or $s -eq "tidal") {
    return "Tidal"
  }
  if ($lu.Contains("qq.com") -or $s.Contains("qqmusic") -or $s -eq "qq") {
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
$script:retryDelays = @(150, 450, 1000, 2000)
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
            Update-Activity $script:currentTrack
          }
        }
      } elseif ($opcode -eq 3) {
        # PING -> PONG
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
    # Store track and wait until Discord READY handshake arrives
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

  # Cross-reference with session.json
  $details = Resolve-TrackDetails $track.Title $track.Artist
  if ($durSec -eq 0 -and $details -and $details.duration -gt 0) {
    $durSec = [long][Math]::Floor($details.duration / 1000)
  }

  $endSec = if ($track.EndTime -gt $startSec) { [long]$track.EndTime } elseif ($durSec -gt 0 -and $startSec -gt 0) { [long]($startSec + $durSec) } else { 0 }

  $songUrl = if ($track.Url) { $track.Url } elseif ($details -and $details.url) { $details.url } else { $null }
  $songSource = if ($details -and $details.source) { $details.source } elseif ($track.Source -and -not ($track.Source -match '(?i)mygo|egoist|windows')) { $track.Source } else { $null }

  # URL synthesis if missing
  if (-not $songUrl -and $details -and $details.id) {
    $s = ($songSource + "").ToLower()
    if ($s -in @("youtube-music", "ytmusic", "youtube")) {
      $songUrl = "https://music.youtube.com/watch?v=$($details.id)"
    } elseif ($s -in @("spotify", "mygotify")) {
      $songUrl = "https://open.spotify.com/track/$($details.id)"
    } elseif ($s.Contains("netease") -or $s -in @("163", "cloudmusic")) {
      $songUrl = "https://music.163.com/#/song?id=$($details.id)"
    } elseif ($s -eq "bilibili") {
      $songUrl = "https://www.bilibili.com/video/$($details.id)"
    }
  }

  $sourceLabel = Format-SourceLabel $songSource $songUrl

  # Artwork resolution with online fallback search
  $coverUrl = if ($track.ImageUrl) { $track.ImageUrl } elseif ($details -and $details.album -and $details.album.imageUrl) { $details.album.imageUrl } else { $null }
  if (-not $coverUrl) {
    $coverUrl = Search-Cover $track.Title $track.Artist
  }
  if (-not $coverUrl) {
    $coverUrl = $DEFAULT_ICON
  }

  # Schedule multi-stage background retry if online details or real cover not found immediately
  if (-not $isPaused -and (-not $details -or -not $songUrl -or $coverUrl -eq $DEFAULT_ICON)) {
    if ($script:retryAttempt -lt $script:retryDelays.Count) {
      $delay = $script:retryDelays[$script:retryAttempt]
      $script:pendingRetryTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $delay
      $script:lastTrackObj = $track
    }
  }

  # Key includes $coverUrl so any cover resolution immediately triggers an update
  $key = "$($track.Title)|$($track.Artist)|$($track.Album)|$($track.Status)|$([string]$isPaused)|$startSec|$sourceLabel|$songUrl|$coverUrl"
  if ($key -eq $script:lastActivityKey) { return }

  $headerName = if ($track.Artist) { "$($track.Artist) - $($track.Title)" } else { $track.Title }

  $activity = @{
    type = 2
    name = $headerName
    details = $track.Title
    state = if ($isPaused) { "$($track.Artist) (Paused)" } else { $track.Artist }
    assets = @{
      large_image = $coverUrl
      large_text = if ($track.Album) { $track.Album } else { $track.Title }
      small_image = $DEFAULT_ICON
      small_text = if ($isPaused) { "MyGo Music (Paused)" } else { "MyGo Music" }
    }
  }

  if (-not $isPaused -and $startSec -gt 0) {
    $ts = @{ start = $startSec }
    if ($endSec -gt $startSec) {
      $ts.end = $endSec
    }
    $activity.timestamps = $ts
  }

  $buttons = @()
  if ($sourceLabel -and $songUrl -and ($songUrl -match '^https?://')) {
    $buttons += @{
      label = "Listen on $sourceLabel"
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
    Write-Log "Updated Discord Presence: `"$($track.Title)`" by $($track.Artist) ($($track.Status)) $btnDesc $covDesc"
  }
}

# -------------------------------------------------------------
# 6. Main Polling Loop
# -------------------------------------------------------------
$lastMetaKey = ""
$lastStartSec = 0
$fallbackStartSec = 0
$missingCount = 0

Write-Log "Native Windows Bridge active. Polling GSMTC and Discord IPC..."

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
      foreach ($s in $gsmtcMgr.GetSessions()) {
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
    } catch {}
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
          $artists = if ($cur.artists) { ($cur.artists | ForEach-Object { $_.name }) -join ", " } else { "" }
          $dur = if ($cur.duration) { [double]($cur.duration / 1000) } else { 0 }
          $pos = if ($sess.position) { [double]($sess.position / 1000) } else { 0 }
          $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
          $startSec = [long]($nowSec - [Math]::Round($pos))

          $item = Get-Item $sessionPath -ErrorAction SilentlyContinue
          if ($item -and ($item.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddSeconds(-15))) {
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
      }
    }
  }

  Start-Sleep -Milliseconds 300
}
