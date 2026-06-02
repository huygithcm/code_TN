<#
.SYNOPSIS
  TASK-13 end-to-end integration test. Flashes once, then runs the IT-01..IT-07
  matrix from the breakdown by combining the on-chip self-tests, a sustained soak,
  and the USB continuity check into one consolidated PASS/FAIL report.

  IT-01 Tone bin        1 kHz -> FFT peak bin 64        (on-chip self-test, TASK-07)
  IT-02 Silence         zero-in -> zero-out spectrum    (on-chip self-test, TASK-13)
  IT-03 TDOA synthetic  5-sample delay -> lag 5         (on-chip self-test, TASK-08)
  IT-04 USB continuity  60 s, no sequence gap           (OTG CDC, reuses TASK-10 check)
  IT-05 DOA sweep       speaker at 0/45/90 deg          (MANUAL; solver self-test auto)
  IT-06 Overrun soak    overruns=0 / saiErr=0           (sustained [MON], TASK-12)
  IT-07 Watchdog        stall -> MCU reset              (MANUAL/destructive; see TASK-12)

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/check_task13_integration.ps1
  powershell -ExecutionPolicy Bypass -File scripts/check_task13_integration.ps1 -SoakSeconds 600
  powershell -ExecutionPolicy Bypass -File scripts/check_task13_integration.ps1 -SkipUsb
#>
param(
    [string]$VcpPort = "COM3",
    [int]$Baud = 115200,
    [int]$BannerSeconds = 8,        # read window for the boot self-tests
    [int]$SoakSeconds = 60,         # IT-06 soak (breakdown's full run is 600)
    [int]$UsbSeconds = 60,          # IT-04 USB continuity window
    [switch]$NoFlash,
    [switch]$SkipUsb,
    [string]$ProjectRoot = (Resolve-Path "$PSScriptRoot\..").Path,
    [string]$Configuration = "Debug",
    [string]$ReportPath = ""
)

$ErrorActionPreference = "Stop"

$buildDir = Join-Path $ProjectRoot "STM32CubeIDE\$Configuration"
$elfPath  = Join-Path $buildDir "code_ver2_Fs16khz.elf"
if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $ProjectRoot "debug\task13_integration_report.txt"
}
$stackAlloc = @{ def = 512; fft = 2048; usb = 512; doa = 512; mon = 512 }

function Find-Tool {
    param([string]$Name, [string[]]$SearchRoots)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($root in $SearchRoots) {
        if (Test-Path $root) {
            $t = Get-ChildItem -Path $root -Recurse -Filter $Name -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($t) { return $t.FullName }
        }
    }
    return $null
}
function Add-ReportLine { param([string]$Line) Write-Host $Line; Add-Content -Path $ReportPath -Value $Line }

if (-not (Test-Path $elfPath)) { throw "ELF not found: $elfPath (build first)" }
$reportDir = Split-Path -Parent $ReportPath
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir | Out-Null }
Set-Content -Path $ReportPath -Value "TASK-13 integration test report"
Add-Content -Path $ReportPath -Value ("Generated: {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
Add-Content -Path $ReportPath -Value ""

$programmer = Find-Tool -Name "STM32_Programmer_CLI.exe" -SearchRoots @("C:\ST", "C:\Program Files\STMicroelectronics")
if (-not $programmer) { throw "STM32_Programmer_CLI.exe not found." }

Add-ReportLine "TASK-13 End-to-End Integration Test"
Add-ReportLine "ELF : $elfPath"
Add-ReportLine "VCP : $VcpPort @ $Baud   soak=${SoakSeconds}s   usb=${UsbSeconds}s"
Add-ReportLine ""

# ---- flash once, then capture banner + soak from the VCP --------------------
$sp = New-Object System.IO.Ports.SerialPort($VcpPort, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
try { $sp.Open() } catch { throw "Could not open ${VcpPort}: $($_.Exception.Message)" }

try {
    $sp.DiscardInBuffer()
    if (-not $NoFlash) {
        Add-ReportLine "Flashing firmware and resetting..."
        $flashOut = & $programmer -c port=SWD mode=UR -d "$elfPath" -rst 2>&1
        foreach ($l in $flashOut) { Add-Content -Path $ReportPath -Value $l }
        if (-not ($flashOut -match "File download complete")) {
            Add-ReportLine "[FAIL] Programmer did not report 'File download complete' - aborting."
            if ($sp.IsOpen) { $sp.Close() }
            exit 1
        }
    } else {
        Add-ReportLine "Resetting target (no flash)..."
        & $programmer -c port=SWD mode=UR -rst 2>&1 | Out-Null
    }

    $total = $BannerSeconds + $SoakSeconds
    Add-ReportLine "Reading $VcpPort for ${total}s (boot self-tests + IT-06 soak)..."
    $deadline = (Get-Date).AddSeconds($total)
    $buf = ""
    while ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250; $buf += $sp.ReadExisting() }
}
finally { if ($sp.IsOpen) { $sp.Close() } }

# ---- evaluate the on-chip + soak results -----------------------------------
$results = [ordered]@{}

# IT-01 tone bin
$m = [regex]::Match($buf, "self-test:\s*1000 Hz -> peak bin (\d+)")
if ($m.Success -and [regex]::IsMatch($buf, "TASK-07 self-test OK")) {
    $bin = [int]$m.Groups[1].Value
    $results["IT-01 Tone bin (1kHz->bin64)"]       = if ($bin -ge 63 -and $bin -le 65) { "PASS (bin $bin)" } else { "FAIL (bin $bin)" }
} else { $results["IT-01 Tone bin (1kHz->bin64)"] = "FAIL (no self-test)" }

# IT-02 silence
$results["IT-02 Silence (zero-in->zero-out)"]      = if ([regex]::IsMatch($buf, "IT-02 silence self-test OK")) { "PASS" } else { "FAIL" }

# IT-03 TDOA synthetic
$m = [regex]::Match($buf, "self-test:\s*delay 5 -> lag (\-?\d+)")
if ($m.Success -and [regex]::IsMatch($buf, "TASK-08 self-test OK")) {
    $lag = [int]$m.Groups[1].Value
    $results["IT-03 TDOA synthetic (delay5->lag5)"] = if ($lag -ge 4 -and $lag -le 6) { "PASS (lag $lag)" } else { "FAIL (lag $lag)" }
} else { $results["IT-03 TDOA synthetic (delay5->lag5)"] = "FAIL (no self-test)" }

# IT-06 soak: overruns=0, saiErr=0, blocks advance, exactly one boot (no reset), stacks ok
$mon = [regex]::Matches($buf, "\[MON\]\s+blocks=(\d+)\s+overruns=(\d+)\s+fft=\d+us\s+gcc=\d+us\s+heapFree=\d+\s+saiErr=(\d+)")
$banners = [regex]::Matches($buf, "last reset:")
$it06 = "FAIL"
if ($mon.Count -ge 2) {
    $b0 = [int]$mon[0].Groups[1].Value; $bN = [int]$mon[$mon.Count-1].Groups[1].Value
    $maxOver = 0; $maxSai = 0
    foreach ($x in $mon) { $o=[int]$x.Groups[2].Value; if($o -gt $maxOver){$maxOver=$o}; $s=[int]$x.Groups[3].Value; if($s -gt $maxSai){$maxSai=$s} }
    if (($bN -gt $b0) -and ($maxOver -eq 0) -and ($maxSai -eq 0) -and ($banners.Count -le 1)) {
        $it06 = "PASS (blocks $b0->$bN, overruns=0, saiErr=0, no reset)"
    } else {
        $it06 = "FAIL (blocksAdv=$($bN-$b0) maxOver=$maxOver maxSai=$maxSai banners=$($banners.Count))"
    }
}
$results["IT-06 Overrun soak (${SoakSeconds}s)"] = $it06

# stack high-water (supporting metric, folded into IT-06 health)
$stk = [regex]::Match($buf, "\[STK\]\s+def=(\d+)\s+fft=(\d+)\s+usb=(\d+)\s+doa=(\d+)\s+mon=(\d+)")
$stackLine = "n/a"
if ($stk.Success) {
    $hw = @{ def=[int]$stk.Groups[1].Value; fft=[int]$stk.Groups[2].Value; usb=[int]$stk.Groups[3].Value; doa=[int]$stk.Groups[4].Value; mon=[int]$stk.Groups[5].Value }
    $stkOk = $true
    foreach ($k in @("def","fft","usb","doa","mon")) { if ($hw[$k] -lt [math]::Ceiling($stackAlloc[$k]*0.10)) { $stkOk = $false } }
    $stackLine = ("def={0} fft={1} usb={2} doa={3} mon={4} -> {5}" -f $hw.def,$hw.fft,$hw.usb,$hw.doa,$hw.mon, ($(if($stkOk){"all >10%"}else{"BELOW 10%"})))
    if (-not $stkOk) { $results["IT-06 Overrun soak (${SoakSeconds}s)"] = "FAIL (stack <10%)" }
}

# DOA solver self-test (supports IT-05)
$doaSelf = if ([regex]::IsMatch($buf, "TASK-11 self-test OK")) { "PASS" } else { "FAIL" }

# reset cause line
$rst = [regex]::Match($buf, "last reset:([^\r\n]*)")
$resetCause = if ($rst.Success) { $rst.Groups[1].Value.Trim() } else { "(not seen)" }

# ---- IT-04 USB continuity: reuse the TASK-10 check (no flash) ---------------
$it04 = "SKIPPED"
if (-not $SkipUsb) {
    Add-ReportLine ""
    Add-ReportLine "Running IT-04 USB continuity (${UsbSeconds}s) via check_task10_usb_cdc.ps1..."
    $usbScript = Join-Path $PSScriptRoot "check_task10_usb_cdc.ps1"
    & powershell -ExecutionPolicy Bypass -File $usbScript -DurationSec $UsbSeconds | Out-Null
    $it04 = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
}

# ---- consolidated report ---------------------------------------------------
$results["IT-04 USB continuity (${UsbSeconds}s)"] = $it04
$results["IT-05 DOA sweep (speaker angles)"]      = "MANUAL (solver self-test $doaSelf; acoustic sweep is manual)"
$results["IT-07 Watchdog (stall->reset)"]         = "MANUAL (demonstrated in TASK-12; destructive)"

Add-ReportLine ""
Add-ReportLine "================ TASK-13 Integration Matrix ================"
Add-ReportLine ("boot reset-cause : {0}" -f $resetCause)
Add-ReportLine ("stack high-water : {0}" -f $stackLine)
Add-ReportLine "------------------------------------------------------------"
$fail = 0
foreach ($k in $results.Keys) {
    $v = $results[$k]
    Add-ReportLine ("{0,-38} : {1}" -f $k, $v)
    if ($v -like "FAIL*") { $fail++ }
}
Add-ReportLine "============================================================"
Add-ReportLine ""
Add-ReportLine "IT-05/IT-07 are manual: move a source around the array and watch az/el on"
Add-ReportLine "$VcpPort (IT-05); IT-07 watchdog reset is demonstrated in TASK-12 (stall the"
Add-ReportLine "pipeline -> 'last reset: IWDG' on the next boot)."
Add-ReportLine ""
if ($fail -gt 0) {
    Add-ReportLine "TASK-13 integration test FAILED ($fail automated check(s))."
    Add-ReportLine "Report written to: $ReportPath"
    exit 1
}
Add-ReportLine "TASK-13 integration test passed (all automated IT checks)."
Add-ReportLine "Report written to: $ReportPath"
