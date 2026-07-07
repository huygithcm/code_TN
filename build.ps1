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

# --- 1. Dinh vi STM32CubeIDE ---------------------------------------------
function Find-CubeIdeRoot {
    $candidates = @()
    foreach ($base in @('C:\ST', 'C:\Program Files\STMicroelectronics', "$env:LOCALAPPDATA\Programs")) {
        if (Test-Path $base) {
            $candidates += Get-ChildItem $base -Directory -Filter 'STM32CubeIDE*' -ErrorAction SilentlyContinue
        }
    }
    # Lay ban moi nhat theo ten (vd STM32CubeIDE_2.1.1)
    $candidates | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}

$cubeIde = Find-CubeIdeRoot
if (-not $cubeIde) {
    throw "Khong tim thay STM32CubeIDE trong C:\ST hoac Program Files. " +
          "Cai dat hoac chinh duong dan trong build.ps1."
}
$plugins = Join-Path $cubeIde 'STM32CubeIDE\plugins'
Write-Host "STM32CubeIDE : $cubeIde" -ForegroundColor Cyan

# --- 2. Dinh vi gcc + make ------------------------------------------------
function Find-Tool($pattern, $exe) {
    $hit = Get-ChildItem $plugins -Directory -Filter $pattern -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending |
           ForEach-Object { Join-Path $_.FullName "tools\bin\$exe" } |
           Where-Object { Test-Path $_ } |
           Select-Object -First 1
    return $hit
}

$gccExe  = Find-Tool 'com.st.stm32cube.ide.mcu.externaltools.gnu-tools-for-stm32*' 'arm-none-eabi-gcc.exe'
$makeExe = Find-Tool 'com.st.stm32cube.ide.mcu.externaltools.make*'                'make.exe'

if (-not $gccExe)  { throw "Khong tim thay arm-none-eabi-gcc.exe trong plugins CubeIDE." }
if (-not $makeExe) { throw "Khong tim thay make.exe trong plugins CubeIDE." }

$gccBin  = Split-Path $gccExe
$makeBin = Split-Path $makeExe
$env:PATH = "$gccBin;$makeBin;$env:PATH"

Write-Host "GCC          : $gccExe" -ForegroundColor Cyan
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
        $prog = Find-Tool 'com.st.stm32cube.ide.mcu.externaltools.cubeprogrammer*' 'STM32_Programmer_CLI.exe'
        if (-not $prog) { throw "Khong tim thay STM32_Programmer_CLI.exe." }
        Write-Host "Programmer   : $prog" -ForegroundColor Cyan
        & $prog -c port=SWD -w $hex -rst
        if ($LASTEXITCODE -ne 0) { throw "Flash that bai (exit $LASTEXITCODE)" }
    }
}

Write-Host "`nHoan tat: $Task" -ForegroundColor Green
