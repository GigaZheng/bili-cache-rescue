param(
    [string]$DeviceName = '',
    [string]$Package = 'tv.danmaku.bili',
    [string]$LocalRoot = '',
    [int]$From = 0,
    [int]$To = 9999,
    [int]$StorageIndex = 0
)

$ErrorActionPreference = 'Stop'

$here = Split-Path $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($LocalRoot)) { $LocalRoot = Join-Path $here 'out_bili' }
if (-not (Test-Path $LocalRoot)) { throw "LocalRoot not found: $LocalRoot" }

$shell = New-Object -ComObject Shell.Application

function Nav($folder, $name) {
    $i = @($folder.Items()) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $i) { throw "not found under MTP: $name" }
    return $i.GetFolder
}

function EnsureDir($folder, $name) {
    $i = @($folder.Items()) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($i) { return $i.GetFolder }
    $null = $folder.NewFolder($name)
    Start-Sleep -Milliseconds 800
    $i = @($folder.Items()) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $i) { throw "mkdir failed: $name" }
    return $i.GetFolder
}

# ---- locate device ----
$drives = @($shell.NameSpace(17).Items())
if ([string]::IsNullOrWhiteSpace($DeviceName)) {
    $DeviceName = ($drives | Select-Object -First 1).Name
    Write-Host "DeviceName not given, using: $DeviceName"
}
$dev = $drives | Where-Object { $_.Name -eq $DeviceName } | Select-Object -First 1
if (-not $dev) { throw "device not found: $DeviceName" }

$f = $dev.GetFolder
$storage = @($f.Items()) | Where-Object { $_.IsFolder } | Select-Object -Skip $StorageIndex -First 1
if (-not $storage) { throw 'no storage folder on device' }
Write-Host ("storage: " + $storage.Name)

$f = $storage.GetFolder
$f = Nav $f 'Android'
$f = Nav $f 'data'
$f = Nav $f $Package
$dl = EnsureDir $f 'download'

# ---- push ----
$avids = @(Get-ChildItem $LocalRoot -Directory | Sort-Object Name)
Write-Host ("local avid dirs = {0}" -f $avids.Count)
if ($From -ge $avids.Count) { Write-Host 'range out of bounds'; exit 1 }

$existing = @{}
foreach ($i in @($dl.Items())) { $existing[$i.Name] = $true }

$end = [Math]::Min($To, $avids.Count - 1)
for ($i = $From; $i -le $end; $i++) {
    $av = $avids[$i]
    $name = $av.Name
    if ($existing.ContainsKey($name)) { Write-Host ("[{0}/{1}] SKIP {2} (exists)" -f ($i + 1), $avids.Count, $name); continue }

    $srcSize = (Get-ChildItem $av.FullName -Recurse -File | Measure-Object Length -Sum).Sum
    $mb = [math]::Round($srcSize / 1MB, 1)

    $expect = @{}
    foreach ($c in (Get-ChildItem $av.FullName -Directory)) {
        $q = @(Get-ChildItem $c.FullName -Directory)[0]
        $expect[$c.Name] = @{ Q = $q.Name; V = (Get-Item (Join-Path $q.FullName 'video.m4s')).Length }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $item = $shell.NameSpace($av.Parent.FullName).ParseName($name)
    $dl.CopyHere($item, 20)
    Start-Sleep -Seconds ([math]::Max(1, [math]::Ceiling($srcSize / 25MB)))

    $okFlag = $false
    $t = 0
    while ($t -lt 120) {
        $cur = @($dl.Items()) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($cur) {
            $cFolders = @($cur.GetFolder.Items())
            $allGood = $true
            foreach ($k in $expect.Keys) {
                $cf = $cFolders | Where-Object { $_.Name -eq $k } | Select-Object -First 1
                if (-not $cf) { $allGood = $false; break }
                $qf = @($cf.GetFolder.Items()) | Where-Object { $_.Name -eq $expect[$k].Q } | Select-Object -First 1
                if (-not $qf) { $allGood = $false; break }
                $vf = @($qf.GetFolder.Items()) | Where-Object { $_.Name -eq 'video.m4s' } | Select-Object -First 1
                if (-not $vf) { $allGood = $false; break }
                if ($vf.ExtendedProperty('System.Size') -ne $expect[$k].V) { $allGood = $false; break }
            }
            if ($allGood) { $okFlag = $true; break }
        }
        Start-Sleep -Seconds 1
        $t++
    }
    $sw.Stop()

    if ($okFlag) { Write-Host ("[{0}/{1}] OK   {2} ({3} MB, {4}s)" -f ($i + 1), $avids.Count, $name, $mb, [math]::Round($sw.Elapsed.TotalSeconds, 1)) }
    else { Write-Host ("[{0}/{1}] WARN {2} ({3} MB) verify timeout" -f ($i + 1), $avids.Count, $name, $mb) }
}
Write-Host 'done'
