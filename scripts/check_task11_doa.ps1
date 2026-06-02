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
    $ReportPath = Join-Path $ProjectRoot "debug\task11_doa_report.txt"
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
Set-Content -Path $ReportPath -Value "TASK-11 DOA (direction of arrival) report"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

$programmer = Find-Tool -Name "STM32_Programmer_CLI.exe" -SearchRoots @("C:\ST", "C:\Program Files\STMicroelectronics")
if (-not $programmer) {
    throw "STM32_Programmer_CLI.exe not found. Install STM32CubeProgrammer or STM32CubeIDE."
}

Add-ReportLine "TASK-11 DOA Verify"
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
    Add-ReportLine "Reading $Port for up to $ReadSeconds s (waiting for DOA self-test + live fixes)..."
    $deadline = (Get-Date).AddSeconds($ReadSeconds)
    $buf = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $buf += $sp.ReadExisting()
        if (($buf -match "TASK-11 self-test") -and ($buf -match "DOA seq=\d+\s+az=")) {
            Start-Sleep -Milliseconds 800
            $buf += $sp.ReadExisting()
            # keep reading a touch longer to collect a few live fixes
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
    if ($l -match "TASK-07 self-test|TASK-08 self-test|TASK-11|self-test:|DOA seq=|\[MON\]") {
        Add-ReportLine $l.Trim()
    }
}
Add-ReportLine "--------------------------------"
Add-ReportLine ""

$ok = $true

# regression: the upstream self-tests must still pass under the DOA build
if ([regex]::IsMatch($buf, "TASK-07 self-test OK")) {
    Add-ReportLine "[ OK ] TASK-07 FFT self-test still passes"
} else {
    $ok = $false; Add-ReportLine "[FAIL] TASK-07 FFT self-test not seen"
}
if ([regex]::IsMatch($buf, "TASK-08 self-test OK")) {
    Add-ReportLine "[ OK ] TASK-08 GCC-PHAT self-test still passes"
} else {
    $ok = $false; Add-ReportLine "[FAIL] TASK-08 GCC-PHAT self-test not seen"
}

# TASK-11 geometry/solver self-test (synthetic azimuth must be recovered)
if ([regex]::IsMatch($buf, "TASK-11 self-test OK")) {
    Add-ReportLine "[ OK ] DOA solver self-test passed (synthetic azimuth recovered)"
} else {
    $ok = $false; Add-ReportLine "[FAIL] DOA solver self-test not OK"
}

# live DOA fixes present, with az/el in valid ranges
$doa = [regex]::Matches($buf, "DOA seq=(\d+)\s+az=(-?\d+\.\d+)\s+el=(-?\d+\.\d+)")
if ($doa.Count -gt 0) {
    Add-ReportLine "[ OK ] Live DOA output present ($($doa.Count) fix(es))"
    $rangeOk = $true
    $series = New-Object System.Collections.Generic.List[string]
    foreach ($m in $doa) {
        $az = [double]$m.Groups[2].Value
        $el = [double]$m.Groups[3].Value
        if ($az -lt 0 -or $az -ge 360 -or $el -lt 0 -or $el -gt 90) { $rangeOk = $false }
        $series.Add(("az={0} el={1}" -f $az, $el))
    }
    Add-ReportLine ("       fixes: " + ($series -join "  |  "))
    if ($rangeOk) {
        Add-ReportLine "[ OK ] All az in [0,360) and el in [0,90]"
    } else {
        $ok = $false; Add-ReportLine "[FAIL] A DOA fix is out of range"
    }
} else {
    $ok = $false; Add-ReportLine "[FAIL] No live DOA fixes seen"
}

# pipeline still healthy
$mon = [regex]::Match($buf, "\[MON\]\s+blocks=(\d+)\s+overruns=(\d+)")
if ($mon.Success) {
    $overruns = [int]$mon.Groups[2].Value
    if ($overruns -eq 0) {
        Add-ReportLine "[ OK ] Pipeline healthy (overruns=0)"
    } else {
        $ok = $false; Add-ReportLine "[FAIL] DMA overruns=$overruns"
    }
}

Add-ReportLine ""
Add-ReportLine "Note: 'speaker moves -> angle changes' is a manual check. Wave a sound"
Add-ReportLine "source around the array and watch the live az/el on COM3 (re-run with"
Add-ReportLine "-NoFlash to avoid resetting), or compare fixes above."
Add-ReportLine ""
if (-not $ok) {
    Add-ReportLine "TASK-11 DOA check FAILED."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

Add-ReportLine "TASK-11 DOA check passed."
Add-ReportLine "Report written to: $ReportPath"
