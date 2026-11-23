param(
    [string]$Root = '',
    [int]$From = 0,
    [int]$To = 9999,
    [string]$OutRoot = '',
    [int]$CacheVer = 0,
    [string]$FFmpeg = ''
)

$ErrorActionPreference = 'Stop'

$here = Split-Path $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutRoot)) { $OutRoot = Join-Path $here 'out_bili' }
New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null

# A "chapter" is any directory holding entry.json next to a lua.flv.* subdirectory.
$srcs = @()
foreach ($av in (Get-ChildItem $Root -Directory -ErrorAction SilentlyContinue)) {
    foreach ($page in (Get-ChildItem $av.FullName -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path (Join-Path $page.FullName 'entry.json')) {
            $hasFlv = @(Get-ChildItem $page.FullName -Directory | Where-Object { $_.Name -like 'lua.flv*' }).Count -gt 0
            if ($hasFlv) { $srcs += $page.FullName }
        }
    }
}
$srcs = @($srcs | Sort-Object)
Write-Host ("source chapters = {0}" -f $srcs.Count)
if ($srcs.Count -eq 0) { exit 1 }
if ($From -ge $srcs.Count) { Write-Host 'range out of bounds'; exit 1 }

$end = [Math]::Min($To, $srcs.Count - 1)
$ok = 0
$fail = 0
for ($i = $From; $i -le $end; $i++) {
    $s = $srcs[$i]
    $tag = Split-Path (Split-Path $s -Parent) -Leaf
    try {
        & (Join-Path $here 'convert.ps1') -SrcDir $s -OutRoot $OutRoot -CacheVer $CacheVer -FFmpeg $FFmpeg 6>$null
        Write-Host ("[{0}/{1}] OK   {2}" -f ($i + 1), $srcs.Count, $tag)
        $ok++
    }
    catch {
        Write-Host ("[{0}/{1}] FAIL {2} :: {3}" -f ($i + 1), $srcs.Count, $s, $_.Exception.Message)
        $fail++
    }
}
Write-Host ("done. ok={0} fail={1}" -f $ok, $fail)
