param(
    [string]$Port = "COM3",
    [int]$Baud = 115200,
    [int]$ReadSeconds = 12,
    [switch]$NoFlash,
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$Configuration = "Debug",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$buildDir = Join-Path $ProjectRoot "STM32CubeIDE\$Configuration"
$elfPath = Join-Path $buildDir "code_ver2_Fs16khz.elf"
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot "debug\task07_fft_report.txt"
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
Set-Content -Path $ReportPath -Value "TASK-07 Hann + FFT report"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

$programmer = Find-Tool -Name "STM32_Programmer_CLI.exe" -SearchRoots @("C:\ST", "C:\Program Files\STMicroelectronics")
if (-not $programmer) {
    throw "STM32_Programmer_CLI.exe not found. Install STM32CubeProgrammer or STM32CubeIDE."
}

Add-ReportLine "TASK-07 Hann + FFT Verify"
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
    Add-ReportLine "Reading $Port for up to $ReadSeconds s (waiting for self-test + 1 FFT line)..."
    $deadline = (Get-Date).AddSeconds($ReadSeconds)
    $buf = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $buf += $sp.ReadExisting()
        # stop once we have the self-test verdict AND at least one live FFT line
        if (($buf -match "TASK-07 self-test (OK|FAIL)") -and ($buf -match "FFT \d+us peakHz")) {
            Start-Sleep -Milliseconds 300; $buf += $sp.ReadExisting(); break
        }
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
}

Add-ReportLine ""
Add-ReportLine "----- VCP output (excerpt) -----"
$lines = $buf -split "`r?`n"
# keep the TASK-07 banner block and the first couple FFT lines tidy
foreach ($l in $lines) {
    if ($l -match "TASK-07|self-test|FFT \d+us peakHz") { Add-ReportLine $l.Trim() }
}
Add-ReportLine "--------------------------------"
Add-ReportLine ""

$ok = $true

# 1) self-test peak bin
if ([regex]::IsMatch($buf, "TASK-07 self-test OK")) {
    $m = [regex]::Match($buf, "self-test:\s*\d+\s*Hz\s*->\s*peak bin\s*(\d+)\s*\(expected\s*(\d+)\)")
    if ($m.Success) {
        Add-ReportLine "[ OK ] FFT self-test peak bin $($m.Groups[1].Value) (expected $($m.Groups[2].Value))"
    } else {
        Add-ReportLine "[ OK ] FFT self-test passed"
    }
} else {
    $ok = $false
    if ([regex]::IsMatch($buf, "TASK-07 self-test FAIL")) {
        Add-ReportLine "[FAIL] FFT self-test reported FAIL (peak bin off)"
    } else {
        Add-ReportLine "[FAIL] TASK-07 self-test result not seen in VCP output"
    }
}

# 2) live 8-mic FFT actually runs (timing line present)
$mt = [regex]::Match($buf, "FFT (\d+)us peakHz\[([^\]]*)\]")
if ($mt.Success) {
    $us = [int]$mt.Groups[1].Value
    Add-ReportLine "[ OK ] Live 8-mic FFT runs: $us us/pass, peakHz = [$($mt.Groups[2].Value)]"
    if ($us -gt 60000) {
        Add-ReportLine "[warn] FFT pass > 60 ms - slower than expected (check optimization)"
    }
} else {
    $ok = $false
    Add-ReportLine "[FAIL] No live FFT timing line seen"
}

# 3) no DMA overruns while FFT runs in the loop
$mo = [regex]::Match($buf, "overruns=(\d+)")
if ($mo.Success -and ([int]$mo.Groups[1].Value -ne 0)) {
    Add-ReportLine "[warn] overruns=$($mo.Groups[1].Value) (FFT may be starving the capture loop)"
}

Add-ReportLine ""
if (-not $ok) {
    Add-ReportLine "TASK-07 FFT check FAILED."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

Add-ReportLine "TASK-07 FFT check passed."
Add-ReportLine "Report written to: $ReportPath"
