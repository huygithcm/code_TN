<#
.SYNOPSIS
  TASK-10 USB CDC transmit continuity check (PowerShell replacement for pc_verify.py).

  Drains the OTG USB CDC port for a sustained window (default 60 s), syncs to the
  "RAW1" frame magic, and verifies the host-visible sequence counter increments by
  exactly 1 with NO gaps for the whole run. A gap means a frame was lost in
  TRANSPORT (the firmware only advances seq on a successful CDC send, so device-side
  back-pressure drops do not create gaps - those are reported separately by the
  board's [USB] monitor line as drops=).

  "Done when" (TASK-10): frames received with no sequence gap for 60 seconds.

  Frame format (see Src/main.c, USB_RAW_STREAM):
    offset 0  : magic  "RAW1"            (4 bytes)
    offset 4  : seq     uint32 LE        (4 bytes)
    offset 8  : nch     uint8  = 8       (1 byte)
    offset 9  : nsamp   uint16 LE = 1024 (2 bytes)
    offset 11 : fmt     uint8  = 0       (1 byte, int32 LE)
    offset 12 : payload int32 LE, channel-major  (nch*nsamp*4 = 32768 bytes)
  Total frame = 32780 bytes.

  Do NOT flash before running - flashing resets/re-enumerates USB. The firmware
  must already be running and streaming.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/check_task10_usb_cdc.ps1
  powershell -ExecutionPolicy Bypass -File scripts/check_task10_usb_cdc.ps1 -DurationSec 60 -Port COM12
#>
param(
    [string]$Port = "",                 # OTG CDC port; auto-detected if empty
    [int]$Baud = 115200,                # CDC ignores baud, set for completeness
    [int]$DurationSec = 60,             # how long to stream/verify (TASK-10 = 60 s)
    [int]$MinFrames = 0,                # min valid frames to pass; 0 => DurationSec*5
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

# ---- frame constants -------------------------------------------------------
$HDR_BYTES     = 12
$EXP_NCH       = 8
$EXP_NSAMP     = 1024
$EXP_FMT       = 0
$PAYLOAD_BYTES = $EXP_NCH * $EXP_NSAMP * 4
$FRAME_BYTES   = $HDR_BYTES + $PAYLOAD_BYTES        # 32780
$SAMPLE_MIN    = -8388608                           # 24-bit signed range
$SAMPLE_MAX    =  8388607

if ($MinFrames -le 0) { $MinFrames = $DurationSec * 5 }

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot "debug\task10_usb_cdc_report.txt"
}

function Add-ReportLine {
    param([string]$Line)
    Write-Host $Line
    Add-Content -Path $ReportPath -Value $Line
}

# ---- locate the OTG CDC port (STM32 CDC = VID_0483 PID_5740) ----------------
function Find-CdcPort {
    $dev = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -match 'VID_0483&PID_5740' -and $_.Name -match '\((COM\d+)\)' } |
        Select-Object -First 1
    if ($dev -and ($dev.Name -match '\((COM\d+)\)')) {
        return $Matches[1]
    }
    return $null
}

function Test-MagicAt {
    param([byte[]]$Data, [int]$i)
    if (($i + 3) -ge $Data.Length) { return $false }
    return ($Data[$i] -eq 0x52 -and $Data[$i+1] -eq 0x41 -and $Data[$i+2] -eq 0x57 -and $Data[$i+3] -eq 0x31)
}

# A true frame start has a SECOND magic exactly one frame later, so a stray
# "RAW1" inside the int32 payload cannot be mistaken for a frame boundary.
function Find-Anchor {
    param([byte[]]$Data, [int]$From)
    $limit = $Data.Length - $FRAME_BYTES - 4
    for ($i = $From; $i -le $limit; $i++) {
        if ((Test-MagicAt $Data $i) -and (Test-MagicAt $Data ($i + $FRAME_BYTES))) {
            return $i
        }
    }
    return -1
}

# ---- prepare report --------------------------------------------------------
$reportDir = Split-Path -Parent $ReportPath
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir | Out-Null
}
Set-Content -Path $ReportPath -Value "TASK-10 USB CDC transmit continuity check"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

Add-ReportLine "TASK-10 USB CDC Transmit Continuity Check"

if ([string]::IsNullOrWhiteSpace($Port)) {
    $Port = Find-CdcPort
    if (-not $Port) {
        Add-ReportLine "[FAIL] OTG USB CDC port not found (looking for VID_0483&PID_5740)."
        Add-ReportLine "       Is the board powered and the firmware running? Pass -Port COMx to override."
        exit 1
    }
    Add-ReportLine "Auto-detected OTG CDC port: $Port"
} else {
    Add-ReportLine "Using OTG CDC port: $Port"
}
Add-ReportLine ("Streaming {0} s, need >= {1} gap-free frame(s) (frame = {2} bytes)." -f $DurationSec, $MinFrames, $FRAME_BYTES)
Add-ReportLine ""

# ---- open the port ---------------------------------------------------------
# Frames are 32 KB each; the default 4 KB driver read buffer overflows and drops
# bytes (causing frame misalignment) unless we both enlarge it AND drain fast.
$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, 'None', 8, 'One')
$sp.ReadBufferSize = 4 * 1024 * 1024
$sp.ReadTimeout = 800
try {
    $sp.Open()
} catch {
    Add-ReportLine "[FAIL] Could not open ${Port}: $($_.Exception.Message)"
    exit 1
}

# ---- phase 1: capture raw bytes fast (no per-byte work => no overflow) -------
$ms = New-Object System.IO.MemoryStream
$tmp = New-Object byte[] 65536
$deadline = (Get-Date).AddSeconds($DurationSec)
try {
    while ((Get-Date) -lt $deadline) {
        try {
            $n = $sp.Read($tmp, 0, $tmp.Length)
            if ($n -gt 0) { $ms.Write($tmp, 0, $n) }
        } catch [System.TimeoutException] {
            # no data this slice; keep waiting until deadline
        }
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
$b = $ms.ToArray()
$elapsed = $DurationSec
Add-ReportLine ("Captured {0} bytes (~{1:N1} MB) from {2} in ~{3} s" -f $b.Length, ($b.Length / 1MB), $Port, $elapsed)

# ---- phase 2: walk frames, checking header + seq continuity (fast, hdr-only) -
$validFrames = 0
$gaps        = 0
$rangeChecks = 0
$rangeBad    = 0
$firstSeq    = $null
$lastSeq     = $null
$prevSeq     = $null

$pos = Find-Anchor -Data $b -From 0
if ($pos -lt 0) {
    Add-ReportLine "[FAIL] No two consecutive RAW1 frames found in the capture."
    Add-ReportLine "       Firmware not streaming, or too few bytes captured."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

while (($pos + $FRAME_BYTES) -le $b.Length) {
    if (-not (Test-MagicAt $b $pos)) {
        $next = Find-Anchor -Data $b -From $pos
        if ($next -lt 0) { break }
        $pos = $next
    }

    $seq   = [System.BitConverter]::ToUInt32($b, $pos + 4)
    $nch   = $b[$pos + 8]
    $nsamp = [System.BitConverter]::ToUInt16($b, $pos + 9)
    $fmt   = $b[$pos + 11]

    if ($nch -ne $EXP_NCH -or $nsamp -ne $EXP_NSAMP -or $fmt -ne $EXP_FMT) {
        $next = Find-Anchor -Data $b -From ($pos + 4)
        if ($next -lt 0) { break }
        $pos = $next
        continue
    }

    # seq continuity (host-visible seq must advance by exactly 1)
    if ($null -ne $prevSeq) {
        $expSeq = ($prevSeq + 1) -band 0xFFFFFFFF
        if ($seq -ne $expSeq) {
            $gaps++
            if ($gaps -le 20) {
                Add-ReportLine ("[GAP] expected seq={0}, got seq={1} (missed {2})" -f $expSeq, $seq, (($seq - $expSeq) -band 0xFFFFFFFF))
            }
        }
    } else {
        $firstSeq = $seq
    }
    $prevSeq = $seq
    $lastSeq = $seq
    $validFrames++

    # spot-check 24-bit range on every 100th frame (full scan is too slow for ~1000 frames)
    if (($validFrames % 100) -eq 1) {
        $rangeChecks++
        $rangeOk = $true
        for ($c = 0; $c -lt $EXP_NCH -and $rangeOk; $c++) {
            $base = $pos + $HDR_BYTES + ($c * $EXP_NSAMP * 4)
            for ($s = 0; $s -lt $EXP_NSAMP; $s++) {
                $v = [System.BitConverter]::ToInt32($b, $base + ($s * 4))
                if ($v -lt $SAMPLE_MIN -or $v -gt $SAMPLE_MAX) { $rangeOk = $false; break }
            }
        }
        if (-not $rangeOk) { $rangeBad++ }
    }

    $pos += $FRAME_BYTES
}

# ---- verdict ---------------------------------------------------------------
$rate = if ($elapsed -gt 0) { [math]::Round($validFrames / $elapsed, 1) } else { 0 }
Add-ReportLine ""
Add-ReportLine ("Frames: {0} valid, seq {1}..{2}, ~{3} fps, gaps={4}, range-checked={5} bad={6}" -f `
    $validFrames, $firstSeq, $lastSeq, $rate, $gaps, $rangeChecks, $rangeBad)
Add-ReportLine ""

$ok = $true

if ($validFrames -lt $MinFrames) {
    $ok = $false
    Add-ReportLine "[FAIL] Only $validFrames valid frame(s); need >= $MinFrames in $DurationSec s."
} else {
    Add-ReportLine "[ OK ] Received $validFrames valid RAW1 frames (~$rate fps)"
}

if ($gaps -eq 0) {
    Add-ReportLine "[ OK ] No sequence gaps over $DurationSec s (continuous transport)"
} else {
    $ok = $false
    Add-ReportLine "[FAIL] $gaps sequence gap(s) - frames lost in transport"
}

if ($rangeBad -eq 0) {
    Add-ReportLine "[ OK ] Sampled frames within 24-bit range ($rangeChecks checked)"
} else {
    $ok = $false
    Add-ReportLine "[FAIL] $rangeBad sampled frame(s) out of 24-bit range"
}

Add-ReportLine ""
if (-not $ok) {
    Add-ReportLine "TASK-10 USB CDC continuity check FAILED."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

Add-ReportLine "TASK-10 USB CDC continuity check passed."
Add-ReportLine "Report written to: $ReportPath"
exit 0
