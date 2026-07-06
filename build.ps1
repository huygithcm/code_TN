<#
.SYNOPSIS
    Script build cho project STM32H7A3ZITxQ (NUCLEO-H7A3ZI-Q).

.DESCRIPTION
    Tu dong dinh vi toolchain arm-none-eabi-gcc + make di kem STM32CubeIDE,
    them vao PATH va goi `make` voi Makefile o thu muc goc.
    Khong can cai dat ARM GCC rieng — tan dung toolchain bundled cua CubeIDE.

.PARAMETER Task
    build   (mac dinh) : bien dich ra .elf/.hex/.bin trong thu muc build/
    clean              : xoa thu muc build/
    rebuild            : clean roi build lai
    flash              : nap file .hex vao board qua ST-LINK (STM32_Programmer_CLI)

.PARAMETER Release
    Build cau hinh Release (-Os, khong debug). Mac dinh la Debug.

.PARAMETER Jobs
    So luong job song song cho make. Mac dinh = so core CPU.

.EXAMPLE
    .\build.ps1                 # build Debug
    .\build.ps1 rebuild
    .\build.ps1 build -Release
    .\build.ps1 flash
#>
[CmdletBinding()]
param(
    [ValidateSet('build', 'clean', 'rebuild', 'flash')]
    [string]$Task = 'build',
    [switch]$Release,
    [int]$Jobs = 0
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root

# --- 1. Dinh vi toolchain (portable — khong hardcode duong dan) -----------
# Khi tim moi cong cu, thu tu uu tien:
#   1) Bien moi truong ghi de (STM32CUBEIDE_PATH / STM32CUBEPROG_PATH)
#   2) Da co san tren PATH (vd toolchain cai rieng)
#   3) Quet cac thu muc cai dat ST tren MOI o dia co dinh + Program Files
# Nho vay script chay duoc tren may khac ma khong can sua duong dan trong file.

# Cac thu muc goc co the chua ban cai ST (chi nhung noi dac thu ST de tranh
# quet toan bo Program Files). Chi tra ve thu muc thuc su ton tai.
function Get-StSearchRoots {
    $roots = @()
    foreach ($ev in @($env:STM32CUBEIDE_PATH, $env:STM32CUBEIDE_ROOT, $env:STM32CUBEPROG_PATH)) {
        if ($ev) { $roots += $ev }
    }
    # Moi o dia co dinh (C:, D:, ...), khong gia dinh chi co C:
    $drives = [System.IO.DriveInfo]::GetDrives() |
              Where-Object { $_.IsReady -and $_.DriveType -eq 'Fixed' } |
              ForEach-Object { $_.Name.TrimEnd('\') }
    foreach ($d in $drives) { $roots += "$d\ST"; $roots += "$d\STMicroelectronics" }
    # Program Files (ca 64/32-bit) va ban cai theo user — chi nhanh con STMicroelectronics
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($pf) { $roots += (Join-Path $pf 'STMicroelectronics') }
    }
    if ($env:LOCALAPPDATA) { $roots += (Join-Path $env:LOCALAPPDATA 'Programs') }
    $roots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
}

# Tim mot .exe: uu tien PATH, roi tim de quy trong cac thu muc goc ST;
# lay ban moi nhat (sort giam dan theo duong dan -> version cao hon thang).
function Find-ToolExe {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$ExtraRoots = @())
    $onPath = Get-Command $Exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    $roots = @($ExtraRoots) + (Get-StSearchRoots) | Where-Object { $_ } | Select-Object -Unique
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $hit = Get-ChildItem $root -Recurse -Filter $Exe -File -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# --- 2. gcc + make --------------------------------------------------------
$gccExe  = Find-ToolExe -Exe 'arm-none-eabi-gcc.exe'
$makeExe = Find-ToolExe -Exe 'make.exe'

if (-not $gccExe) {
    throw "Khong tim thay arm-none-eabi-gcc.exe. Cai STM32CubeIDE, hoac them toolchain " +
          "arm-none-eabi vao PATH, hoac dat bien STM32CUBEIDE_PATH tro toi thu muc cai dat."
}
if (-not $makeExe) {
    throw "Khong tim thay make.exe. Cai STM32CubeIDE hoac them 'make' vao PATH."
}

$gccBin  = Split-Path $gccExe
$makeBin = Split-Path $makeExe
$env:PATH = "$gccBin;$makeBin;$env:PATH"

Write-Host "GCC          : $gccExe"  -ForegroundColor Cyan
Write-Host "make         : $makeExe" -ForegroundColor Cyan

# --- 3. Tham so make ------------------------------------------------------
if ($Jobs -le 0) { $Jobs = [Environment]::ProcessorCount }
$debugFlag = if ($Release) { 'DEBUG=0' } else { 'DEBUG=1' }
$gccPathArg = "GCC_PATH=$($gccBin -replace '\\','/')"

function Invoke-Make([string[]]$mArgs) {
    Write-Host ">> make $($mArgs -join ' ')" -ForegroundColor Yellow
    & $makeExe @mArgs
    if ($LASTEXITCODE -ne 0) { throw "make that bai (exit $LASTEXITCODE)" }
}

# --- 4. Thuc thi task -----------------------------------------------------
switch ($Task) {
    'clean' {
        Invoke-Make @('clean')
    }
    'rebuild' {
        Invoke-Make @('clean')
        Invoke-Make @("-j$Jobs", $debugFlag, $gccPathArg, 'all')
    }
    'build' {
        Invoke-Make @("-j$Jobs", $debugFlag, $gccPathArg, 'all')
    }
    'flash' {
        $hex = Join-Path $root 'build\code_ver2_Fs16khz.hex'
        if (-not (Test-Path $hex)) {
            Write-Host "Chua co .hex — build truoc..." -ForegroundColor Yellow
            Invoke-Make @("-j$Jobs", $debugFlag, $gccPathArg, 'all')
        }
        # STM32_Programmer_CLI co the nam trong CubeIDE hoac ban STM32CubeProgrammer
        # cai rieng (thu muc STMicroelectronics) — Find-ToolExe quet ca hai + PATH.
        $prog = Find-ToolExe -Exe 'STM32_Programmer_CLI.exe'
        if (-not $prog) {
            throw "Khong tim thay STM32_Programmer_CLI.exe. Cai STM32CubeProgrammer/STM32CubeIDE " +
                  "hoac dat bien STM32CUBEPROG_PATH."
        }
        Write-Host "Programmer   : $prog" -ForegroundColor Cyan
        & $prog -c port=SWD -w $hex -rst
        if ($LASTEXITCODE -ne 0) { throw "Flash that bai (exit $LASTEXITCODE)" }
    }
}

Write-Host "`nHoan tat: $Task" -ForegroundColor Green
