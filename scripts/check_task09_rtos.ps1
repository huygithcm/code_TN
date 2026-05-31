param(
    [string]$Port = "COM3",
    [int]$Baud = 115200,
    [int]$ReadSeconds = 16,
    [switch]$NoFlash,
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$Configuration = "Debug",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$buildDir = Join-Path $ProjectRoot "STM32CubeIDE\$Configuration"
$elfPath = Join-Path $buildDir "code_ver2_Fs16khz.elf"
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot "debug\task09_rtos_report.txt"
}

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
Set-Content -Path $ReportPath -Value "TASK-09 RTOS tasks and IPC report"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

$programmer = Find-Tool -Name "STM32_Programmer_CLI.exe" -SearchRoots @("C:\ST", "C:\Program Files\STMicroelectronics")
if (-not $programmer) {
    throw "STM32_Programmer_CLI.exe not found. Install STM32CubeProgrammer or STM32CubeIDE."
}

Add-ReportLine "TASK-09 RTOS Tasks + IPC Verify"
Add-ReportLine "ELF : $elfPath"
Add-ReportLine "Port: $Port @ $Baud"
Add-ReportLine ""

$sp = New-Object System.IO.Ports.SerialPort($Port, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
try {
    $sp.Open()
} catch {
    throw "Could not open ${Port}: $($_.Exception.Message). Close any serial terminal using it."
}

try {
    $sp.DiscardInBuffer()

    if (-not $NoFlash) {
        Add-ReportLine "Flashing firmware and resetting..."
        $flashOut = & $programmer -c port=SWD mode=UR -d "$elfPath" -rst 2>&1
        foreach ($line in $flashOut) { Add-Content -Path $ReportPath -Value $line }
        if ($LASTEXITCODE -ne 0) {
            Add-ReportLine "Programmer exit code $LASTEXITCODE (continuing to read serial anyway)"
        }
    } else {
        Add-ReportLine "Resetting target (no flash)..."
        & $programmer -c port=SWD mode=UR -rst 2>&1 | Out-Null
    }

    Add-ReportLine ""
    Add-ReportLine "Reading $Port for up to $ReadSeconds s (waiting for vTaskList + monitor line)..."
    $deadline = (Get-Date).AddSeconds($ReadSeconds)
    $buf = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $buf += $sp.ReadExisting()
        if (($buf -match "TASK-09 vTaskList") -and ($buf -match "\[MON\]\s+blocks=\d+")) {
            Start-Sleep -Milliseconds 500
            $buf += $sp.ReadExisting()
            break
        }
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
}

Add-ReportLine ""
Add-ReportLine "----- VCP output (excerpt) -----"
$lines = $buf -split "`r?`n"
foreach ($l in $lines) {
    if ($l -match "TASK-03|TASK-04|TASK-07|TASK-08|TASK-09|self-test|FFT_Task|USB_Task|DOA_Task|Monitor_Task|\[MON\]") {
        Add-ReportLine $l.Trim()
    }
}
Add-ReportLine "--------------------------------"
Add-ReportLine ""

$ok = $true

if ([regex]::IsMatch($buf, "TASK-07 self-test OK")) {
    Add-ReportLine "[ OK ] TASK-07 FFT self-test still passes under RTOS"
} else {
    $ok = $false
    Add-ReportLine "[FAIL] TASK-07 FFT self-test result not seen"
}

if ([regex]::IsMatch($buf, "TASK-08 self-test OK")) {
    Add-ReportLine "[ OK ] TASK-08 GCC-PHAT self-test still passes under RTOS"
} else {
    $ok = $false
    Add-ReportLine "[FAIL] TASK-08 GCC-PHAT self-test result not seen"
}

if ([regex]::IsMatch($buf, "TASK-09 vTaskList")) {
    Add-ReportLine "[ OK ] vTaskList printed"
} else {
    $ok = $false
    Add-ReportLine "[FAIL] TASK-09 vTaskList not seen"
}

$taskNames = @("FFT_Task", "USB_Task", "DOA_Task", "Monitor_Task")
foreach ($taskName in $taskNames) {
    $m = [regex]::Match($buf, "(?m)^\s*$([regex]::Escape($taskName))\s+([XRBSD])\s+(\d+)\s+(\d+)\s+(\d+)")
    if ($m.Success) {
        $state = $m.Groups[1].Value
        $stack = [int]$m.Groups[3].Value
        Add-ReportLine "[ OK ] $taskName present (state=$state, stack_free=$stack words)"
        if ($state -eq "D") {
            $ok = $false
            Add-ReportLine "[FAIL] $taskName is deleted"
        }
        if ($stack -le 0) {
            $ok = $false
            Add-ReportLine "[FAIL] $taskName reports no free stack"
        }
    } else {
        $ok = $false
        Add-ReportLine "[FAIL] $taskName not found in vTaskList"
    }
}

$monMatches = [regex]::Matches($buf, "\[MON\]\s+blocks=(\d+)\s+overruns=(\d+)\s+fft=(\d+)us\s+gcc=(\d+)us\s+heapFree=(\d+)")
if ($monMatches.Count -gt 0) {
    $last = $monMatches[$monMatches.Count - 1]
    $blocks = [int]$last.Groups[1].Value
    $overruns = [int]$last.Groups[2].Value
    $fftUs = [int]$last.Groups[3].Value
    $gccUs = [int]$last.Groups[4].Value
    $heapFree = [int]$last.Groups[5].Value
    Add-ReportLine "[ OK ] Monitor line seen: blocks=$blocks overruns=$overruns fft=${fftUs}us gcc=${gccUs}us heapFree=$heapFree"

    if ($blocks -le 0) {
        $ok = $false
        Add-ReportLine "[FAIL] blocks did not advance"
    }
    if ($overruns -ne 0) {
        $ok = $false
        Add-ReportLine "[FAIL] DMA overruns=$overruns"
    }
    if ($heapFree -lt 1024) {
        Add-ReportLine "[warn] heapFree below 1 KB"
    }
    if (($fftUs + $gccUs) -gt 60000) {
        Add-ReportLine "[warn] FFT+GCC work is close to the 64 ms half-buffer period"
    }
} else {
    $ok = $false
    Add-ReportLine "[FAIL] No monitor line seen"
}

Add-ReportLine ""
if (-not $ok) {
    Add-ReportLine "TASK-09 RTOS check FAILED."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

Add-ReportLine "TASK-09 RTOS check passed."
Add-ReportLine "Report written to: $ReportPath"
