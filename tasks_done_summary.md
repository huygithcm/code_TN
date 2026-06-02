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
| TASK-07 | Hann window and FFT | DONE | Verified on hardware via `scripts/check_task07_fft.ps1`: CMSIS-DSP 1024-pt rfft on all 8 mics; self-test 1 kHz -> peak bin 64; ~9.2 ms/8-mic pass; overruns=0. |
| TASK-08 | GCC-PHAT and TDOA | DONE | Verified on hardware via `scripts/check_task08_gccphat.ps1`: GCC-PHAT self-test (synthetic 5-sample delay -> lag 5); live mic0-vs-mic1..7 lags computed each heartbeat; overruns=0. |
| TASK-09 | RTOS tasks and IPC | DONE | Verified on hardware via `scripts/check_task09_rtos.ps1`: FreeRTOS task list shows FFT/USB/DOA/Monitor tasks, notifications/queue run, monitor reports blocks advancing with `overruns=0`. |
| TASK-10 | USB CDC transmit | DONE | Verified on hardware via `scripts/check_task10_usb_cdc.ps1`: 948 RAW1 frames in 60 s (~15.8 fps), seq 1..948 with 0 gaps, samples in 24-bit range. Device-side `g_usb_drops` + `[USB]` monitor line added. |
| TASK-11 | DOA output | DONE | Verified on hardware via `scripts/check_task11_doa.ps1`: planar least-squares DOA from the 7 sub-sample TDOAs; solver self-test az 30->30; live `DOA seq= az= el=` on COM3 + LED; overruns=0. Fixed a latent bug: defaultTask stack overflow (USB init) was zeroing the result_queue, breaking FFT->DOA IPC since TASK-09. |
| TASK-12 | Monitor and watchdog | DONE | Verified on hardware via `scripts/check_task12_monitor.ps1`: IWDG (fed only while the pipeline advances), `HAL_SAI_ErrorCallback` + `SAI2_IRQn` enabled (closes TASK-04 follow-up), stack high-water all >10%, 60 s overruns=0/saiErr=0. IT-07 demonstrated: stalling the pipeline triggers an IWDG reset (`last reset: IWDG`). |
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

Verified output (`-Frames 4`):

```text
Captured 262240 bytes from COM12
frame 1: seq=94  ch0[-8375..7389] ch1[-7935..7881] ch2[-9755..9865] ... ch7[-8271..8941]
frame 2: seq=95  ch0[-7894..5190] ch1[-6361..6394] ch2[-8239..8420] ... ch7[-5843..9847]
...
[ OK ] Received 4 valid RAW1 frame(s)
[ OK ] Headers valid (nch=8 nsamp=1024 fmt=0)
[ OK ] Sequence counter advanced
[ OK ] All samples within 24-bit range
USB CDC raw stream check passed.
```

The per-channel min/max are bipolar and differ across channels and frames — real, independent mic audio
(see the MATLAB FFT test below for the full content analysis).

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

Verified run (16 frames, seq 116-131, no acoustic stimulus applied):

```text
mic       dc(cnt)   rmsAC(cnt)    peakHz   prom_dB  flatness   verdict
0              12       2694.4        47      40.0     0.031   TONE @ 47 Hz
2             -31       3209.1        47      41.5     0.027   TONE @ 47 Hz
...
7             -13       2909.0        47      40.2     0.026   TONE @ 47 Hz
Live channels: 8/8
[ OK ] Channels are independent (max |corr|=0.971).
```

**Result: the microphones read real, bipolar 24-bit audio.** DC ≈ 0 on every channel (±30 counts),
AC RMS ~2.5-3.2 k counts, and each channel's min/max differs frame to frame — genuine, independent
capture through the full SAI → DMA → deinterleave → USB path. The dominant ~47 Hz tone (prominence
~40 dB, flatness ~0.03) is almost certainly **50 Hz mains hum**: with a 15.625 Hz FFT bin, 50 Hz
leaks onto bin 3 = 46.875 Hz, and it is common-mode (highly correlated across channels), as expected
for electrical pickup rather than sound. To confirm the acoustic path, play a steady tone/whistle near
the array and re-run — every mic should additionally report `TONE` at that frequency.

> **Correction:** an earlier draft of this section reported all channels as a positive-only
> `[0..32767]` ~47 Hz "test artifact". That was wrong — it came from frame **misalignment** in the
> capture (the old single-magic `read_mic_raw` locked onto a stray `RAW1` byte pattern inside the int32
> payload, producing a +16384 DC offset and clipped 15-bit values). After hardening `read_mic_raw.m`
> with the double-magic anchor, the same hardware reads clean bipolar audio (DC ≈ 0). See
> `debug/bugs_encountered.md` BUG-02.

### Notes For Later

- `usb_seq=1` during the status-log test is acceptable. The OTG CDC raw stream needs a host reader on the OTG USB CDC port to drain frames continuously.
- The ST-LINK VCP (`COM3`) is only for status logs.
- Actual audio content should be checked with `tools/mic_fft_test.m` (per-mic FFT verdict + channel-independence check) on the OTG CDC port, applying a tone/tap near the mics; `tools/read_mic_raw.m` gives the raw waveform dump.

---

## TASK-07 - Hann Window & FFT

**Status:** DONE - verified on hardware.

**Goal:** Apply a Hann window and compute a 1024-point real FFT for all 8 mics using CMSIS-DSP;
"Done when" = a 1 kHz tone produces a magnitude peak at bin 64 (`1000 / 16000 x 1024`).

### CMSIS-DSP Build Integration (from source, no prebuilt lib)

The pack ships CMSIS-DSP **source** under `Drivers/CMSIS/DSP/` but no prebuilt `libarm_cortexM7*`.
The five "all-in-one" aggregate units we need are compiled at `-O2` and linked in:

| Aggregate unit | Provides |
|----------------|----------|
| `TransformFunctions.c` | `arm_rfft_fast_init_f32`, `arm_rfft_fast_f32`, `arm_cfft_f32` |
| `CommonTables.c` | twiddle factors / bit-reversal tables (`arm_cfft_sR_f32_len512`, ...) |
| `BasicMathFunctions.c` | `arm_mult_f32` (windowing) |
| `ComplexMathFunctions.c` | `arm_cmplx_mag_f32` (and `arm_cmplx_mult_cmplx_f32` for TASK-08) |
| `StatisticsFunctions.c` | `arm_max_f32` (peak find, TASK-08) |

Wiring (CLI makefile build):

- New `STM32CubeIDE/Debug/Drivers/CMSIS/DSP/subdir.mk` compiles the five units (own `-O2` rule).
- `STM32CubeIDE/Debug/makefile` gets `-include Drivers/CMSIS/DSP/subdir.mk`.
- `STM32CubeIDE/Debug/objects.list` lists the five `.o` so they are linked.
- The DSP include path `-I../../Drivers/CMSIS/DSP/Include` was already present on the app compiles.
- Modern CMSIS-DSP auto-detects the Cortex-M7 + FPv5 core from `-mcpu`/`-mfpu`; **no `ARM_MATH_CM7`
  define needed**. `arm_sin_f32` was avoided (would pull in `FastMathFunctions`); the self-test uses
  libm `sinf` instead.

> The five DSP aggregate units are now registered as **linked source files** in the project model
> (`STM32CubeIDE/.project`), and a per-folder `Drivers/CMSIS/DSP` override in `STM32CubeIDE/.cproject`
> forces them to `-O2` (Debug default is `-O0`) while carrying the full include paths + defines. So
> STM32CubeIDE (GUI or headless) now regenerates `Debug/Drivers/CMSIS/DSP/subdir.mk` and links the DSP
> objects automatically — no manual `subdir.mk` / `objects.list` / `makefile` editing is needed anymore.
> (Verified via headless `org.eclipse.cdt.managedbuilder.core.headlessbuild -cleanBuild`: 0 errors,
> ELF text=179356.) `DSP/PrivateInclude` was added to the C-compiler include paths for both Debug and
> Release because some component `.c` files pulled in by the aggregates need it.

### What Was Added (`Src/main.c`, guarded by `FFT_ENABLE`)

- DTCM buffers: `hann_window[1024]`, `fft_win[1024]`, `fft_cplx[1024]`, `fft_mag[8][512]`.
- `FFT_Init()` - `arm_rfft_fast_init_f32(&fft_inst, 1024)` + pre-computes the Hann window.
- `FFT_ProcessAll()` - per mic: `arm_mult_f32` (window) -> `arm_rfft_fast_f32` (forward) ->
  `arm_cmplx_mag_f32` (512 bins); times the whole 8-mic pass with the DWT cycle counter (`g_fft_us`).
- `FFT_PeakBin()` - dominant bin, skipping DC.
- `FFT_SelfTest()` - synthesizes a clean 1 kHz sine, runs the pipeline, checks the peak bin (proves
  the path independent of the mics).
- Wired into the capture loop: `FFT_Init()`/`FFT_SelfTest()` before the loop; `FFT_ProcessAll()` plus a
  per-mic peak-Hz print on the ~1 Hz heartbeat. (TASK-09 will move the FFT into its own RTOS task
  running every block.)

Note: `arm_rfft_fast_f32` packs DC in `[0]` and Nyquist in `[1]`, so `fft_mag[m][0]` is
`sqrt(DC^2 + Nyq^2)`; peak detection skips bin 0 anyway.

### Verification - PASSED on hardware

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task07_fft.ps1
```

Options: `-NoFlash`, `-Port COM3`, `-Baud 115200`, `-ReadSeconds 12`. Report: `debug/task07_fft_report.txt`.

```text
--- TASK-07 Hann + FFT ---
self-test: 1000 Hz -> peak bin 64 (expected 64) mag=255
TASK-07 self-test OK (peak within +/-1 bin).
FFT 9230us peakHz[46 46 46 46 93 93 46 46]

[ OK ] FFT self-test peak bin 64 (expected 64)
[ OK ] Live 8-mic FFT runs: 9230 us/pass, peakHz = [46 46 46 46 93 93 46 46]
TASK-07 FFT check passed.
```

- **Self-test:** 1 kHz -> peak bin **64**, exactly as specified.
- **Timing:** ~**9.2 ms** for all 8 mics (~1.15 ms / 1024-pt rfft+mag), well under the 20 ms budget;
  `overruns=0` with the FFT running in the loop.
- **Live mics:** dominant bin tracks the ~46 Hz (50 Hz mains) hum seen in TASK-06, and jumps to higher
  bins on taps/voice - the FFT responds to real input.

---

## TASK-08 - GCC-PHAT & TDOA

**Status:** DONE - verified on hardware.

**Goal:** Estimate the time delay (TDOA) between mic pairs with GCC-PHAT; "Done when" = a synthetic
5-sample delay between two signals is recovered as lag 5 +/- 1.

### What Was Added (`Src/main.c`, guarded by `GCC_ENABLE`, reuses the TASK-07 `fft_inst`)

- DTCM scratch: `gcc_a`, `gcc_b` (packed spectra), `gcc_r` (PHAT cross-spectrum), `gcc_corr` (correlation).
- `int32_t GCC_PHAT(const float *a, const float *b)`:
  1. forward rfft of both inputs (from the `fft_win` scratch copy - see the gotcha below);
  2. cross-spectrum `conj(Xa) * Xb` handling the packed DC/Nyquist terms;
  3. PHAT whitening: divide each bin by its magnitude (floored at 1e-9);
  4. inverse rfft -> cross-correlation; `arm_max_f32` peak -> lag, unwrapped to +/- N/2.
  - **Sign convention:** positive lag means signal reaches mic *a* before mic *b* (b is the delayed
    copy). This drove the `conj(Xa)*Xb` choice (the other order returns -lag).
- `GCC_SelfTest()`: builds a broadband pseudo-random reference and a copy **circularly** delayed by 5
  samples, then checks the recovered lag. (Broadband, not a tone - PHAT whitening needs energy across
  all bins, so a pure sine is a poor test.)
- `GCC_ProcessPairs()`: live TDOA for mic0 vs mic1..7 from `mic_data`, timed with the DWT counter.
- Wired into the loop: `GCC_SelfTest()` once before the loop; `GCC_ProcessPairs()` + a lag print on the
  ~1 Hz heartbeat.

> **Gotcha (cost a sign bug + a corruption trap):** `arm_rfft_fast_f32` *forward* runs the cfft
> **in-place on its input buffer**, so passing `mic_data[m]` directly would corrupt it. `GCC_PHAT`
> always `memcpy`s the input into `fft_win` first and FFTs from there. (Same reason `FFT_ProcessAll`
> FFTs the windowed copy, not `mic_data`.)

### Verification - PASSED on hardware

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task08_gccphat.ps1
```

Options: `-NoFlash`, `-Port COM3`, `-Baud 115200`, `-ReadSeconds 14`. Report: `debug/task08_gccphat_report.txt`.

```text
--- TASK-08 GCC-PHAT / TDOA ---
self-test: delay 5 -> lag 5 (expected 5)
TASK-08 self-test OK (lag within +/-1 sample).
GCC 41732us lag0x[-1 0 -1 1 1 1 0]

[ OK ] GCC-PHAT self-test lag=5 (expected 5)
[ OK ] Live GCC-PHAT runs: 41732 us, mic0-vs-mic1..7 lags = [-1 0 -1 1 1 1 0]
TASK-08 GCC-PHAT check passed.
```

- **Self-test:** synthetic 5-sample delay -> lag **5**, exactly as specified.
- **Live mics:** mic0-vs-mic{1..7} lags are small (+/-1 sample). Expected here: the dominant signal is
  common-mode ~50 Hz mains hum, which has ~0 inter-mic delay; a real off-axis acoustic source is
  needed to see larger, physically meaningful TDOAs (TASK-11/13).
- **Timing:** ~41.7 ms for 7 pairs (21 FFTs + the PHAT loops). The FFTs are `-O2` (DSP lib) but the
  per-bin cross-spectrum/`sqrtf` loop is in `main.c` at `-O0`; still `overruns=0` because one heavy
  heartbeat iteration (~51 ms incl. FFT) stays under the 64 ms half-buffer period. TASK-09 will move
  this into a dedicated RTOS task and can cache mic0's spectrum / compute all 28 pairs off the hot path.

---

## TASK-09 - RTOS Tasks & IPC

**Status:** DONE - implemented and verified on hardware.

**Goal:** Run the capture + DSP pipeline under FreeRTOS with FFT, USB, DOA and Monitor tasks, using
task notifications from the SAI DMA callback and a queue for TDOA results.

### What Was Done

- FreeRTOS CMSIS_V2 is enabled, with HAL timebase moved to TIM6.
- DMA1_Stream0..3 and SAI1 IRQ priorities are set to 5 so `xTaskNotifyFromISR()` is legal; OTG_HS is
  priority 6.
- `result_queue` is created as 4 items of `tdoa_result_t`, not the CubeMX placeholder `uint16_t`.
- Task stacks were raised to the project budget:

| Task | Priority | Stack |
|------|----------|-------|
| FFT_Task | osPriorityHigh | 2048 words |
| USB_Task | osPriorityRealtime | 512 words |
| DOA_Task | osPriorityAboveNormal | 512 words |
| Monitor_Task | osPriorityLow | 512 words |

- `Pipeline_InitOnce()` now runs inside `FFT_Task`, so clock/DWT verify, SAI verify, FFT/GCC self-tests
  and `Audio_Start()` are no longer stranded after `osKernelStart()`.
- SAI master-block half/full callbacks notify `FFT_Task` from ISR.
- `FFT_Task` deinterleaves one ready half-buffer, runs FFT and GCC-PHAT, sends a `tdoa_result_t` to
  `DOA_Task`, and snapshots raw samples for USB.
- `USB_Task` waits on `FLAG_USB` and sends the RAW1 CDC frame when the USB device is ready.
- `DOA_Task` drains `result_queue` and prints live lag vectors as the TASK-09 IPC proof; TASK-11 will
  replace this with angle estimation.
- `Monitor_Task` prints `vTaskList()` once and then periodic runtime health.

### Verification - PASSED on hardware

Automated check:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task09_rtos.ps1 -NoFlash
```

Options: `-Port COM3`, `-Baud 115200`, `-ReadSeconds 16`, omit `-NoFlash` to flash the current ELF
before checking. Report: `debug/task09_rtos_report.txt`.

Captured boot excerpt:

```text
--- TASK-09 vTaskList ---
Name          State Prio Stack Num
Monitor_Task    X   8   455   5
IDLE            R   0   107   6
defaultTask     B   24  0     1
Tmr Svc         B   2   213   7
USB_Task        S   48  452   3
FFT_Task        S   40  1874  2
DOA_Task        B   32  452   4

[MON] blocks=24 overruns=0 fft=7691us gcc=25586us heapFree=17136
```

Pass criteria:

- `TASK-07 self-test OK` and `TASK-08 self-test OK` still appear after RTOS startup.
- `vTaskList()` includes `FFT_Task`, `USB_Task`, `DOA_Task` and `Monitor_Task`.
- Monitor heartbeat appears with `blocks > 0`, `overruns=0`, and nonzero free heap.
- FFT+GCC time is comfortably below the 64 ms half-buffer period.

Result:

```text
[ OK ] TASK-07 FFT self-test still passes under RTOS
[ OK ] TASK-08 GCC-PHAT self-test still passes under RTOS
[ OK ] vTaskList printed
[ OK ] FFT_Task present
[ OK ] USB_Task present
[ OK ] DOA_Task present
[ OK ] Monitor_Task present
[ OK ] Monitor line seen: blocks=24 overruns=0 fft=7691us gcc=25586us heapFree=17136
TASK-09 RTOS check passed.
```

---

## TASK-10 - USB CDC Transmit

**Status:** DONE - verified on hardware.

**Goal:** Stream the 8-channel capture to the PC over USB CDC with no dropped frames;
"Done when" = the host receives frames with no sequence gap for 60 s.

### What Was Done

The RAW1 CDC stream itself was already built in TASK-06 and moved into `USB_Task` in
TASK-09 (header `RAW1` + `seq`/`nch`/`nsamp`/`fmt`, then int32 channel-major payload, 32780
bytes/frame, sent over the OTG USB CDC port via `CDC_Transmit_HS`). TASK-10 closes it out by
making frame loss **measurable** and adding the sustained 60 s continuity test (replacing the
breakdown's `pc_verify.py` with a PowerShell check, consistent with the rest of the project).

Firmware (`Src/main.c`):

- The host-visible `g_usb_seq` still increments **only on a successful `CDC_Transmit_HS`**, so the
  PC sees a gap-free sequence. A gap at the host therefore means a **transport** loss, which is what
  the 60 s test watches for.
- Added `volatile uint32_t g_usb_drops` - counts frames the device could **not** ship because the
  previous CDC transfer was still in flight (`TxState != 0`) or `CDC_Transmit_HS` returned non-OK.
  These are expected, by-design back-pressure drops (the design explicitly drops rather than blocks).
- `Monitor_Task` prints a new `[USB] sent=<n> drops=<n>` line each cycle (the `[MON]` line is
  unchanged, so the TASK-09 check still parses). This makes the device-side drop rate observable.

### Behaviour Observed

While the host is actively draining the port, `sent` advances at ~15.8 fps and `drops` stays low.
When the host stops reading (port closed), USB `TxState` stays busy, so `sent` freezes and `drops`
climbs every block - confirming the back-pressure counter is correct (e.g. `[USB] sent=950 drops=706`
captured right after the test closed COM12).

### Verification - PASSED on hardware

The firmware must already be running - do **not** flash before the check (flashing re-enumerates USB):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task10_usb_cdc.ps1 -DurationSec 60
```

Options: `-Port COMx` (default: auto-detect VID_0483&PID_5740), `-DurationSec` (default 60),
`-MinFrames` (default `DurationSec*5`). Report: `debug/task10_usb_cdc_report.txt`. It captures the
stream fast (4 MB read buffer, capture-then-parse) and walks every frame with the double-magic anchor,
checking header + strict `seq+1` continuity, plus a 24-bit range spot-check every 100th frame.

```text
TASK-10 USB CDC Transmit Continuity Check
Auto-detected OTG CDC port: COM12
Captured 31106685 bytes (~29.7 MB) from COM12 in ~60 s
Frames: 948 valid, seq 1..948, ~15.8 fps, gaps=0, range-checked=10 bad=0

[ OK ] Received 948 valid RAW1 frames (~15.8 fps)
[ OK ] No sequence gaps over 60 s (continuous transport)
[ OK ] Sampled frames within 24-bit range (10 checked)
TASK-10 USB CDC continuity check passed.
```

- **948 frames in 60 s (~15.8 fps)** - matches the ~15.6 Hz half-buffer rate (1024 frames @ 16 kHz).
- **0 sequence gaps** over the full minute -> the CDC transport is reliable end-to-end.
- `overruns=0` throughout; adding the drop counter did not perturb the DSP pipeline.

> **Format note:** TASK-10 keeps the existing **RAW1 / int32** frame, not the breakdown's
> `0x55AA / int16 / CRC16` layout, so the existing host tools (`read_mic_raw.m`, `mic_fft_test.m`,
> `check_usb_cdc_stream.ps1`) keep working unchanged. int32 also preserves the full 24-bit sample
> depth (the int16 layout would have truncated 8 bits). CRC integrity is covered instead by the
> per-frame header/range validation and the strict seq-continuity check.

---

## TASK-11 - DOA Output

**Status:** DONE - verified on hardware.

**Goal:** Turn the live TDOAs into a direction (azimuth + elevation) and output it;
"Done when" = moving a speaker around the array changes the reported angle.

### Array Geometry (USER-PROVIDED, editable)

The test array is a planar (2D) **square-ish array** of the 4 stereo pairs. Spacings the
user measured: **27.1 mm between the two mics of a pair**, **19.37 mm between adjacent pairs**.
The firmware encodes this as a 2x4 grid in an editable table `mic_pos[8][2]` (metres, near
`DOA_Init` in `Src/main.c`): pair `p` at `x = p * 19.37 mm`; the pair's two mics (L = side 0,
R = side 1) at `y = 0` and `y = 27.1 mm`; channel index = `pair*2 + side`. **If the real layout
differs, edit only that table** - the solver is geometry-agnostic.

### What Was Added (`Src/main.c`, guarded by `DOA_ENABLE`)

- **Sub-sample TDOA.** The array is tiny: max delay = 58 mm / 343 m/s ~= 2.7 samples at 16 kHz,
  so integer lags are far too coarse for an angle. `GCC_PHAT` now also does a **parabolic
  interpolation** around the correlation peak (`g_last_frac`); `GCC_ProcessPairs` stores the
  fractional lags in `g_tdoa_lag_f[]`. The int return is unchanged, so the TASK-08 self-test
  still reads lag 5.
- **Least-squares plane-wave solver.** Far-field model: each baseline `d_k = pos[k+1]-pos[0]`
  obeys `d_k . u = -(C/Fs) * lag_k`, with `u` the unit direction to the source. `DOA_Init`
  precomputes the 2x7 pseudo-inverse `M = -(C/Fs)*(DtD)^-1 Dt` so each frame is `u = M . lag_f`
  (just 14 MACs). `DOA_Compute` returns azimuth = `atan2(u_y,u_x)` (0..360, measured in the
  array x-y plane: 0 deg = +x / pair axis, CCW) and elevation = `acos(|u|)` (0 = in-plane,
  90 = overhead; a planar array cannot tell above from below, so elevation is a magnitude).
- **DOA_SelfTest** (runs at bring-up like the FFT/GCC self-tests): synthesizes the lags a known
  in-plane source at `DOA_SELFTEST_AZ` (30 deg) would produce and confirms the solver recovers it.
- **DOA_Task** now solves DOA on each `result_queue` item and prints `DOA seq= az= el=` ~1 Hz on
  the VCP, toggling `LED_GREEN` per fix. Floats are printed as integer tenths (`%f` is not linked
  in - newlib-nano without `-u _printf_float`).
- The `result_queue` payload `tdoa_result_t.lag[]` changed from `int32_t` to `float` (fractional).

### Bug Found & Fixed - defaultTask stack overflow corrupted result_queue

The first hardware run printed the DOA **self-test OK** but **no live `DOA seq=` lines**. Diagnosis
(VCP counters + an ST-LINK read of the queue control block): every `osMessageQueuePut` returned
`osErrorResource` and `DOA_Task` blocked forever, because the queue reported **capacity 0**
(`uxLength`/`uxItemSize` zeroed) even though its storage pointers proved it had been created
correctly as 4x32. Root cause: **`defaultTask` had only 128 words of stack** but runs
`MX_USB_DEVICE_Init()` (stack-hungry). It overflowed (TASK-09's `vTaskList` even showed
`defaultTask` stack-free = **0**) and wrote down into the FreeRTOS heap, zeroing the
`result_queue` control block - the first heap allocation. This had **silently broken the
FFT_Task->DOA_Task IPC since TASK-09** (TASK-09's check never asserted a DOA line, so it went
unnoticed). Fix: raise `defaultTask` stack to 512 words. After that, `cap=4`, every put/get
succeeds, and live DOA flows. See `debug/bugs_encountered.md`.

### Verification - PASSED on hardware

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task11_doa.ps1
```

Options: `-NoFlash`, `-Port COM3`, `-ReadSeconds 14`. Report: `debug/task11_doa_report.txt`.

```text
--- TASK-11 DOA ---
self-test: az 30 -> az 30 el 0 (expected az 30 el 0)
TASK-11 self-test OK (azimuth within +/-2 deg).
DOA seq=16 az=133.6 el=0.0
DOA seq=32 az=163.4 el=57.2
...
[ OK ] DOA solver self-test passed (synthetic azimuth recovered)
[ OK ] Live DOA output present (15 fix(es))
[ OK ] All az in [0,360) and el in [0,90]
[ OK ] Pipeline healthy (overruns=0)
TASK-11 DOA check passed.
```

- **Self-test:** synthetic azimuth 30 deg -> recovered 30 deg, elevation 0 - validates the linear
  algebra + `mic_pos` wiring independently of the mics.
- **Live:** valid az/el every fix, `overruns=0`. Without an acoustic source the dominant signal is
  common-mode ~50 Hz mains hum (near-zero inter-mic delay), so the live azimuth is noise-driven and
  wanders - expected. The **"speaker moves -> angle changes" step is manual**: wave a steady tone
  near the array and watch the live `az`/`el` on COM3 (re-run with `-NoFlash`).

> **Resolution caveat:** with a ~58 mm aperture at 16 kHz the angular resolution is coarse even
> with sub-sample interpolation. For sharper DOA, a larger array, a higher sample rate, or
> averaging several frames would help (future work / TASK-13).

---

## TASK-12 - Monitor & Watchdog

**Status:** DONE - verified on hardware.

**Goal:** Feed an independent watchdog, count DMA/SAI overruns, and report task stack
high-water marks; "Done when" = overruns=0 after 60 s capture and stack high-water > 10%.

### What Was Added (`Src/main.c`, `Monitor_Task` = StartTask05)

- **IWDG watchdog**, driven **directly via registers** (the HAL IWDG module is disabled in this
  project; register access also survives a CubeMX regen). LSI ~32 kHz, prescaler /64, reload 1000
  -> **~2.0 s timeout**, frozen while the debugger halts the core (`__HAL_DBGMCU_FREEZE_IWDG1`).
  `Monitor_Task` starts it after bring-up and **feeds it every ~0.5 s, but only while `g_blocks`
  keeps changing** - so a hung/stalled DSP pipeline stops the feed and the IWDG resets the MCU.
- **`HAL_SAI_ErrorCallback`** counts hardware SAI errors into `g_sai_errors` (+ `g_sai_err_code`,
  LED_RED), distinct from `g_overruns` (the software "FFT_Task didn't keep up" counter).
- **`SAI2_IRQn` enabled** (NVIC priority 5) in `HAL_SAI_MspInit`, with a new `SAI2_IRQHandler`
  in `stm32h7xx_it.c` calling `HAL_SAI_IRQHandler` for both SAI2 blocks. This **closes the TASK-04
  follow-up**: SAI2 overrun/error interrupts now reach the callback (previously only SAI1's IRQ was
  enabled; SAI2 relied on the DMA error path alone).
- **Stack high-water reporting**: a new `[STK] def= fft= usb= doa= mon=` line (min free words per
  task), plus `saiErr=` appended to the `[MON]` line. The `[MON]` prefix/format is otherwise
  unchanged so the TASK-09 check still parses it.
- **Reset-cause reporting**: `Print_ResetCause()` prints `last reset: ...` (IWDG/PIN/BOR/SFT/POR)
  at bring-up and clears the flags, so an IWDG-triggered reset is visible on the next boot.

### Verification - PASSED on hardware

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task12_monitor.ps1 -ReadSeconds 60
```

Options: `-NoFlash`, `-Port COM3`, `-ReadSeconds` (default 60). Report: `debug/task12_monitor_report.txt`.

```text
[ OK ] Reset-cause reported: 'PIN'
[ OK ] Monitor lines: 30, blocks 24 -> 953
[ OK ] Pipeline advancing (blocks climbed by 929)
[ OK ] overruns=0 across the whole window
[ OK ] saiErr=0 across the whole window (SAI1+SAI2)
[ OK ] Stack high-water (free words): def=344 fft=1874 usb=463 doa=358 mon=365
[ OK ] All tasks keep > 10% stack headroom
TASK-12 Monitor/Watchdog check passed.
```

- **60 s continuous**: `overruns=0`, `saiErr=0`, blocks climbed 24->953 (~15.5/s), no mid-run reset
  -> the watchdog is being fed correctly the whole time.
- **Stack high-water** (free words, allocated): def 344/512, fft 1874/2048, usb 463/512,
  doa 358/512, mon 365/512 - all well above the 10% floor.

### IT-07 watchdog proof (manual, demonstrated)

Temporarily stalling the pipeline (`vTaskSuspend(NULL)` in `FFT_Task` after 80 blocks) froze
`g_blocks`; `Monitor_Task` stopped feeding and the **IWDG reset the MCU in ~2 s**, after which the
next boot printed **`last reset: IWDG`** (captured twice as the board reset-looped). The temporary
stall was then removed and the clean firmware confirmed to run indefinitely (`last reset: PIN`,
blocks climb past 80, 0 IWDG resets). This is the destructive IT-07 case from the breakdown.
