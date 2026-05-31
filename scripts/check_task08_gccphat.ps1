param(
    [string]$Port = "COM3",
    [int]$Baud = 115200,
    [int]$ReadSeconds = 14,
    [switch]$NoFlash,
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$Configuration = "Debug",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$buildDir = Join-Path $ProjectRoot "STM32CubeIDE\$Configuration"
$elfPath = Join-Path $buildDir "code_ver2_Fs16khz.elf"
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot "debug\task08_gccphat_report.txt"
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
Set-Content -Path $ReportPath -Value "TASK-08 GCC-PHAT / TDOA report"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

$programmer = Find-Tool -Name "STM32_Programmer_CLI.exe" -SearchRoots @("C:\ST", "C:\Program Files\STMicroelectronics")
if (-not $programmer) {
    throw "STM32_Programmer_CLI.exe not found. Install STM32CubeProgrammer or STM32CubeIDE."
}

Add-ReportLine "TASK-08 GCC-PHAT / TDOA Verify"
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
    Add-ReportLine "Reading $Port for up to $ReadSeconds s (self-test + 1 live GCC line)..."
    $deadline = (Get-Date).AddSeconds($ReadSeconds)
    $buf = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $buf += $sp.ReadExisting()
        if (($buf -match "TASK-08 self-test (OK|FAIL)") -and ($buf -match "GCC \d+us lag0x")) {
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
foreach ($l in $lines) {
    if ($l -match "TASK-08|self-test: delay|GCC \d+us lag0x") { Add-ReportLine $l.Trim() }
}
Add-ReportLine "--------------------------------"
Add-ReportLine ""

$ok = $true

# 1) synthetic-delay self-test (lag == GCC_SELFTEST_SHIFT +/-1)
if ([regex]::IsMatch($buf, "TASK-08 self-test OK")) {
    $m = [regex]::Match($buf, "self-test:\s*delay\s*(-?\d+)\s*->\s*lag\s*(-?\d+)\s*\(expected\s*(-?\d+)\)")
    if ($m.Success) {
        Add-ReportLine "[ OK ] GCC-PHAT self-test lag=$($m.Groups[2].Value) (expected $($m.Groups[3].Value))"
    } else {
        Add-ReportLine "[ OK ] GCC-PHAT self-test passed"
    }
} else {
    $ok = $false
    if ([regex]::IsMatch($buf, "TASK-08 self-test FAIL")) {
        $m = [regex]::Match($buf, "self-test:\s*delay\s*(-?\d+)\s*->\s*lag\s*(-?\d+)")
        if ($m.Success) {
            Add-ReportLine "[FAIL] GCC-PHAT self-test lag=$($m.Groups[2].Value), expected ~$($m.Groups[1].Value)"
        } else {
            Add-ReportLine "[FAIL] GCC-PHAT self-test reported FAIL"
        }
    } else {
        Add-ReportLine "[FAIL] TASK-08 self-test result not seen in VCP output"
    }
}

# 2) live pairs actually compute (timing + lag vector present)
$mt = [regex]::Match($buf, "GCC (\d+)us lag0x\[([^\]]*)\]")
if ($mt.Success) {
    Add-ReportLine "[ OK ] Live GCC-PHAT runs: $([int]$mt.Groups[1].Value) us, mic0-vs-mic1..7 lags = [$($mt.Groups[2].Value)]"
} else {
    $ok = $false
    Add-ReportLine "[FAIL] No live GCC-PHAT line seen"
}

# 3) no overruns introduced by the extra DSP load
$mo = [regex]::Match($buf, "overruns=(\d+)")
if ($mo.Success -and ([int]$mo.Groups[1].Value -ne 0)) {
    Add-ReportLine "[warn] overruns=$($mo.Groups[1].Value) (FFT+GCC may be starving the capture loop)"
}

Add-ReportLine ""
if (-not $ok) {
    Add-ReportLine "TASK-08 GCC-PHAT check FAILED."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

Add-ReportLine "TASK-08 GCC-PHAT check passed."
Add-ReportLine "Report written to: $ReportPath"
