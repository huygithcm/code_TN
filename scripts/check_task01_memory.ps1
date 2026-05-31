param(
    [switch]$ReadTarget,
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$Configuration = "Debug",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$buildDir = Join-Path $ProjectRoot "STM32CubeIDE\$Configuration"
$mapPath = Join-Path $buildDir "code_ver2_Fs16khz.map"
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot "debug\task01_memory_report.txt"
}

function Find-Tool {
    param(
        [string]$Name,
        [string[]]$SearchRoots
    )

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    foreach ($root in $SearchRoots) {
        if (Test-Path $root) {
            $tool = Get-ChildItem -Path $root -Recurse -Filter $Name -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($tool) {
                return $tool.FullName
            }
        }
    }

    return $null
}

function Get-MapSymbol {
    param(
        [string]$MapText,
        [string]$SymbolName
    )

    $escaped = [regex]::Escape($SymbolName)
    $patterns = @(
        "(?m)^\s*(0x[0-9a-fA-F]+)\s+$escaped\s*$",
        "(?m)^\s*$escaped\s+0x([0-9a-fA-F]+)\s*$"
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($MapText, $pattern)
        if ($match.Success) {
            $hex = $match.Groups[1].Value
            if (-not $hex.StartsWith("0x")) {
                $hex = "0x$hex"
            }

            return [uint64]::Parse($hex.Substring(2), [System.Globalization.NumberStyles]::HexNumber)
        }
    }

    return $null
}

function Test-AddressRange {
    param(
        [string]$Name,
        [Nullable[uint64]]$Address,
        [uint64]$Start,
        [uint64]$EndExclusive
    )

    if ($null -eq $Address) {
        Add-ReportLine "[FAIL] $Name not found in map file"
        return $false
    }

    $hex = "0x{0:X8}" -f $Address
    if (($Address -ge $Start) -and ($Address -lt $EndExclusive)) {
        Add-ReportLine "[ OK ] $Name = $hex"
        return $true
    }

    Add-ReportLine ("[FAIL] $Name = $hex, expected 0x{0:X8}..0x{1:X8}" -f $Start, ($EndExclusive - 1))
    return $false
}

function Add-ReportLine {
    param([string]$Line)
    Write-Host $Line
    Add-Content -Path $ReportPath -Value $Line
}

function Read-TargetMemory {
    param(
        [string]$Programmer,
        [string]$Name,
        [Nullable[uint64]]$Address,
        [uint32]$Bytes
    )

    if ($null -eq $Address) {
        Add-ReportLine ""
        Add-ReportLine "ST-LINK read skipped for $Name because the symbol was not found."
        return
    }

    $addrHex = "0x{0:X8}" -f $Address
    Add-ReportLine ""
    Add-ReportLine "ST-LINK read: $Name at $addrHex, $Bytes bytes"

    $output = & $Programmer -c port=SWD mode=UR -r32 $addrHex $Bytes 2>&1
    foreach ($line in $output) {
        Add-ReportLine $line
    }

    if ($LASTEXITCODE -ne 0) {
        Add-ReportLine "ST-LINK read failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path $mapPath)) {
    throw "Map file not found: $mapPath"
}

$reportDir = Split-Path -Parent $ReportPath
if (-not (Test-Path $reportDir)) {
    New-Item -ItemType Directory -Path $reportDir | Out-Null
}
Set-Content -Path $ReportPath -Value "TASK-01 memory debug report"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

$mapText = Get-Content -Path $mapPath -Raw

$dmaBuf = Get-MapSymbol -MapText $mapText -SymbolName "dma_buf"
$micData = Get-MapSymbol -MapText $mapText -SymbolName "mic_data"

Add-ReportLine "Checking Task-01 memory map:"
Add-ReportLine "Map: $mapPath"

$ok = $true
$ok = (Test-AddressRange -Name "dma_buf" -Address $dmaBuf -Start 0x24000000 -EndExclusive 0x24100000) -and $ok
$ok = (Test-AddressRange -Name "mic_data" -Address $micData -Start 0x20000000 -EndExclusive 0x20020000) -and $ok

if ($ReadTarget) {
    $programmer = Find-Tool -Name "STM32_Programmer_CLI.exe" -SearchRoots @("C:\ST", "C:\Program Files\STMicroelectronics")
    if (-not $programmer) {
        throw "STM32_Programmer_CLI.exe was not found. Install STM32CubeProgrammer or STM32CubeIDE."
    }

    Add-ReportLine ""
    Add-ReportLine "Using STM32 Programmer CLI: $programmer"
    Read-TargetMemory -Programmer $programmer -Name "dma_buf" -Address $dmaBuf -Bytes 32
    Read-TargetMemory -Programmer $programmer -Name "mic_data" -Address $micData -Bytes 32
}

if (-not $ok) {
    Add-ReportLine ""
    Add-ReportLine "Hint: if symbols are missing, build the project in STM32CubeIDE first."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}

Add-ReportLine ""
Add-ReportLine "Task-01 memory map check passed."
Add-ReportLine "Report written to: $ReportPath"
