<#
.SYNOPSIS
  Per-channel mic diagnostics: capture RAW1 frames from the OTG CDC port and
  report DC offset, RMS, peak, and zero-lag cross-correlation between all
  channel pairs to spot dead / stuck / duplicated / noisy mics.
#>
param(
    [string]$Port = "",
    [int]$Frames = 8,
    [int]$TimeoutSec = 25
)
$ErrorActionPreference = "Stop"

$HDR = 12; $NCH = 8; $NSAMP = 1024
$FRAME = $HDR + $NCH * $NSAMP * 4

function Find-CdcPort {
    $dev = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VID_0483&PID_5740' -and $_.Name -match '\((COM\d+)\)' } |
        Select-Object -First 1
    if ($dev -and ($dev.Name -match '\((COM\d+)\)')) { return $Matches[1] }
    return $null
}
if ([string]::IsNullOrWhiteSpace($Port)) { $Port = Find-CdcPort }
if (-not $Port) { Write-Host "[FAIL] CDC port not found"; exit 1 }
Write-Host "Port: $Port  frames: $Frames"

$sp = New-Object System.IO.Ports.SerialPort($Port, 115200, 'None', 8, 'One')
$sp.ReadBufferSize = 4MB; $sp.ReadTimeout = 800
$sp.Open()
$ms = New-Object System.IO.MemoryStream
$tmp = New-Object byte[] 16384
$need = ($Frames + 2) * $FRAME + 65536
$deadline = (Get-Date).AddSeconds($TimeoutSec)
try {
    while (((Get-Date) -lt $deadline) -and ($ms.Length -lt $need)) {
        try { $n = $sp.Read($tmp, 0, $tmp.Length); if ($n -gt 0) { $ms.Write($tmp, 0, $n) } }
        catch [System.TimeoutException] {}
    }
} finally { $sp.Close(); $sp.Dispose() }
$b = $ms.ToArray()
Write-Host ("Captured {0} bytes" -f $b.Length)

function Test-MagicAt([byte[]]$d, [int]$i) {
    if (($i + 3) -ge $d.Length) { return $false }
    return ($d[$i] -eq 0x52 -and $d[$i+1] -eq 0x41 -and $d[$i+2] -eq 0x57 -and $d[$i+3] -eq 0x31)
}
$pos = -1
for ($i = 0; $i -le ($b.Length - $FRAME - 4); $i++) {
    if ((Test-MagicAt $b $i) -and (Test-MagicAt $b ($i + $FRAME))) { $pos = $i; break }
}
if ($pos -lt 0) { Write-Host "[FAIL] no frame sync"; exit 1 }

# accumulate stats over all frames
$N = 0
$sum = New-Object double[] $NCH
$sumsq = New-Object double[] $NCH
$peak = New-Object int[] $NCH
$data = @{}            # per-channel concatenated samples (for correlation)
for ($c = 0; $c -lt $NCH; $c++) { $data[$c] = New-Object System.Collections.Generic.List[double] }

$frameCount = 0
while (($frameCount -lt $Frames) -and (($pos + $FRAME) -le $b.Length)) {
    if (-not (Test-MagicAt $b $pos)) { break }
    for ($c = 0; $c -lt $NCH; $c++) {
        $base = $pos + $HDR + ($c * $NSAMP * 4)
        for ($s = 0; $s -lt $NSAMP; $s++) {
            $v = [System.BitConverter]::ToInt32($b, $base + $s * 4)
            $sum[$c] += $v; $sumsq[$c] += [double]$v * $v
            $a = [Math]::Abs($v); if ($a -gt $peak[$c]) { $peak[$c] = $a }
            $data[$c].Add($v)
        }
    }
    $N += $NSAMP; $frameCount++; $pos += $FRAME
}
Write-Host "Analyzed $frameCount frames ($N samples/ch)`n"

Write-Host ("{0,-4} {1,12} {2,12} {3,12}" -f "ch", "mean(DC)", "RMS(AC)", "peak")
$mean = New-Object double[] $NCH
$rmsac = New-Object double[] $NCH
for ($c = 0; $c -lt $NCH; $c++) {
    $mean[$c] = $sum[$c] / $N
    $var = $sumsq[$c] / $N - $mean[$c] * $mean[$c]
    $rmsac[$c] = [Math]::Sqrt([Math]::Max($var, 0))
    Write-Host ("ch{0,-2} {1,12:N1} {2,12:N1} {3,12}" -f $c, $mean[$c], $rmsac[$c], $peak[$c])
}

Write-Host "`nZero-lag correlation matrix (AC-coupled, normalized):"
$hdr = "     " + (($(0..($NCH-1)) | ForEach-Object { "ch$_".PadLeft(7) }) -join "")
Write-Host $hdr
for ($i = 0; $i -lt $NCH; $i++) {
    $row = "ch$i".PadRight(5)
    for ($j = 0; $j -lt $NCH; $j++) {
        $acc = 0.0
        for ($k = 0; $k -lt $N; $k++) {
            $acc += ($data[$i][$k] - $mean[$i]) * ($data[$j][$k] - $mean[$j])
        }
        $den = $rmsac[$i] * $rmsac[$j] * $N
        $r = if ($den -gt 0) { $acc / $den } else { 0 }
        $row += ("{0,7:N2}" -f $r)
    }
    Write-Host $row
}
