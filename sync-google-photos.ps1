<#
  Sync Google Photos shared albums into the Photos folder for the offline slideshow.

  - Album links live in albums.txt next to this script (one per line). On first run
    you are asked to paste one.
  - Only new photos/videos are downloaded; ones removed from the album are removed here.
  - Works offline: if Google Photos can't be reached, the photos already downloaded
    are used as-is.
  - Writes Photos\library.js, which slideshow.html reads to play everything with no
    folder picking.

  This reads the public shared-album web page (Google offers no official way to
  read a whole album any more), so a change on Google's side can break syncing.
  Already-downloaded photos keep playing either way.
#>
param(
  [int]$MaxSize = 3840,          # longest side of downloaded photos, in pixels
  [string]$AlbumsFile,
  [string]$PhotosDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar on
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$Root = $PSScriptRoot
if (-not $AlbumsFile) { $AlbumsFile = Join-Path $Root 'albums.txt' }
if (-not $PhotosDir) { $PhotosDir = Join-Path $Root 'Photos' }
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0'
$MediaPattern = '\.(jpe?g|png|gif|webp|avif|bmp|heic|mp4|m4v|webm|mov)$'
$VideoPattern = '\.(mp4|m4v|webm|mov)$'
$SyncedName = '^\d{4}-\d{2}-\d{2}_\d{6}_([0-9a-f]{10})\.[a-z0-9]+$'
$Sha1 = [System.Security.Cryptography.SHA1]::Create()

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }

function Get-ShortId([string]$Text) {
  $bytes = $Sha1.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
  (($bytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 10)
}

function ConvertFrom-JsonText([string]$Json) {
  if ($PSVersionTable.PSVersion.Major -ge 6) {
    return , (ConvertFrom-Json -InputObject $Json -NoEnumerate)
  }
  # Windows PowerShell 5.1: ConvertFrom-Json chokes on large documents, so use the serializer directly.
  Add-Type -AssemblyName System.Web.Extensions
  $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $serializer.MaxJsonLength = [int]::MaxValue
  $serializer.RecursionLimit = 1000
  return , ($serializer.DeserializeObject($Json))
}

function ConvertTo-JsonString([string]$Text) {
  '"' + ($Text -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Test-HasKey($Value, [string]$Key, [int]$Depth = 0) {
  if ($null -eq $Value -or $Depth -gt 8 -or $Value -is [string]) { return $false }
  if ($Value -is [System.Collections.IDictionary]) {
    if ($Value.Contains($Key)) { return $true }
    foreach ($v in $Value.Values) { if (Test-HasKey $v $Key ($Depth + 1)) { return $true } }
  } elseif ($Value -is [array]) {
    foreach ($v in $Value) { if (Test-HasKey $v $Key ($Depth + 1)) { return $true } }
  } elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $Value.PSObject.Properties) {
      if ($p.Name -eq $Key) { return $true }
      if (Test-HasKey $p.Value $Key ($Depth + 1)) { return $true }
    }
  }
  return $false
}

function Get-SafeName([string]$Name) {
  $clean = ($Name -replace '[\\/:*?"<>|\x00-\x1f]', ' ' -replace '\s+', ' ').Trim().TrimEnd('.')
  if ($clean.Length -gt 80) { $clean = $clean.Substring(0, 80).Trim() }
  return $clean
}

# ---------------------------------------------------------------- album links

function Get-AlbumLinks {
  $links = @()
  if (Test-Path -LiteralPath $AlbumsFile) {
    $links = @(Get-Content -LiteralPath $AlbumsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
  }
  if ($links.Count -eq 0) {
    Say ''
    Say 'First-time setup' 'Cyan'
    Say '1. Open the album in Google Photos (photos.google.com or the app).'
    Say '2. Click Share, then "Create link" or "Copy link".'
    Say '3. Paste the link below and press Enter. (Add more albums later in albums.txt.)'
    Say ''
    $link = (Read-Host 'Album link').Trim()
    if ($link) {
      $header = @(
        '# Google Photos shared album links, one per line.',
        '# Lines starting with # are ignored. Remove a line to remove that album from the slideshow.'
      )
      Set-Content -LiteralPath $AlbumsFile -Value ($header + $link) -Encoding UTF8
      $links = @($link)
    }
  }
  foreach ($l in $links) { $l }
}

# ---------------------------------------------------------------- reading an album

function Get-Album([string]$Link) {
  $resp = Invoke-WebRequest -Uri $Link -UseBasicParsing -UserAgent $UserAgent -Headers @{ 'Accept-Language' = 'en' } -MaximumRedirection 10
  $html = [string]$resp.Content
  $finalUrl = $null
  try { $finalUrl = $resp.BaseResponse.ResponseUri.AbsoluteUri } catch {}
  if (-not $finalUrl) { try { $finalUrl = $resp.BaseResponse.RequestMessage.RequestUri.AbsoluteUri } catch {} }
  if (-not $finalUrl) { $finalUrl = $Link }

  # Album title
  $title = ''
  $m = [regex]::Match($html, '<meta\s+property="og:title"\s+content="([^"]*)"')
  if ($m.Success) { $title = $m.Groups[1].Value }
  if (-not $title) {
    $m = [regex]::Match($html, '<title>([^<]*)</title>')
    if ($m.Success) { $title = $m.Groups[1].Value -replace '\s*[-\u2013]\s*Google Photos\s*$', '' }
  }
  $title = [System.Net.WebUtility]::HtmlDecode($title).Trim()

  # The album contents are embedded as AF_initDataCallback({... data:[...] ...}); pick the largest.
  $best = ''
  foreach ($blob in [regex]::Matches($html, 'AF_initDataCallback\((\{[\s\S]*?\})\);</script>')) {
    $b = $blob.Groups[1].Value
    if ($b.Contains('data:') -and $b.Length -gt $best.Length) { $best = $b }
  }
  if (-not $best) { throw "This doesn't look like a shared Google Photos album (no album data found). Check the link is shared with 'anyone with the link'." }
  $m = [regex]::Match($best, 'data:([\s\S]*\])\s*,\s*sideChannel\s*:')
  if (-not $m.Success) { $m = [regex]::Match($best, 'data:([\s\S]*\])') }
  $data = ConvertFrom-JsonText $m.Groups[1].Value
  if (-not ($data -is [array]) -or $data.Count -lt 2 -or -not ($data[1] -is [array])) {
    throw 'Unexpected album format. Google may have changed the shared-album page.'
  }

  $items = New-Object System.Collections.ArrayList
  Add-AlbumItems $data[1] $items
  $token = $null
  if ($data.Count -gt 2 -and $data[2] -is [string]) { $token = $data[2] }

  # Large albums arrive in pages; fetch the rest (best effort).
  $complete = $true
  if ($token) {
    try {
      $albumId = [regex]::Match($finalUrl, '/share/([^/?#]+)').Groups[1].Value
      $authKey = [regex]::Match($finalUrl, '[?&]key=([^&#]+)').Groups[1].Value
      $origin = ([Uri]$finalUrl).GetLeftPart([UriPartial]::Authority)
      $xsrf = [regex]::Match($html, '"SNlM0e":"([^"]+)"').Groups[1].Value
      $pages = 0
      while ($token -and $pages -lt 200) {
        $pages++
        $page = Get-AlbumPage $origin $albumId $authKey $token $xsrf
        Add-AlbumItems $page[1] $items
        $token = $null
        if ($page.Count -gt 2 -and $page[2] -is [string]) { $token = $page[2] }
      }
    } catch {
      $complete = $false
      Say ("  Note: only the first {0} items could be read. Google may have changed how large albums load." -f $items.Count) 'Yellow'
    }
  }
  return @{ Title = $title; Items = $items; Complete = $complete }
}

function Get-AlbumPage([string]$Origin, [string]$AlbumId, [string]$AuthKey, [string]$Token, [string]$Xsrf) {
  $inner = '[' + (ConvertTo-JsonString $AlbumId) + ',' + (ConvertTo-JsonString $Token) + ',null,' + (ConvertTo-JsonString $AuthKey) + ']'
  $freq = '[[["snAcKc",' + (ConvertTo-JsonString $inner) + ',null,"generic"]]]'
  $body = 'f.req=' + [Uri]::EscapeDataString($freq)
  if ($Xsrf) { $body += '&at=' + [Uri]::EscapeDataString($Xsrf) }
  $url = $Origin + '/_/PlusAppUi/data/batchexecute?rpcids=snAcKc&source-path=' + [Uri]::EscapeDataString('/share/' + $AlbumId)
  $resp = Invoke-WebRequest -Uri $url -Method Post -Body $body -UseBasicParsing -UserAgent $UserAgent `
    -ContentType 'application/x-www-form-urlencoded;charset=UTF-8'
  $text = [string]$resp.Content
  $start = $text.IndexOf('[')
  if ($start -lt 0) { throw 'bad page response' }
  $envelope = ConvertFrom-JsonText $text.Substring($start).Trim()
  foreach ($row in $envelope) {
    if ($row -is [array] -and $row.Count -gt 2 -and $row[0] -eq 'wrb.fr' -and $row[1] -eq 'snAcKc' -and $row[2] -is [string]) {
      $page = ConvertFrom-JsonText $row[2]
      if ($page -is [array] -and $page.Count -gt 1 -and $page[1] -is [array]) { return , $page }
    }
  }
  throw 'page data not found'
}

function Add-AlbumItems($Raw, [System.Collections.ArrayList]$Into) {
  foreach ($e in $Raw) {
    if (-not ($e -is [array]) -or $e.Count -lt 3) { continue }
    $uid = $e[0]
    $detail = $e[1]
    if (-not ($uid -is [string]) -or -not ($detail -is [array]) -or $detail.Count -lt 1 -or -not ($detail[0] -is [string])) { continue }
    $when = Get-Date
    if ($e[2] -is [ValueType]) {
      try { $when = [DateTimeOffset]::FromUnixTimeMilliseconds([int64][double]$e[2]).LocalDateTime } catch {}
    }
    [void]$Into.Add(@{
      Id      = Get-ShortId $uid
      Url     = $detail[0]
      Date    = $when
      IsVideo = (Test-HasKey $e '76647426')   # video metadata block in Google's album data
    })
  }
}

# ---------------------------------------------------------------- syncing one album

function Find-AlbumFolder([string]$Link, [string]$Title, [int]$Number) {
  if (-not (Test-Path -LiteralPath $PhotosDir)) { New-Item -ItemType Directory -Path $PhotosDir | Out-Null }
  $existing = $null
  foreach ($dir in Get-ChildItem -LiteralPath $PhotosDir -Directory) {
    $marker = Join-Path $dir.FullName '.album-link'
    if ((Test-Path -LiteralPath $marker) -and ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $Link)) { $existing = $dir; break }
  }
  $name = Get-SafeName $Title
  if (-not $name) { $name = "Album $Number" }

  if ($existing) {
    if ($existing.Name -ne $name -and -not (Test-Path -LiteralPath (Join-Path $PhotosDir $name))) {
      Rename-Item -LiteralPath $existing.FullName -NewName $name
      return (Join-Path $PhotosDir $name)
    }
    return $existing.FullName
  }
  $candidate = $name
  $n = 2
  while (Test-Path -LiteralPath (Join-Path $PhotosDir $candidate)) { $candidate = "$name ($n)"; $n++ }
  $path = Join-Path $PhotosDir $candidate
  New-Item -ItemType Directory -Path $path | Out-Null
  Set-Content -LiteralPath (Join-Path $path '.album-link') -Value $Link -Encoding UTF8
  (Get-Item -LiteralPath (Join-Path $path '.album-link') -Force).Attributes = 'Hidden'
  return $path
}

function Get-Extension([string]$ContentType, [bool]$IsVideo) {
  switch -regex ($ContentType) {
    'image/jpe?g'      { return 'jpg' }
    'image/png'        { return 'png' }
    'image/gif'        { return 'gif' }
    'image/webp'       { return 'webp' }
    'image/heic'       { return 'heic' }
    'video/mp4'        { return 'mp4' }
    'video/webm'       { return 'webm' }
    'video/quicktime'  { return 'mov' }
  }
  if ($IsVideo) { return 'mp4' }
  return 'jpg'
}

function Sync-Album([string]$Link, [int]$Number) {
  Say ''
  Say "Album $Number" 'Cyan'
  $album = Get-Album $Link
  $label = $album.Title
  if (-not $label) { $label = "Album $Number" }
  $folder = Find-AlbumFolder $Link $album.Title $Number
  Say ("  {0}: {1} items in Google Photos" -f $label, $album.Items.Count)

  $have = @{}
  foreach ($f in Get-ChildItem -LiteralPath $folder -File) {
    $m = [regex]::Match($f.Name, $SyncedName)
    if ($m.Success) { $have[$m.Groups[1].Value] = $f }
  }

  $wanted = @{}
  $added = 0; $failed = 0
  foreach ($item in $album.Items) {
    $wanted[$item.Id] = $true
    if ($have.ContainsKey($item.Id)) { continue }
    $src = if ($item.IsVideo) { $item.Url + '=dv' } else { $item.Url + "=w$MaxSize-h$MaxSize" }
    $tmp = Join-Path $folder (".{0}.part" -f $item.Id)
    try {
      $resp = Invoke-WebRequest -Uri $src -UseBasicParsing -UserAgent $UserAgent -OutFile $tmp -PassThru
      $ext = Get-Extension ([string]$resp.Headers['Content-Type']) $item.IsVideo
      $final = Join-Path $folder ("{0:yyyy-MM-dd_HHmmss}_{1}.{2}" -f $item.Date, $item.Id, $ext)
      Move-Item -LiteralPath $tmp -Destination $final -Force
      (Get-Item -LiteralPath $final).LastWriteTime = $item.Date
      $added++
      Write-Host ("`r  Downloaded {0} new" -f $added) -NoNewline
    } catch {
      $failed++
      if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
  }
  if ($added) { Write-Host '' }

  # Mirror deletions, but only when the whole album was read.
  $removed = 0
  if ($album.Complete -and $album.Items.Count -gt 0) {
    foreach ($id in @($have.Keys)) {
      if (-not $wanted.ContainsKey($id)) { Remove-Item -LiteralPath $have[$id].FullName -Force; $removed++ }
    }
  }
  $summary = "  Up to date: $added new"
  if ($removed) { $summary += ", $removed removed" }
  if ($failed) { $summary += ", $failed could not be downloaded (will retry next time)" }
  Say $summary 'Green'
  return $folder
}

# ---------------------------------------------------------------- library.js for the slideshow

function Write-Library([string]$Status) {
  if (-not (Test-Path -LiteralPath $PhotosDir)) { New-Item -ItemType Directory -Path $PhotosDir | Out-Null }
  $base = (Resolve-Path -LiteralPath $PhotosDir).ProviderPath.TrimEnd('\', '/')
  $epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
  $entries = New-Object System.Collections.ArrayList
  foreach ($f in Get-ChildItem -LiteralPath $base -Recurse -File) {
    if ($f.Name -notmatch $MediaPattern -or $f.Name.StartsWith('.')) { continue }
    $rel = $f.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
    $kind = if ($f.Name -match $VideoPattern) { 'video' } else { 'image' }
    [void]$entries.Add(@{
      path = 'Photos/' + $rel
      kind = $kind
      date = [int64]($f.LastWriteTimeUtc - $epoch).TotalMilliseconds
      size = $f.Length
    })
  }
  $lib = @{
    syncedAt = [int64]((Get-Date).ToUniversalTime() - $epoch).TotalMilliseconds
    status   = $Status
    items    = @($entries)
  }
  $json = ConvertTo-Json -InputObject $lib -Depth 5 -Compress
  $js = "// Written by sync-google-photos.ps1. Safe to delete; it is rebuilt on every sync.`r`nwindow.SLIDESHOW_LIBRARY = $json;`r`n"
  [IO.File]::WriteAllText((Join-Path $base 'library.js'), $js, (New-Object Text.UTF8Encoding $false))
  return $entries.Count
}

# ---------------------------------------------------------------- main

Say 'Photo Slideshow: syncing Google Photos' 'White'
$links = @(Get-AlbumLinks)
$status = 'synced'
$problems = 0
$synced = @()
if ($links.Count -eq 0) {
  Say 'No album link yet. The slideshow will only show files already in the Photos folder.' 'Yellow'
  $status = 'no-albums'
} else {
  $online = $true
  $i = 0
  foreach ($link in $links) {
    $i++
    try {
      $synced += Sync-Album $link $i
    } catch {
      $problems++
      $ex = $_.Exception
      $msg = $ex.Message
      $httpStatus = $null
      try { if ($ex.Response) { $httpStatus = [int]$ex.Response.StatusCode } } catch {}
      $noConnection = -not $httpStatus -and (
        $ex -is [System.Net.WebException] -or $ex.GetType().Name -eq 'HttpRequestException' -or
        $msg -match 'No such host|could not be resolved|unable to connect|network|timed out')
      if ($noConnection) {
        $online = $false
        Say "  Couldn't reach Google Photos. Using the photos already downloaded." 'Yellow'
      } else {
        Say "  Problem with $link" 'Red'
        Say "  $msg" 'Red'
      }
    }
  }
  if (-not $online) { $status = 'offline' }

  # Albums removed from albums.txt: delete their synced folders, but only after a clean sync
  # (so a mistyped link can't wipe an album that's already downloaded).
  if ($online -and $problems -eq 0 -and (Test-Path -LiteralPath $PhotosDir)) {
    foreach ($dir in Get-ChildItem -LiteralPath $PhotosDir -Directory) {
      $marker = Join-Path $dir.FullName '.album-link'
      if (-not (Test-Path -LiteralPath $marker)) { continue }
      $l = (Get-Content -LiteralPath $marker -Raw).Trim()
      if ($links -notcontains $l) {
        Say "Removing '$($dir.Name)' (no longer in albums.txt)" 'Yellow'
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
      }
    }
  }
}

$count = Write-Library $status
Say ''
Say "$count photos and videos ready." 'White'
if ($problems -and $status -ne 'offline') {
  Say 'Some albums had problems (see above). Starting the slideshow in 15 seconds...' 'Yellow'
  Start-Sleep -Seconds 15
}
