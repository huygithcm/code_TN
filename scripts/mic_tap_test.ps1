<#
.SYNOPSIS
  Mic tap test: continuously shows a live level bar per channel so you can tap
  each physical mic and see which channel (ch1..ch8) it maps to.

  Channel map (from Src/main.c Deinterleave_Pair; display ch1..ch8 = firmware index 0..7):
    ch1/ch2 = SAI1-A (data pin PE6)   slot0/slot1
    ch3/ch4 = SAI1-B (data pin PE3)   slot0/slot1
    ch5/ch6 = SAI2-A (data pin PD11)  slot0/slot1
    ch7/ch8 = SAI2-B (data pin PA0)   slot0/slot1
  slot0 = LEFT mic (L/R select pin -> GND), slot1 = RIGHT mic (L/R -> VDD).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/mic_tap_test.ps1 -Seconds 60
#>
param(
    [string]$Port = "",
    [int]$Seconds = 45
)
$ErrorActionPreference = "Stop"

$HDR = 12; $NCH = 8; $NSAMP = 1024
$FRAME = $HDR + $NCH * $NSAMP * 4

$label = @(
    "ch1 SAI1-A PE6  slot0/L",
    "ch2 SAI1-A PE6  slot1/R",
    "ch3 SAI1-B PE3  slot0/L",
    "ch4 SAI1-B PE3  slot1/R",
    "ch5 SAI2-A PD11 slot0/L",
    "ch6 SAI2-A PD11 slot1/R",
    "ch7 SAI2-B PA0  slot0/L",
    "ch8 SAI2-B PA0  slot1/R"
)

function Find-CdcPort {
    $dev = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VID_0483&PID_5740' -and $_.Name -match '\((COM\d+)\)' } |
        Select-Object -First 1
    if ($dev -and ($dev.Name -match '\((COM\d+)\)')) { return $Matches[1] }
    return $null
}
if ([string]::IsNullOrWhiteSpace($Port)) { $Port = Find-CdcPort }
if (-not $Port) { Write-Host "[FAIL] CDC port not found"; exit 1 }

Write-Host "Tap test on $Port for $Seconds s."
Write-Host "Go nhe tung mic mot; kenh tuong ung se hien bar lon nhat.`n"

$sp = New-Object System.IO.Ports.SerialPort($Port, 115200, 'None', 8, 'One')
$sp.ReadBufferSize = 4MB; $sp.ReadTimeout = 300
$sp.Open()

function Test-MagicAt([byte[]]$d, [int]$i) {
    if (($i + 3) -ge $d.Length) { return $false }
    return ($d[$i] -eq 0x52 -and $d[$i+1] -eq 0x41 -and $d[$i+2] -eq 0x57 -and $d[$i+3] -eq 0x31)
}

$buf = New-Object System.IO.MemoryStream
$tmp = New-Object byte[] 16384
$deadline = (Get-Date).AddSeconds($Seconds)
$BARMAX = 30; $FULLSCALE = 20000.0

try {
    while ((Get-Date) -lt $deadline) {
        # read until we have at least 2 frames buffered
        while ($buf.Length -lt (2 * $FRAME + 4)) {
            try { $n = $sp.Read($tmp, 0, $tmp.Length); if ($n -gt 0) { $buf.Write($tmp, 0, $n) } }
            catch [System.TimeoutException] {}
            if ((Get-Date) -ge $deadline) { break }
        }
        $b = $buf.ToArray()
        # find anchored frame
        $pos = -1
        for ($i = 0; $i -le ($b.Length - $FRAME - 4); $i++) {
            if ((Test-MagicAt $b $i) -and (Test-MagicAt $b ($i + $FRAME))) { $pos = $i; break }
        }
        if ($pos -lt 0) { $buf = New-Object System.IO.MemoryStream; continue }

        # peak per channel for this frame (subsample x4 for speed)
        $line = ""
        for ($c = 0; $c -lt $NCH; $c++) {
            $base = $pos + $HDR + ($c * $NSAMP * 4)
            $pk = 0
            for ($s = 0; $s -lt $NSAMP; $s += 4) {
                $v = [Math]::Abs([System.BitConverter]::ToInt32($b, $base + $s * 4))
                if ($v -gt $pk) { $pk = $v }
            }
            $len = [Math]::Min($BARMAX, [int]($pk / $FULLSCALE * $BARMAX))
            $line += ("{0}  {1,6} |{2}{3}|`n" -f $label[$c], $pk, ('#' * $len), (' ' * ($BARMAX - $len)))
        }
        Clear-Host
        Write-Host ("Tap test - {0:HH:mm:ss}  (con {1}s)  Ctrl+C de dung`n" -f (Get-Date), [int]($deadline - (Get-Date)).TotalSeconds)
        Write-Host $line

        # keep only bytes after the consumed frame
        $rest = $b.Length - ($pos + $FRAME)
        $buf = New-Object System.IO.MemoryStream
        if ($rest -gt 0) { $buf.Write($b, $pos + $FRAME, $rest) }
    }
} finally {
    $sp.Close(); $sp.Dispose()
}
Write-Host "`nXong."
