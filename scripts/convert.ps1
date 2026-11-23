param(
    [Parameter(Mandatory = $true)][string]$SrcDir,
    [string]$OutRoot = '',
    [int]$CacheVer = 0,
    [string]$FFmpeg = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    $OutRoot = Join-Path (Split-Path $MyInvocation.MyCommand.Path) 'out'
}

function Resolve-Ffmpeg {
    param([string]$Hint)
    if ($Hint -and (Test-Path $Hint)) { return $Hint }

    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        'C:\ffmpeg',
        (Join-Path $env:ProgramFiles 'ffmpeg')
    )
    foreach ($r in $roots) {
        if (Test-Path $r) {
            $hit = Get-ChildItem $r -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    throw 'ffmpeg.exe not found. Install with: winget install --id Gyan.FFmpeg'
}

$FFmpeg = Resolve-Ffmpeg -Hint $FFmpeg
$FFprobe = Join-Path (Split-Path $FFmpeg) 'ffprobe.exe'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Json($obj, $path) {
    $json = $obj | ConvertTo-Json -Depth 8 -Compress
    [System.IO.File]::WriteAllText($path, $json, $Utf8NoBom)
}

# ---- locate source ----
$entryPath = Join-Path $SrcDir 'entry.json'
if (-not (Test-Path $entryPath)) { throw "entry.json not found in $SrcDir" }
$old = Get-Content $entryPath -Raw -Encoding UTF8 | ConvertFrom-Json

$flvDir = Get-ChildItem $SrcDir -Directory | Where-Object { $_.Name -like 'lua.flv*' } | Select-Object -First 1
if (-not $flvDir) { throw "lua.flv.* directory not found in $SrcDir" }
$blv = Join-Path $flvDir.FullName '0.blv'
if (-not (Test-Path $blv)) { throw "0.blv not found in $($flvDir.FullName)" }

$qid = [int]($flvDir.Name.Split('.')[-1])
$qLabel = switch ($qid) {
    120 { '4K' }
    116 { '1080P60' }
    80 { '1080P' }
    74 { '720P60' }
    64 { '720P' }
    32 { '480P' }
    16 { '360P' }
    default { "${qid}P" }
}

$avid = [int64]$old.avid
$cid = [int64]$old.page_data.cid
$title = $old.title
$durationMs = [int64]$old.total_time_milli

# ---- probe ----
$probe = (& $FFprobe -v error -print_format json -show_streams -show_format $blv) -join "`n" | ConvertFrom-Json
$vs = $probe.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
$as = $probe.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
if (-not $vs) { throw "no video stream in $blv" }

$width = [int]$vs.width
$height = [int]$vs.height
$parts = $vs.r_frame_rate -split '/'
$fps = if ([double]$parts[1] -ne 0) { [math]::Round([double]$parts[0] / [double]$parts[1], 3) } else { 0 }
$durSec = if ($probe.format.duration) { [double]$probe.format.duration } else { $durationMs / 1000.0 }
if (-not $durationMs -or $durationMs -le 0) { $durationMs = [int64]($durSec * 1000) }

$codecid = switch ($vs.codec_name) {
    'h264' { 7 }
    'hevc' { 12 }
    'av1' { 13 }
    default { 7 }
}

# ---- output dirs ----
$chapterDir = Join-Path (Join-Path $OutRoot "$avid") "c_$cid"
$qualityDir = Join-Path $chapterDir "$qid"
New-Item -ItemType Directory -Path $qualityDir -Force | Out-Null

$videoOut = Join-Path $qualityDir 'video.m4s'
$audioOut = Join-Path $qualityDir 'audio.m4s'
$movFlags = '+frag_keyframe+empty_moov+default_base_moof+global_sidx'

Write-Host '[1/4] video -> fMP4'
& $FFmpeg -y -v error -i $blv -map 0:v:0 -c:v copy -an -movflags $movFlags -f mp4 $videoOut
if ($LASTEXITCODE -ne 0) { throw 'ffmpeg video failed' }

Write-Host '[2/4] audio -> fMP4'
$audioArgs = @('-y', '-v', 'error', '-i', $blv, '-map', '0:a:0', '-c:a', 'copy', '-vn', '-movflags', $movFlags)
if ($as -and $as.codec_name -eq 'aac') { $audioArgs += @('-bsf:a', 'aac_adtstoasc') }
$audioArgs += @('-f', 'mp4', $audioOut)
& $FFmpeg @audioArgs
if ($LASTEXITCODE -ne 0) { throw 'ffmpeg audio failed' }

# ---- checksums ----
Write-Host '[3/4] md5'
$vSize = (Get-Item $videoOut).Length
$aSize = (Get-Item $audioOut).Length
$vMd5 = (Get-FileHash $videoOut -Algorithm MD5).Hash.ToLower()
$aMd5 = (Get-FileHash $audioOut -Algorithm MD5).Hash.ToLower()
$vBw = [int][math]::Round($vSize * 8 / $durSec)
$aBw = [int][math]::Round($aSize * 8 / $durSec)

# ---- index.json ----
$index = [ordered]@{
    video = @(
        [ordered]@{
            id           = $qid
            base_url     = ''
            backup_url   = @('')
            bandwidth    = $vBw
            codecid      = $codecid
            md5          = $vMd5
            size         = $vSize
            audio_id     = 30232
            no_rexcode   = $false
            frame_rate   = ('{0:0.000}' -f $fps)
            width        = $width
            height       = $height
            widevinePssh = ''
            bilidrmUri   = ''
        }
    )
    audio = @(
        [ordered]@{
            id           = 30232
            base_url     = ''
            backup_url   = @('')
            bandwidth    = $aBw
            codecid      = 0
            md5          = $aMd5
            size         = $aSize
            audio_id     = 0
            no_rexcode   = $false
            frame_rate   = ''
            width        = 0
            height       = 0
            widevinePssh = ''
            bilidrmUri   = ''
        }
    )
}
Write-Json $index (Join-Path $qualityDir 'index.json')

# ---- entry.json ----
$now = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$entry = [ordered]@{
    media_type                    = 2
    has_dash_audio                = $true
    is_completed                  = $true
    total_bytes                   = ($vSize + $aSize)
    downloaded_bytes              = ($vSize + $aSize)
    title                         = $title
    type_tag                      = "$qid"
    cover                         = $old.cover
    video_quality                 = $qid
    prefered_video_quality        = $qid
    guessed_total_bytes           = 0
    total_time_milli              = $durationMs
    danmaku_count                 = $(if ($old.danmaku_count) { [int]$old.danmaku_count } else { 0 })
    time_update_stamp             = $now
    time_create_stamp             = $(if ($old.time_create_stamp) { [int64]$old.time_create_stamp } else { $now })
    can_play_in_advance           = $true
    interrupt_transform_temp_file = $false
    quality_pithy_description     = $qLabel
    quality_superscript           = ''
    variable_resolution_ratio     = $false
    cache_version_code            = $CacheVer
    preferred_audio_quality       = 0
    audio_quality                 = 0
    avid                          = $avid
    spid                          = 0
    season_id                     = 0
    bvid                          = ''
    owner_id                      = 0
    owner_name                    = ''
    is_charge_video               = $false
    verification_code             = 0
    page_data                     = [ordered]@{
        cid               = $cid
        page              = $(if ($old.page_data.page) { [int]$old.page_data.page } else { 1 })
        from              = 'vupload'
        part              = $(if ($old.page_data.part) { $old.page_data.part } else { $title })
        link              = ('bilibili://video/' + $avid + '?cid=' + $cid)
        rich_vid          = ''
        has_alias         = $false
        tid               = $(if ($null -ne $old.page_data.tid) { [int]$old.page_data.tid } else { 0 })
        width             = $width
        height            = $height
        rotate            = 0
        download_title    = ''
        download_subtitle = ''
    }
    ep                            = $null
}
Write-Json $entry (Join-Path $chapterDir 'entry.json')

# ---- danmaku ----
$dm = Join-Path $SrcDir 'danmaku.xml'
if (Test-Path $dm) { Copy-Item $dm (Join-Path $chapterDir 'danmaku.xml') -Force }

Write-Host '[4/4] done'
Write-Host "  out : $chapterDir"
Write-Host "  vid : $vSize bytes ($vMd5)"
Write-Host "  aud : $aSize bytes ($aMd5)"
Write-Host "  meta: ${width}x${height} ${fps}fps ${durSec}s cid=$cid qid=$qid"
