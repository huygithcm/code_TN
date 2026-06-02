param(
    [string]$Port = "COM3",
    [int]$Baud = 115200,
    [int]$ReadSeconds = 60,
    [switch]$NoFlash,
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$Configuration = "Debug",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$buildDir = Join-Path $ProjectRoot "STM32CubeIDE\$Configuration"
$elfPath = Join-Path $buildDir "code_ver2_Fs16khz.elf"
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot "debug\task12_monitor_report.txt"
}

# allocated stack sizes (words) from the osThreadAttr_t definitions in main.c
$stackAlloc = @{ def = 512; fft = 2048; usb = 512; doa = 512; mon = 512 }

function Find-Tool {
    param([string]$Name, [string[]]$SearchRoots)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($root in $SearchRoots) {
        if (Test-Path $root) {
            $tool = Get-ChildItem -Path $root -Recurse -Filter $Name -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($tool) { return $tool.FullName }
        }
    }
    return $null
}

function Add-ReportLine {
    param([string]$Line)
    Write-Host $Line
    Add-Content -Path $ReportPath -Value $Line
}

if (-not (Test-Path $elfPath)) {
    throw "ELF not found: $elfPath  (build the project first)"
}

$reportDir = Split-Path -Parent $ReportPath
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir | Out-Null
}
Set-Content -Path $ReportPath -Value "TASK-12 Monitor and Watchdog report"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

$programmer = Find-Tool -Name "STM32_Programmer_CLI.exe" -SearchRoots @("C:\ST", "C:\Program Files\STMicroelectronics")
if (-not $programmer) {
    throw "STM32_Programmer_CLI.exe not found. Install STM32CubeProgrammer or STM32CubeIDE."
}

Add-ReportLine "TASK-12 Monitor + Watchdog Verify"
Add-ReportLine "ELF : $elfPath"
Add-ReportLine "Port: $Port @ $Baud, window ${ReadSeconds}s"
Add-ReportLine ""

$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
try { $sp.Open() } catch {
    throw "Could not open ${Port}: $($_.Exception.Message). Close any serial terminal using it."
}

try {
    $sp.DiscardInBuffer()
    if (-not $NoFlash) {
        Add-ReportLine "Flashing firmware and resetting..."
        $flashOut = & $programmer -c port=SWD mode=UR -d "$elfPath" -rst 2>&1
        foreach ($line in $flashOut) { Add-Content -Path $ReportPath -Value $line }
    } else {
        Add-ReportLine "Resetting target (no flash)..."
        & $programmer -c port=SWD mode=UR -rst 2>&1 | Out-Null
    }

    Add-ReportLine ""
    Add-ReportLine "Reading $Port for $ReadSeconds s (watchdog must keep the board alive)..."
    $deadline = (Get-Date).AddSeconds($ReadSeconds)
    $buf = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $buf += $sp.ReadExisting()
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
}

$lines = $buf -split "`r?`n"

Add-ReportLine ""
Add-ReportLine "----- VCP output (excerpt) -----"
foreach ($l in $lines) {
    if ($l -match "Monitor/Watchdog|last reset:|\[MON\]|\[STK\]|self-test OK") {
        Add-ReportLine $l.Trim()
    }
}
Add-ReportLine "--------------------------------"
Add-ReportLine ""

$ok = $true

# 1) Reset cause printed, and it must NOT be an IWDG reset (no spurious watchdog fire)
$rstMatches = [regex]::Matches($buf, "last reset:([^\r\n]*)")
if ($rstMatches.Count -ge 1) {
    $cause = $rstMatches[0].Groups[1].Value.Trim()
    Add-ReportLine "[ OK ] Reset-cause reported: '$cause'"
    if ($cause -match "IWDG") {
        $ok = $false
        Add-ReportLine "[FAIL] Board came up from an IWDG reset (watchdog fired unexpectedly)"
    }
    if ($rstMatches.Count -gt 1) {
        $ok = $false
        Add-ReportLine "[FAIL] Boot banner seen $($rstMatches.Count)x -> board reset mid-run (watchdog starved)"
    }
} else {
    $ok = $false
    Add-ReportLine "[FAIL] No reset-cause line seen (TASK-12 banner missing)"
}

# 2) [MON] lines: blocks must advance, overruns=0, saiErr=0
$mon = [regex]::Matches($buf, "\[MON\]\s+blocks=(\d+)\s+overruns=(\d+)\s+fft=\d+us\s+gcc=\d+us\s+heapFree=\d+\s+saiErr=(\d+)")
if ($mon.Count -ge 2) {
    $first = $mon[0]; $last = $mon[$mon.Count - 1]
    $b0 = [int]$first.Groups[1].Value; $bN = [int]$last.Groups[1].Value
    $maxOver = 0; $maxSai = 0
    foreach ($m in $mon) {
        $o = [int]$m.Groups[2].Value; if ($o -gt $maxOver) { $maxOver = $o }
        $s = [int]$m.Groups[3].Value; if ($s -gt $maxSai) { $maxSai = $s }
    }
    Add-ReportLine "[ OK ] Monitor lines: $($mon.Count), blocks $b0 -> $bN"
    if ($bN -le $b0) { $ok = $false; Add-ReportLine "[FAIL] blocks did not advance (pipeline stalled)" }
    else { Add-ReportLine "[ OK ] Pipeline advancing (blocks climbed by $($bN - $b0))" }
    if ($maxOver -ne 0) { $ok = $false; Add-ReportLine "[FAIL] overruns reached $maxOver (expected 0)" }
    else { Add-ReportLine "[ OK ] overruns=0 across the whole window" }
    if ($maxSai -ne 0) { $ok = $false; Add-ReportLine "[FAIL] SAI errors reached $maxSai (expected 0)" }
    else { Add-ReportLine "[ OK ] saiErr=0 across the whole window (SAI1+SAI2)" }
} else {
    $ok = $false
    Add-ReportLine "[FAIL] Too few [MON] lines ($($mon.Count)); board may be resetting"
}

# 3) [STK] stack high-water: each task must keep > 10% of its allocated stack free
$stk = [regex]::Match($buf, "\[STK\]\s+def=(\d+)\s+fft=(\d+)\s+usb=(\d+)\s+doa=(\d+)\s+mon=(\d+)")
if ($stk.Success) {
    $hw = @{ def = [int]$stk.Groups[1].Value; fft = [int]$stk.Groups[2].Value
             usb = [int]$stk.Groups[3].Value; doa = [int]$stk.Groups[4].Value
             mon = [int]$stk.Groups[5].Value }
    Add-ReportLine ("[ OK ] Stack high-water (free words): def={0} fft={1} usb={2} doa={3} mon={4}" -f `
        $hw.def, $hw.fft, $hw.usb, $hw.doa, $hw.mon)
    foreach ($k in @("def","fft","usb","doa","mon")) {
        $thr = [math]::Ceiling($stackAlloc[$k] * 0.10)
        if ($hw[$k] -lt $thr) {
            $ok = $false
            Add-ReportLine "[FAIL] $k stack free $($hw[$k]) < 10% of $($stackAlloc[$k]) (=$thr) words"
        }
    }
    if ($ok) { Add-ReportLine "[ OK ] All tasks keep > 10% stack headroom" }
} else {
    $ok = $false
    Add-ReportLine "[FAIL] No [STK] stack high-water line seen"
}

Add-ReportLine ""
Add-ReportLine "Note: the watchdog is fed only while g_blocks advances, so a stalled DSP"
Add-ReportLine "pipeline triggers an IWDG reset (~2 s). The destructive IT-07 'suspend"
Add-ReportLine "FFT_Task -> MCU resets' is a manual/debugger test; a real reset then shows"
Add-ReportLine "'last reset: IWDG' on the next boot."
Add-ReportLine ""
if (-not $ok) {
    Add-ReportLine "TASK-12 Monitor/Watchdog check FAILED."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}
Add-ReportLine "TASK-12 Monitor/Watchdog check passed."
Add-ReportLine "Report written to: $ReportPath"
