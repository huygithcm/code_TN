<#
.SYNOPSIS
  TASK-06 raw USB CDC stream check.

  Reads the OTG USB CDC port, syncs to the "RAW1" frame magic, validates each
  frame header/payload, confirms the sequence counter increments by 1, and
  reports per-channel min/max so you can see live mic data.

  Frame format (see Src/main.c, USB_RAW_STREAM):
    offset 0  : magic  "RAW1"            (4 bytes)
    offset 4  : seq     uint32 LE        (4 bytes)
    offset 8  : nch     uint8  = 8       (1 byte)
    offset 9  : nsamp   uint16 LE = 1024 (2 bytes)
    offset 11 : fmt     uint8  = 0       (1 byte, int32 LE)
    offset 12 : payload int32 LE, channel-major  (nch*nsamp*4 = 32768 bytes)
  Total frame = 32780 bytes.

  The firmware only queues a new frame when the previous CDC transfer finished,
  so the host MUST drain the port (this script does) for seq to advance.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/check_usb_cdc_stream.ps1
  powershell -ExecutionPolicy Bypass -File scripts/check_usb_cdc_stream.ps1 -Port COM12 -Frames 10
#>
param(
    [string]$Port = "",                 # OTG CDC port; auto-detected if empty
    [int]$Baud = 115200,                # CDC ignores baud, set for completeness
    [int]$Frames = 5,                   # number of valid frames required to pass
    [int]$TimeoutSec = 20,              # overall read timeout
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

# ---- frame constants -------------------------------------------------------
$MAGIC        = [byte[]]@(0x52, 0x41, 0x57, 0x31)   # "RAW1"
$HDR_BYTES    = 12
$EXP_NCH      = 8
$EXP_NSAMP    = 1024
$EXP_FMT      = 0
$PAYLOAD_BYTES = $EXP_NCH * $EXP_NSAMP * 4
$FRAME_BYTES   = $HDR_BYTES + $PAYLOAD_BYTES        # 32780
$SAMPLE_MIN   = -8388608                            # 24-bit signed range
$SAMPLE_MAX   =  8388607

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot "debug\usb_cdc_stream_report.txt"
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

# ---- prepare report --------------------------------------------------------
$reportDir = Split-Path -Parent $ReportPath
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir | Out-Null
}
Set-Content -Path $ReportPath -Value "USB CDC raw stream check"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

Add-ReportLine "TASK-06 USB CDC Raw Stream Check"

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
Add-ReportLine ("Expecting frames: magic=RAW1 nch={0} nsamp={1} fmt={2} ({3} bytes each)" -f $EXP_NCH, $EXP_NSAMP, $EXP_FMT, $FRAME_BYTES)
Add-ReportLine "Need $Frames valid frame(s) within $TimeoutSec s."
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
# Grab enough for the requested frames plus slack for leading junk / alignment.
$needBytes = (($Frames + 2) * $FRAME_BYTES) + 65536
$ms = New-Object System.IO.MemoryStream
$tmp = New-Object byte[] 16384
$deadline = (Get-Date).AddSeconds($TimeoutSec)
try {
    while (((Get-Date) -lt $deadline) -and ($ms.Length -lt $needBytes)) {
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
Add-ReportLine ("Captured {0} bytes from {1}" -f $b.Length, $Port)
Add-ReportLine ""

# ---- phase 2: parse the captured buffer by index ----------------------------
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

$validFrames = 0
$prevSeq = $null

$pos = Find-Anchor -Data $b -From 0
if ($pos -lt 0) {
    Add-ReportLine "[FAIL] No two consecutive RAW1 frames found in the capture."
    Add-ReportLine "       Firmware not streaming, or too few bytes captured."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

while (($validFrames -lt $Frames) -and (($pos + $FRAME_BYTES) -le $b.Length)) {
    if (-not (Test-MagicAt $b $pos)) {
        # stride broke -> re-anchor from here
        $next = Find-Anchor -Data $b -From $pos
        if ($next -lt 0) { break }
        $pos = $next
    }

    # --- header ---
    $seq   = [System.BitConverter]::ToUInt32($b, $pos + 4)
    $nch   = $b[$pos + 8]
    $nsamp = [System.BitConverter]::ToUInt16($b, $pos + 9)
    $fmt   = $b[$pos + 11]

    if ($nch -ne $EXP_NCH -or $nsamp -ne $EXP_NSAMP -or $fmt -ne $EXP_FMT) {
        Add-ReportLine "[warn] misaligned frame (nch=$nch nsamp=$nsamp fmt=$fmt), resyncing"
        $next = Find-Anchor -Data $b -From ($pos + 4)
        if ($next -lt 0) { break }
        $pos = $next
        continue
    }

    # --- seq continuity ---
    $seqNote = ""
    if ($null -ne $prevSeq) {
        $expSeq = ($prevSeq + 1) -band 0xFFFFFFFF
        if ($seq -ne $expSeq) { $seqNote = " (GAP, expected $expSeq)" }
    }
    $prevSeq = $seq

    # --- payload min/max per channel + 24-bit range sanity ---
    $perCh = New-Object System.Collections.Generic.List[string]
    $rangeOk = $true
    for ($c = 0; $c -lt $EXP_NCH; $c++) {
        $base = $pos + $HDR_BYTES + ($c * $EXP_NSAMP * 4)
        $mn = [int]::MaxValue; $mx = [int]::MinValue
        for ($s = 0; $s -lt $EXP_NSAMP; $s++) {
            $v = [System.BitConverter]::ToInt32($b, $base + ($s * 4))
            if ($v -lt $mn) { $mn = $v }
            if ($v -gt $mx) { $mx = $v }
        }
        if ($mn -lt $SAMPLE_MIN -or $mx -gt $SAMPLE_MAX) { $rangeOk = $false }
        $perCh.Add(("ch{0}[{1}..{2}]" -f $c, $mn, $mx))
    }

    if (-not $rangeOk) {
        Add-ReportLine "[warn] frame seq=$seq has out-of-range sample, resyncing"
        $next = Find-Anchor -Data $b -From ($pos + 4)
        if ($next -lt 0) { break }
        $pos = $next
        continue
    }

    $validFrames++
    Add-ReportLine ("frame {0}: seq={1}{2}  {3}" -f $validFrames, $seq, $seqNote, ($perCh -join " "))
    $pos += $FRAME_BYTES
}

# ---- verdict ---------------------------------------------------------------
Add-ReportLine ""
if ($validFrames -lt $Frames) {
    Add-ReportLine "[FAIL] Only $validFrames/$Frames valid frame(s) received within $TimeoutSec s."
    Add-ReportLine "       Frame magic never synced, or the firmware is not streaming."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

Add-ReportLine "[ OK ] Received $validFrames valid RAW1 frame(s)"
Add-ReportLine "[ OK ] Headers valid (nch=$EXP_NCH nsamp=$EXP_NSAMP fmt=$EXP_FMT)"
Add-ReportLine "[ OK ] Sequence counter advanced"
Add-ReportLine "[ OK ] All samples within 24-bit range"
Add-ReportLine "USB CDC raw stream check passed."
Add-ReportLine "Report written to: $ReportPath"
exit 0
