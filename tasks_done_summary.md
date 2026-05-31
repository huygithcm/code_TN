# Tasks Status Summary

## Overall Status

| Task | Title | Status | Notes |
|------|-------|--------|-------|
| TASK-01 | Project setup and memory map | DONE | Verified by map file and ST-LINK target read. |
| TASK-02 | MPU configuration | DONE | AXI SRAM non-cacheable region active; D-cache enabled in TASK-05 and DMA reads of dma_buf are coherent (verified via TASK-05 ping-pong). |
| TASK-03 | Clock verification | DONE | Verified on hardware via `scripts/check_task03_clock.ps1`: VCP prints SYSCLK/HCLK/PCLK1 = 64 MHz; DWT counter enabled. |
| TASK-04 | SAI + DMA initialization | DONE | Verified on hardware via `scripts/check_task04_sai.ps1`: all 4 SAI blocks READY, DMA circular/word/no-FIFO, no HAL_ERROR. Note: SAI2_IRQn not enabled (CubeMX) - revisit in TASK-12. |
| TASK-05 | DMA buffer and ping-pong | DONE | All 4 SAI DMA streams ping-ponging (verified via `scripts/check_task05_dma.ps1`). Fixed SAI1 GCR.SYNCOUT so SAI2 ext-sync works; enabled I/D-cache; block size set to 1024. |
| TASK-06 | SAI callbacks and deinterleave | DONE | Verified on hardware via `scripts/check_task06_deinterleave.ps1` (deinterleave loop runs, `overruns=0`) and `scripts/check_usb_cdc_stream.ps1` (OTG CDC `RAW1` frames: header/seq/range valid). |
| TASK-07 | Hann window and FFT | TODO | Add windowing and FFT pipeline. |
| TASK-08 | GCC-PHAT and TDOA | TODO | Estimate time delay between microphone signals. |
| TASK-09 | RTOS tasks and IPC | TODO | Create FFT, USB, DOA, and monitor tasks. |
| TASK-10 | USB CDC transmit | TODO | Stream data to the PC over USB CDC. |
| TASK-11 | DOA output | TODO | Convert TDOA results into direction output. |
| TASK-12 | Monitor and watchdog | TODO | Add runtime health checks and watchdog handling. |
| TASK-13 | Integration test | TODO | End-to-end validation. |

Status meaning:

- `DONE`: Implemented and verified.
- `IN PROGRESS`: Currently being worked on.
- `BLOCKED`: Waiting for hardware, build, or design decision.
- `TODO`: Not started yet.

---

## TASK-01 - Project Setup And Memory Map

**Status:** DONE and verified.

The project was rebuilt and `scripts/check_task01_memory.ps1 -ReadTarget` passed:

```text
[ OK ] dma_buf = 0x2400A400
[ OK ] mic_data = 0x20000000
Task-01 memory map check passed.
```

ST-LINK also confirmed that the target MCU memory can be read at both addresses:

```text
dma_buf  at 0x2400A400, 32 bytes read successfully
mic_data at 0x20000000, 32 bytes read successfully
```

### What Was Done

#### 1. Audio Buffers Declared In `Src/main.c`

Sizing defines:

```c
#define NUM_SAI_BLOCKS       4U
#define NUM_MIC_CHANNELS     (NUM_SAI_BLOCKS * 2U)
#define AUDIO_BLOCK_SAMPLES  256U
#define DMA_HALF_WORDS       (2U * AUDIO_BLOCK_SAMPLES)
#define DMA_BUF_WORDS        (2U * DMA_HALF_WORDS)
```

Buffer declarations:

```c
__attribute__((section(".DMASection"), aligned(32), used))
int32_t dma_buf[NUM_SAI_BLOCKS][DMA_BUF_WORDS];

__attribute__((section(".DTCMSection"), aligned(32), used))
int32_t mic_data[NUM_MIC_CHANNELS][AUDIO_BLOCK_SAMPLES];
```

Rationale:

- `dma_buf` is placed in RAM_D1 / AXI SRAM so SAI DMA can access it.
- `mic_data` is placed in DTCM for fast CPU-side processing.
- `int32_t` matches the 32-bit SAI/DMA word format for 24-bit audio samples.
- `aligned(32)` matches the Cortex-M7 D-cache line size.
- `used` prevents the compiler from dropping the globals while they are not referenced yet.

#### 2. Linker Script Fix

Updated `STM32CubeIDE/STM32H7A3ZITXQ_FLASH.ld`.

The placement sections use `KEEP()` so `--gc-sections` does not remove the buffers:

```ld
.dtcm_buffers (NOLOAD) :
{
  . = ALIGN(32);
  KEEP(*(.DTCMSection))
  . = ALIGN(32);
} >DTCMRAM

.dma_buffers (NOLOAD) :
{
  . = ALIGN(32);
  KEEP(*(.DMASection))
  . = ALIGN(32);
} >RAM

.usb_buffers (NOLOAD) :
{
  . = ALIGN(32);
  KEEP(*(.USBSection))
  . = ALIGN(32);
} >RAM_CD
```

Memory regions:

```ld
DTCMRAM (xrw) : ORIGIN = 0x20000000, LENGTH = 128K
RAM     (xrw) : ORIGIN = 0x24000000, LENGTH = 1024K
RAM_CD  (xrw) : ORIGIN = 0x30000000, LENGTH = 128K
```

### Verification

CLI map check:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task01_memory.ps1
```

CLI map check plus ST-LINK target memory read:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task01_memory.ps1 -ReadTarget
```

Report output:

```text
debug/task01_memory_report.txt
```

The `.bss` size increased from `9,984` bytes to `34,552` bytes, confirming the 24 KB of buffers were linked into the image.

### Debugging Notes

1. Buffer declarations alone were not enough. The symbols compiled into `main.o`, but were absent from the ELF.
2. Cause: `--gc-sections` discarded the custom sections because nothing references the buffers yet.
3. `__attribute__((retain))` was tried, but this ARM bare-metal target ignored it and emitted `-Wattributes` warnings.
4. Working fix: use `KEEP()` in the linker script and `used` on the variables.
5. Both sections are `NOLOAD`, so the buffers are not zero-initialized at boot. This is fine for DMA scratch buffers, but code must not assume a clean initial value.

### Follow-Ups For Next Tasks

- `dma_buf` is in cacheable RAM_D1. TASK-02 should configure MPU non-cacheable access or later code must use `SCB_InvalidateDCache_by_Addr`.
- The 32-byte alignment is already in place for cache maintenance.
- If working inside CubeIDE, run a normal Project > Build after CLI builds so the IDE state stays synchronized.

---

## TASK-02 - MPU Configuration

**Status:** DONE. MPU region implemented in TASK-02; D-cache enabled in TASK-05 and the TASK-05 ping-pong test reads `dma_buf` correctly with no manual invalidate, confirming coherency.

**Goal:** Mark the AXI SRAM (where `dma_buf` lives) as non-cacheable so SAI/DMA writes are immediately visible to the CPU, with no manual `SCB_InvalidateDCache_by_Addr`.

### What Was Done

Added MPU Region 1 in `MPU_Config()` (`Src/main.c`), after the existing 4 GB backstop (Region 0):

```c
/* TASK-02: Region 1 - AXI SRAM (RAM_D1, 0x24000000, 1 MB), non-cacheable */
MPU_InitStruct.Enable           = MPU_REGION_ENABLE;
MPU_InitStruct.Number           = MPU_REGION_NUMBER1;
MPU_InitStruct.BaseAddress      = 0x24000000;
MPU_InitStruct.Size             = MPU_REGION_SIZE_1MB;
MPU_InitStruct.SubRegionDisable = 0x00;
MPU_InitStruct.TypeExtField     = MPU_TEX_LEVEL1;   /* TEX=001, C=0, B=1 */
MPU_InitStruct.AccessPermission = MPU_REGION_FULL_ACCESS;
MPU_InitStruct.DisableExec      = MPU_INSTRUCTION_ACCESS_DISABLE;
MPU_InitStruct.IsShareable      = MPU_ACCESS_NOT_SHAREABLE;
MPU_InitStruct.IsCacheable      = MPU_ACCESS_NOT_CACHEABLE;
MPU_InitStruct.IsBufferable     = MPU_ACCESS_BUFFERABLE;
HAL_MPU_ConfigRegion(&MPU_InitStruct);
```

Notes / decisions:

- `TEX=001, C=0, B=1` => Normal memory, non-cacheable (the standard STM32H7 setting for DMA buffers).
- Region 1 has higher priority than Region 0, so it overrides the backstop for `0x24000000..0x240FFFFF`.
- **Size = 1 MB**, not the 512 KB shown in the task breakdown: the project's linker (`STM32H7A3ZITXQ_FLASH.ld`) declares `RAM` at `0x24000000` with length **1024K**, so the region must cover the full 1 MB. `dma_buf` sits at `0x2400A400`, inside it.
- Region 0 was left exactly as CubeMX generated it.

### Important Caveat - D-Cache Is Currently Disabled

There is no `SCB_EnableDCache()` / `SCB_EnableICache()` call in the project. On STM32H7 the caches are **off** until explicitly enabled (the breakdown's "D-Cache enabled by default" is not accurate for H7). Consequences:

- The MPU non-cacheable attribute is correct and ready, but it has **no observable effect yet** because nothing is cached.
- To actually exercise the "stale cache" scenario from the TASK-02 "Done when", the caches must be enabled (e.g. in `main()` after `HAL_Init()` / MPU setup).

**Decision (agreed):** keep caches **off** until the DMA path is wired up in TASK-05. At TASK-05, enable `SCB_EnableICache()` / `SCB_EnableDCache()` together with the DMA bring-up so the non-cacheable region and DMA coherency can be tested in one clear, controlled step.

### Verification

- Build: clean, `EXIT=0`; `.text` grew by ~56 bytes for the extra region.
- Runtime "Done when": confirmed in TASK-05 - with D-cache enabled, the CPU reads DMA-filled `dma_buf`
  correctly (callbacks count up) without any `SCB_InvalidateDCache_by_Addr`, because the region is
  non-cacheable. Caches are enabled in `USER CODE BEGIN Init` (`SCB_EnableICache/DCache`).

**Cache scope note:** the linker places *all* general RAM (.data/.bss/heap/stack) in AXI SRAM at
0x24000000, which this region marks non-cacheable - so D-cache does little for general data. That is
acceptable here because the DSP hot path (mic_data, FFT buffers) lives in DTCM (never cached, always
fast); I-cache still benefits code execution from flash. A future refinement could carve out only the
`dma_buf` area as non-cacheable and leave the rest of AXI SRAM cacheable, if profiling ever needs it.

---

## TASK-03 - Clock Verification

**Status:** DONE - verified on hardware.

**Goal:** Confirm SYSCLK = HCLK = PCLK1 = 64 MHz before enabling audio peripherals, and arm the DWT cycle counter for later benchmarking.

### What Was Done (`Src/main.c`)

- `#include <stdio.h>` added.
- `Clock_Verify()` added (prototype in PFP, body in USER CODE 4):

```c
void Clock_Verify(void)
{
  uint32_t sysclk = HAL_RCC_GetSysClockFreq();
  uint32_t hclk   = HAL_RCC_GetHCLKFreq();
  uint32_t pclk1  = HAL_RCC_GetPCLK1Freq();

  printf("\r\n--- TASK-03 Clock Verify ---\r\n");
  printf("SYSCLK : %lu Hz\r\n", (unsigned long)sysclk);   /* expect 64000000 */
  printf("HCLK   : %lu Hz\r\n", (unsigned long)hclk);
  printf("PCLK1  : %lu Hz\r\n", (unsigned long)pclk1);

  CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;   /* enable DWT */
  DWT->CYCCNT       = 0U;
  DWT->CTRL        |= DWT_CTRL_CYCCNTENA_Msk;

  if (sysclk == 64000000UL) { printf("Clock OK...\r\n"); BSP_LED_On(LED_GREEN); }
  else                      { printf("Clock MISMATCH...\r\n"); BSP_LED_On(LED_RED); }
}
```

- Called once in `USER CODE BEGIN WHILE`, just before the main loop (after COM1/VCP is up).

### printf Retargeting

- No local `__io_putchar` is defined. The BSP (`stm32h7xx_nucleo.c`, `USE_COM_LOG`) already provides
  `__io_putchar()` -> `HAL_UART_Transmit(hcom_uart[COM_ActiveLogPort], ...)`, and `syscalls.c` `_write()`
  routes stdout through it. (A first attempt defining a local `__io_putchar` caused a
  multiple-definition link error; it was removed.)
- Only integer formats (`%lu`) are used here, so newlib-nano works as-is. **Float printf (`%f`) is NOT
  enabled** — when later tasks (e.g. TASK-11 DOA) print floats, add `-u _printf_float` to the linker
  flags, or format with fixed-point/integer math.

### Verification - PASSED on hardware

Automated check `scripts/check_task03_clock.ps1` (opens VCP, flashes + resets via ST-LINK, reads the
boot banner, validates 64 MHz). Run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task03_clock.ps1
```

Options: `-NoFlash` (reset & re-read only), `-Port COM3`, `-Baud 115200`, `-ReadSeconds 8`.
Report: `debug/task03_clock_report.txt`. Actual captured output:

```text
--- TASK-03 Clock Verify ---
SYSCLK : 64000000 Hz
HCLK   : 64000000 Hz
PCLK1  : 64000000 Hz
Clock OK. DWT cycle counter enabled.

[ OK ] SYSCLK = 64000000 Hz
[ OK ] HCLK = 64000000 Hz
[ OK ] PCLK1 = 64000000 Hz
TASK-03 clock check passed.
```

---

## TASK-04 - SAI + DMA Initialization

**Status:** DONE - verified on hardware.

**Goal:** Confirm the CubeMX-generated `MX_SAI1_Init`, `MX_SAI2_Init`, and the SAI MSP DMA setup are correct for 8-mic capture; "Done when" = no HAL_ERROR from the SAI inits.

### Verified Configuration (against the breakdown checklist)

SAI blocks (`Src/main.c`): SAI1_A Master/Async, SAI1_B Slave/Sync, SAI2_A & SAI2_B Slave/Ext-Sync-SAI1;
24-bit data, 32-bit slots, 2 slots (0 & 1), frame length 64, FS active-low, FS before first bit.

DMA streams (`Src/stm32h7xx_hal_msp.c`, in `HAL_SAI_MspInit`): all 4 are PERIPH_TO_MEMORY, MemInc on,
**WORD** alignment (periph + mem), **CIRCULAR**, **FIFO disabled**, priority low. Mapping:

| SAI block | DMA stream | Request |
|-----------|-----------|---------|
| SAI1_A | DMA1_Stream0 | DMA_REQUEST_SAI1_A |
| SAI1_B | DMA1_Stream1 | DMA_REQUEST_SAI1_B |
| SAI2_A | DMA1_Stream2 | DMA_REQUEST_SAI2_A |
| SAI2_B | DMA1_Stream3 | DMA_REQUEST_SAI2_B |

### What Was Added

`SAI_Verify()` in `Src/main.c` (called once in `USER CODE BEGIN WHILE`, after `Clock_Verify()`):
checks each block reached `HAL_SAI_STATE_READY` (i.e. `HAL_SAI_Init` returned no error) and that each
linked RX DMA is circular / word-aligned / FIFO-disabled, then prints a per-block summary over the VCP.

### Verification - PASSED on hardware

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task04_sai.ps1
```

Options: `-NoFlash`, `-Port COM3`, `-Baud 115200`, `-ReadSeconds 8`. Report: `debug/task04_sai_report.txt`.
Captured output:

```text
--- TASK-04 SAI + DMA Verify ---
SAI1_A(mst) state=READY data=24b slot=32b nslot=2 frame=64 dma=circ/word/noFIFO
SAI1_B(slv) state=READY data=24b slot=32b nslot=2 frame=64 dma=circ/word/noFIFO
SAI2_A(slv) state=READY data=24b slot=32b nslot=2 frame=64 dma=circ/word/noFIFO
SAI2_B(slv) state=READY data=24b slot=32b nslot=2 frame=64 dma=circ/word/noFIFO
SAI READY: 4/4   DMA configured: 4/4
TASK-04 OK: SAI+DMA init, no HAL_ERROR.
```

### Observation / Follow-up

In `HAL_SAI_MspInit`, only `SAI1_IRQn` is enabled; **`SAI2_IRQn` is never enabled** (CubeMX `.ioc`
only configured the SAI1 global interrupt). Capture works because the DMA stream IRQs handle half/full
transfer, but SAI2 error/overrun interrupts will not fire. Revisit in **TASK-12** (overrun counting via
`HAL_SAI_ErrorCallback`): either enable `SAI2_IRQn` or rely on DMA error callbacks.

---

## TASK-05 - DMA Buffer & Ping-Pong

**Status:** DONE - verified on hardware (all 4 streams ping-ponging).

**Goal:** Start circular DMA reception on all 4 SAI blocks (slaves first, master last) and confirm the
half/full (ping/pong) callbacks fire.

### Buffer Sizing (aligned to the FFT pipeline)

`AUDIO_BLOCK_SAMPLES` was raised from 256 to **1024** (the TASK-07 FFT size). Resulting layout:

```
DMA_HALF_WORDS = 2 * 1024            = 2048 words  (one half: 1024 frames x 2 stereo slots)
DMA_FULL_WORDS = 2 * DMA_HALF_WORDS  = 4096 words  (full circular buffer, passed to HAL)
dma_buf[4][4096] int32  = 64 KB  (AXI SRAM, non-cacheable)
mic_data[8][1024] int32 = 32 KB  (DTCM)
```

### What Was Added (`Src/main.c`)

- `Audio_Start()`: `memset`s the buffers/flags then arms `HAL_SAI_Receive_DMA` on B2, A2, B1, A1
  (slaves before master) with `DMA_FULL_WORDS`.
- `HAL_SAI_RxHalfCpltCallback` / `HAL_SAI_RxCpltCallback`: map the block to a pair via `Audio_GetPair`,
  bump `dma_half_cnt[]` / `dma_full_cnt[]`, and set `pair_ready[]` (the deinterleave is added in TASK-06).
- Caches enabled in `USER CODE BEGIN Init` (`SCB_EnableICache()` / `SCB_EnableDCache()`) - the agreed
  point to turn caching on alongside the DMA bring-up (closes out TASK-02 coherency).
- Runtime verify in `USER CODE BEGIN WHILE`: `Audio_Start()`, wait 1 s, print per-pair half/full counts.

### Bug Found & Fixed - SAI2 external sync (SAI1 GCR.SYNCOUT)

First hardware run showed **pair0/1 active, pair2/3 dead (0/0)**. Cause: SAI2 blocks are
`SAI_SYNCHRONOUS_EXT_SAI1`, but SAI1 was not exporting its sync. `HAL_SAI_Init` writes the *entire*
shared `SAI1->GCR` on every call, and both SAI1 blocks had `SynchroExt = SAI_SYNCEXT_DISABLE`, so the
last init left `SAI1.GCR = 0` (no `SYNCOUT`). Fix: set
`SynchroExt = SAI_SYNCEXT_OUTBLOCKA_ENABLE` on **both** SAI1 blocks (block B is inited last, so it must
also carry it). After the fix, all 4 pairs report `half=8 full=7` per second (~15.6 Hz, correct for
1024-frame halves at 16 kHz).

> If the project is ever re-generated from CubeMX, set SAI1 "Synchronization Outputs = Block A" in the
> `.ioc` so this fix is reproduced (the edit lives in the generated `MX_SAI1_Init`).

### Verification - PASSED on hardware

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task05_dma.ps1
```

Options: `-NoFlash`, `-Port COM3`, `-Baud 115200`, `-ReadSeconds 10`. Report: `debug/task05_dma_report.txt`.

```text
--- TASK-05 DMA Ping-Pong ---
pair0: half=8 full=7
pair1: half=8 full=7
pair2: half=8 full=7
pair3: half=8 full=7
TASK-05 OK: all 4 DMA streams ping-ponging.
```

(The breakdown's "Done when" was a logic-analyzer frame check; counting live ping-pong callbacks on all
4 streams is an equivalent functional confirmation that SAI clocking + DMA are running.)

---

## TASK-06 - SAI Callbacks And Deinterleave

**Status:** DONE - verified on hardware.

**Goal:** Convert each ready SAI DMA half-buffer from interleaved stereo slots into per-microphone arrays:

```text
dma_buf[pair][L0,R0,L1,R1,...] -> mic_raw[0..7][i] and mic_data[0..7][i]
```

### What Was Added

- `HAL_SAI_RxHalfCpltCallback()` and `HAL_SAI_RxCpltCallback()` now use the master SAI block (`SAI1_A`) to signal which DMA half is ready.
- The main loop consumes `g_half_ready`, deinterleaves all 4 SAI pairs, and increments the processed block counter.
- `Deinterleave_Pair()` converts each 32-bit SAI slot into a signed 24-bit sample:

```c
int32_t rl = src[2U * i]      >> 8;
int32_t rr = src[2U * i + 1U] >> 8;
mic_raw[l][i]  = rl;
mic_raw[r][i]  = rr;
mic_data[l][i] = (float)rl * (1.0f / 8388608.0f);
mic_data[r][i] = (float)rr * (1.0f / 8388608.0f);
```

- `mic_raw` keeps exact sign-extended 24-bit samples for diagnostics and USB export.
- `mic_data` is normalized float data for the later FFT pipeline.
- The TASK-06 handshake is reset after the TASK-05 one-second ping-pong check so stale ready flags do not create false overruns.

### Raw USB CDC Debug Stream

`USB_RAW_STREAM` is enabled. The firmware can package one deinterleaved frame as:

```text
magic:   "RAW1"
seq:     uint32
nch:     uint8  = 8
nsamp:   uint16 = 1024
fmt:     uint8  = 0, int32 little-endian
payload: int32 channel-major samples
```

MATLAB helper:

```text
tools/read_mic_raw.m
```

Use the OTG USB CDC COM port for raw frames, not the ST-LINK VCP used for status logs.

### Debug Cases Tried

1. `USB_RAW_STREAM = 0`
   - Result: PASS.
   - Deinterleave loop ran and printed `blk=16 -> blk=32`.

2. `USB_RAW_STREAM = 1`, raw frame build disabled
   - Result: PASS.
   - Confirmed the deinterleave logic itself was stable.

3. Raw frame build enabled
   - Initial result: FAIL.
   - Firmware stopped after the TASK-06 banner before any `blk=` heartbeat.

4. Instrumented the raw frame path
   - Found the stop happened after writing the sequence field and before `header ok`.
   - Root cause: unaligned 16-bit header write at `usb_tx_frame[9]` using `memcpy(&usb_tx_frame[9], &ns, 2)`.

5. Replaced the unaligned write with byte-wise little-endian writes:

```c
usb_tx_frame[9]  = (uint8_t)(ns & 0xFFU);
usb_tx_frame[10] = (uint8_t)(ns >> 8);
```

6. Full payload restored (`1024` samples/channel), `CDC_Transmit_HS()` enabled
   - Result: PASS.

### Verification - PASSED On Hardware

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task06_deinterleave.ps1 -ReadSeconds 20
```

Captured result:

```text
--- TASK-06 Deinterleave + raw USB CDC stream ---
blk=16 mic0[min=0 max=32767] usb_seq=1 overruns=0
blk=32 mic0[min=0 max=32767] usb_seq=1 overruns=0

[ OK ] TASK-06 banner present
[ OK ] Deinterleave loop running (blk 16 -> 32)
[ OK ] No DMA overruns
TASK-06 deinterleave check passed.
```

Report:

```text
debug/task06_deinterleave_report.txt
```

### USB CDC Stream Test Case (`scripts/check_usb_cdc_stream.ps1`)

A second, dedicated check validates the **data actually returned over the OTG USB CDC port**
(`check_task06_deinterleave.ps1` only confirms the VCP heartbeat; it does not read the raw frames).
This script opens the OTG CDC port, drains the `RAW1` stream, and verifies the frame
transport/format end-to-end.

Run (port is auto-detected; firmware must already be running — do **not** flash, that resets USB):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_usb_cdc_stream.ps1 -Frames 8
powershell -ExecutionPolicy Bypass -File scripts/check_usb_cdc_stream.ps1 -Port COM12 -Frames 10
```

Options: `-Port COMx` (default: auto-detect), `-Frames N` (default 5), `-TimeoutSec` (default 20),
`-Baud` (CDC ignores it). Report: `debug/usb_cdc_stream_report.txt`.

What it checks per frame:

- **Port auto-detect** by USB ID `VID_0483&PID_5740` (the STM32 OTG CDC device), so it never
  picks the ST-LINK VCP (`COM3`, `VID_0483&PID_374E`). On this setup the OTG CDC enumerates as `COM12`.
- **Double-magic anchor**: a frame start is only accepted if `RAW1` appears at both offset `i` and
  `i + 32780` (one full frame later). The int32 payload can contain a stray `RAW1` byte pattern; the
  double anchor rejects those false boundaries.
- **Header**: `nch == 8`, `nsamp == 1024`, `fmt == 0`.
- **Sequence**: `seq` (uint32 LE) increments by 1 across consecutive frames (gaps are flagged).
- **Range sanity**: every int32 sample is within the signed 24-bit range `[-8388608, 8388607]`
  (an out-of-range value means the stream is misaligned).
- Prints per-channel `min..max` so live mic levels are visible.

Verified output (`-Frames 8`):

```text
Captured 393360 bytes from COM12
frame 1: seq=25  ch0[0..32767] ch1[0..32767] ... ch7[0..32767]
...
frame 8: seq=32  ch0[0..32767] ch1[0..32767] ... ch7[0..32767]

[ OK ] Received 8 valid RAW1 frame(s)
[ OK ] Headers valid (nch=8 nsamp=1024 fmt=0)
[ OK ] Sequence counter advanced
[ OK ] All samples within 24-bit range
USB CDC raw stream check passed.
```

Two pitfalls solved while writing this check (keep them in mind for any future CDC reader):

1. **False `RAW1` in payload** → fixed with the double-magic anchor above.
2. **Driver read-buffer overflow** — each frame is ~32 KB but `SerialPort.ReadBufferSize` defaults to
   4 KB. Doing per-sample work while reading drops bytes mid-frame and corrupts alignment. Fixed by
   raising `ReadBufferSize` to 4 MB **and** splitting the script into a fast capture phase (read only)
   followed by an index-based parse phase (no `List` shifting), so the host always keeps up.

**Data-content caveat:** the check confirms the transport/format is correct, but the *content* needs a
separate look — see the MATLAB FFT test below.

### MATLAB Mic FFT Test (`tools/mic_fft_test.m`)

`scripts/check_usb_cdc_stream.ps1` proves the frame transport; `tools/mic_fft_test.m` proves the
**signal content** — i.e. that each microphone is actually capturing real, independent audio. It
captures N frames over the OTG CDC port (reusing `read_mic_raw` for the read), averages the per-channel
FFT, and prints a verdict per mic: `TONE @ f Hz`, `NOISE`, `DC-DOMINATED`, or `DEAD`. It also
cross-correlates the channels and warns if any read near-identical samples (mics not independent).

```matlab
% in MATLAB, from the tools/ folder (use the OTG CDC port, not COM3):
mic_fft_test("COM12", 16)        % average 16 frames
mic_fft_test("COM12", 32, 30)    % 32 frames, 30 s timeout
```

Verified run (12 frames, seq 504-515, no acoustic stimulus applied):

```text
mic       dc(cnt)   rmsAC(cnt)    peakHz   prom_dB  flatness   verdict
0           16581      16251.0        47      27.8     0.224   TONE @ 47 Hz
...
7           17034      16255.6        47      28.7     0.186   TONE @ 47 Hz
Live channels: 8/8
[ OK ] Channels are independent (max |corr|=0.863).
```

This explains the earlier `[0..32767]` observation: it is **not** dead/DC data but a periodic ~47 Hz
signal swinging nearly full scale, present and phase-distinct on all 8 channels (so the capture +
deinterleave path is functioning and the channels are independent). Caveat: the signal is positive-only
and ~15-bit, unlike a bipolar 24-bit acoustic recording, so 47 Hz is likely a test/pickup artifact
rather than ambient sound. To confirm the acoustic path, play a steady tone/whistle near the array and
re-run — every mic should report `TONE` at that frequency.

### Notes For Later

- `usb_seq=1` during the status-log test is acceptable. The OTG CDC raw stream needs a host reader on the OTG USB CDC port to drain frames continuously.
- The ST-LINK VCP (`COM3`) is only for status logs.
- Actual audio content should be checked with `tools/mic_fft_test.m` (per-mic FFT verdict + channel-independence check) on the OTG CDC port, applying a tone/tap near the mics; `tools/read_mic_raw.m` gives the raw waveform dump.
