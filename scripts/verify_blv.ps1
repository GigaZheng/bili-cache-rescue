param(
    [Parameter(Mandatory = $true)][string]$Root
)

$ErrorActionPreference = 'Stop'

function Test-Blv {
    param([string]$Path)

    $result = [ordered]@{
        Path    = $Path
        Sig     = ''
        Size    = 0
        SumSize = $null
        Video   = 0
        Audio   = 0
        Script  = 0
        MaxTs   = 0
        Left    = 0
        Error   = ''
    }

    $result.Size = (Get-Item $Path).Length

    $sumPath = "$Path.4m.sum"
    if (Test-Path $sumPath) {
        try { $result.SumSize = (Get-Content $sumPath -Raw | ConvertFrom-Json).length } catch { }
    }

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $sigBytes = $br.ReadBytes(3)
        $result.Sig = [System.Text.Encoding]::ASCII.GetString($sigBytes)
        if ($result.Sig -ne 'FLV') {
            $result.Error = 'bad signature'
            return [PSCustomObject]$result
        }

        # header(9) + PreviousTagSize0(4)
        if ($fs.Length -lt 13) { $result.Error = 'file too short'; return [PSCustomObject]$result }
        $fs.Position = 13

        while ($fs.Position -lt ($fs.Length - 11)) {
            $t = $br.ReadByte()

            $x1 = $br.ReadByte(); $x2 = $br.ReadByte(); $x3 = $br.ReadByte()
            $size = [int]$x1 * 65536 + [int]$x2 * 256 + [int]$x3

            $y1 = $br.ReadByte(); $y2 = $br.ReadByte(); $y3 = $br.ReadByte(); $y4 = $br.ReadByte()
            $ts = [int]$y4 * 16777216 + [int]$y1 * 65536 + [int]$y2 * 256 + [int]$y3

            $null = $br.ReadBytes(3)   # StreamID (UI24)

            if ($ts -gt $result.MaxTs) { $result.MaxTs = $ts }

            $fs.Position = $fs.Position + $size
            $null = $br.ReadBytes(4)   # PreviousTagSize

            switch ($t) {
                8 { $result.Audio++ }
                9 { $result.Video++ }
                18 { $result.Script++ }
                default { }
            }
        }

        $result.Left = $fs.Length - $fs.Position
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        $fs.Close()
    }

    return [PSCustomObject]$result
}

$files = @(Get-ChildItem -Path $Root -Recurse -Filter '*.blv' -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { Write-Host "no .blv files under $Root"; exit 1 }

Write-Host ("checked {0} files" -f $files.Count)
$rows = @()
foreach ($f in $files) { $rows += Test-Blv -Path $f.FullName }

$bad = @($rows | Where-Object { $_.Error -ne '' -or $_.Left -ne 0 -or $_.Video -eq 0 -or ($null -ne $_.SumSize -and $_.SumSize -ne $_.Size) })

Write-Host ("problems: {0}" -f $bad.Count)
if ($bad.Count -gt 0) {
    $bad | Select-Object Path, Size, SumSize, Video, Audio, MaxTs, Left, Error | Format-Table -AutoSize -Wrap
}

Write-Host ''
Write-Host 'summary (first 10)'
$rows | Select-Object -First 10 @{n = 'MB'; e = { [math]::Round($_.Size / 1MB, 1) } }, Video, Audio, @{n = 'Sec'; e = { [math]::Round($_.MaxTs / 1000, 1) } }, Left, Error | Format-Table -AutoSize
