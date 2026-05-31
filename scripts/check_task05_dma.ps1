param(
    [string]$Port = "COM3",
    [int]$Baud = 115200,
    [int]$ReadSeconds = 10,
    [switch]$NoFlash,
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$Configuration = "Debug",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$buildDir = Join-Path $ProjectRoot "STM32CubeIDE\$Configuration"
$elfPath = Join-Path $buildDir "code_ver2_Fs16khz.elf"
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot "debug\task05_dma_report.txt"
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
Set-Content -Path $ReportPath -Value "TASK-05 DMA ping-pong report"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

$programmer = Find-Tool -Name "STM32_Programmer_CLI.exe" -SearchRoots @("C:\ST", "C:\Program Files\STMicroelectronics")
if (-not $programmer) {
    throw "STM32_Programmer_CLI.exe not found. Install STM32CubeProgrammer or STM32CubeIDE."
}

Add-ReportLine "TASK-05 DMA Ping-Pong Verify"
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
    Add-ReportLine "Reading $Port for up to $ReadSeconds s..."
    $deadline = (Get-Date).AddSeconds($ReadSeconds)
    $buf = ""
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $buf += $sp.ReadExisting()
        if ($buf -match "TASK-05 (OK|FAIL)") { Start-Sleep -Milliseconds 300; $buf += $sp.ReadExisting(); break }
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
}

Add-ReportLine ""
Add-ReportLine "----- VCP output -----"
$lines = $buf -split "`r?`n"
foreach ($l in $lines) { if ($l.Trim().Length -gt 0) { Add-ReportLine $l } }
Add-ReportLine "----------------------"
Add-ReportLine ""

$ok = $true
if ([regex]::IsMatch($buf, "TASK-05 OK")) {
    Add-ReportLine "[ OK ] All 4 DMA streams ping-ponging (TASK-05 OK)"
} else {
    $ok = $false
    $m = [regex]::Match($buf, "TASK-05 FAIL: (\d+)/4")
    if ($m.Success) {
        Add-ReportLine "[FAIL] Only $($m.Groups[1].Value)/4 DMA streams active"
    } else {
        Add-ReportLine "[FAIL] TASK-05 result not seen in VCP output"
    }
}

Add-ReportLine ""
if (-not $ok) {
    Add-ReportLine "TASK-05 DMA check FAILED."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

Add-ReportLine "TASK-05 DMA check passed."
Add-ReportLine "Report written to: $ReportPath"
