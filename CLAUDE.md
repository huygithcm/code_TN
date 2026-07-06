# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## What this project is

Firmware for an **8-microphone acoustic Direction-of-Arrival (DOA) system** on an
STM32H7A3ZI (NUCLEO-H7A3ZI-Q). It captures 8 mono mics (4 SAI blocks × 2 slots) at
16 kHz / 24-bit, runs GCC-PHAT time-delay estimation between diametrically-opposite
mic pairs, matches the measured TDOAs against a hardcoded delay table to get an
azimuth, and pans a camera servo toward the sound (a talker or a hand clap). Raw
audio and live DOA are streamed to a PC for verification.

Most inline comments and the Vietnamese `.md` docs describe *why* something is the
way it is — the hardware is subtly miswired and several non-obvious workarounds
depend on that. **Read the relevant comment before changing DSP constants, the mic
remap, or the servo mapping.**

---

## Build / flash / test

Do **not** install a separate ARM GCC — `build.ps1` auto-locates the toolchain
bundled inside STM32CubeIDE (`C:\ST\STM32CubeIDE_*` or Program Files) and drives the
root [Makefile](Makefile). Output lands in `build/` (gitignored).

```powershell
.\build.ps1                # build Debug  -> build/code_ver2_Fs16khz.elf/.hex/.bin/.map
.\build.ps1 -Release       # build Release (-Os)
.\build.ps1 rebuild        # clean + build
.\build.ps1 clean
.\build.ps1 flash          # flash .hex over ST-LINK (auto-builds if missing)
```

Raw `make` also works if `arm-none-eabi-gcc` is on PATH (`make`, `make DEBUG=0`,
`make clean`, `make -jN`). CMSIS-DSP is compiled **from source** via the aggregate
`*Functions.c` units listed in the Makefile — there is no prebuilt lib.

### Hardware verification tests (`scripts/`, PowerShell)

There is no host unit-test suite; verification is **on-target**. Each build task has a
`scripts/check_taskNN_*.ps1` that flashes (optional), resets via ST-LINK, reads the
VCP boot banner, and asserts the expected output. They double as the run-a-single-test
mechanism.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/check_task07_fft.ps1
# common flags: -NoFlash (don't reflash, just re-read), -Port COM5, -ReadSeconds 12
```

Each writes a report to `debug/taskNN_*_report.txt`. `scripts/check_usb_cdc_stream.ps1`
and `scripts/diag_mic_channels.ps1` / `scripts/mic_tap_test.ps1` diagnose the raw
audio path on the **CDC** port (not the VCP). Task status and the full verification
history live in [BUILD_AND_CONFIG.md](BUILD_AND_CONFIG.md) and [README.md](README.md)
(which is actually the task-status summary).

> `-NoFlash` matters: flashing resets the USB device and drops the CDC stream. To
> test the live audio/DOA path, flash once, then run readers without reflashing.

---

## Two USB serial ports (critical to keep straight)

The board enumerates as **two different COM ports** with distinct roles:

| Port | VID:PID | Role |
|------|---------|------|
| **ST-Link VCP** (USART3) | `0483:374E` | `printf` logs: clock/SAI checks, `[MON]` health, `DOA seq=… az=…`. ~COM5 |
| **USB CDC** (OTG_HS)      | `0483:5740` | Raw 8-channel `RAW1` audio frames **out** + `SET`/`SERVO`/`AUTO`/`VOICE` commands **in**. ~COM7 |

Python tools auto-detect by VID:PID, so COM numbers rarely matter. You may run one VCP
reader and one CDC reader concurrently, but **not two CDC readers** (port contention).

---

## Signal pipeline (the big picture)

All DSP lives in [Src/main.c](Src/main.c) under FreeRTOS (CMSIS-RTOS v2). Key sizing:
`AUDIO_BLOCK_SAMPLES = 1024` (= FFT size), 16 kHz, 8 channels.

```
SAI1-A(master) + 3 slave blocks ──DMA(circular, per block)──► dma_buf[4][4096] (AXI SRAM, non-cacheable)
     │ master half/full ISR fires xTaskNotify(FFT_Task)
     ▼
Deinterleave_Pair()  24-bit unpack + MIC_REMAP + per-channel polarity/wrap fixes ──► mic_data[8][1024] (float, DTCM)
     ▼
FFT_ProcessAll()     Hann × 1024-pt rfft × magnitude (CMSIS-DSP), all 8 mics
     ▼
GCC_ProcessPairs()   GCC-PHAT on 4 OPPOSITE pairs (slots 2k,2k+1), band-limited 250–3500 Hz,
                     ±5-sample search + phase-slope sub-sample refinement ──► g_tdoa_lag_f[4]
     ▼ result_queue (tdoa_result_t: 4 lags + frame level + clipped flag)
DOA_Task: DOA_Compute()  match 4 TDOAs to g_doa_table[16 az][4 pairs] (min SSE) ──► azimuth
     ▼ 1-second voting window + input gate (clap or voice mode)
Servo_PointToAzimuth()   az → servo angle (EMA-smoothed, gradual, dead-banded) ──► TIM4_CH1 PWM on PB6
```

### FreeRTOS tasks (created in `main()`; pipeline brought up inside FFT_Task)

| Task | Prio / stack | Role |
|------|--------------|------|
| `FFT_Task` (StartTask02) | High / 2048 w | Owns `Pipeline_InitOnce()` (clock/SAI verify + self-tests + `Audio_Start()`), then per-half: deinterleave → FFT → GCC-PHAT → push `tdoa_result_t` → snapshot for USB |
| `USB_Task` (StartTask03) | Realtime / 512 w | Ships one `RAW1` CDC frame per snapshot; back-pressure drops counted in `g_usb_drops` |
| `DOA_Task` (StartTask04) | AboveNormal / 512 w | Drains result queue, gates input, votes over 1 s window, drives servo |
| `Monitor_Task` (StartTask05) | Low / 512 w | `vTaskList()` once, then `[MON]`/`[USB]`/`[STK]` health lines; owns the IWDG (fed only while `g_blocks` advances) |
| `defaultTask` | Normal / **512 w** | Runs `MX_USB_DEVICE_Init()` then idles. Stack is deliberately 512 (not CubeMX's 128) — see BUG note below |

Self-tests run at boot for every stage (FFT→bin 64, GCC→lag 5, DOA→table recovery,
silence→zero) and print over the VCP; a red LED means a self-test or SAI error failed.

---

## Non-obvious things that will bite you

These are load-bearing workarounds for real hardware quirks. Changing them without
understanding breaks DOA silently (no build error).

- **`MIC_REMAP[8] = {0,1,7,6,5,4,2,3}`** in `Deinterleave_Pair`. The board's SAI
  capture order does **not** match the physical mic labels. The remap fixes it in one
  place so the rest of the pipeline sees clean pairs and `g_doa_table` can use natural
  baselines φ = {0,45,90,135}°. Re-run `tools/test_mic_order.py` and edit only this
  array if the board is rewired. Do **not** bake wiring into the delay table.
- **All 8 mics are one type now — read as 24-bit, no phase inversion.** After the mic
  hardware change, `Deinterleave_Pair` reads **every** channel as full signed 24-bit
  (`wide = 1U`) because the new mics overflow the 16-bit slot, and applies **no**
  per-channel polarity flip (`l_sign = r_sign = 1`). Verified from a RAW1 capture: all
  4 opposite pairs are in-phase (corr ≈ +0.6…+0.7). The old code read only pair0 wide
  and inverted ch3/ch5/ch6 for a mixed-mic board — both are gone. If a single channel
  is ever rewired/replaced, restore its `wide` gating or sign flip there (the old
  values are kept in the comment). Re-verify with `scripts/diag_mic_channels.ps1`.
- **All 4 pairs feed DOA** (`DOA_SKIP_PAIR DOA_NPAIRS`): with uniform mics, pair0
  (Mic1/Mic2) matches the other three, so the table match uses all 4 baselines. (Was
  `DOA_SKIP_PAIR 0` = exclude pair0 when it was a different mic type.)
- **No 180° front/back correction** in `DOA_Compute` — the table match now yields the
  physical bearing directly (`*az_deg = g_doa_angles[best_a]`). That flip only existed
  to cancel the TDOA-sign error from the per-channel inversions, which are removed.
  The servo mapping constants (`SERVO_AZ_CENTER = 180`, `SERVO_DIR = -1`) were
  calibrated against the physical rig; the az→servo convention is in the "DIRECTION
  STANDARD" comment block in `main.c` and **must** be mirrored in `tools/plot_doa.py`.
  (Azimuth after the phase-alignment change still needs a known-direction source check.)
- **SAI1 `SynchroExt = SAI_SYNCEXT_OUTBLOCKA_ENABLE` on both SAI1 blocks** — required
  so the SAI2 external-sync slaves get a clock. `HAL_SAI_Init` rewrites the shared GCR
  on every call, so it must be set on the last-inited block too. If regenerating from
  CubeMX, set "Synchronization Outputs = Block A" in the `.ioc` or pair2/pair3 go dead.
- **`arm_rfft_fast_f32` forward overwrites its input buffer** — always FFT from a
  scratch copy (`fft_win`), never from `mic_data` directly.
- **`defaultTask` stack = 512 words**: `MX_USB_DEVICE_Init()` overflowed the CubeMX
  128-word default and corrupted the FreeRTOS heap (zeroing `result_queue`), silently
  killing the FFT→DOA IPC. See its declaration comment and `debug/bugs_encountered.md`.
- **Float `printf` is disabled** (newlib-nano). VCP logs scale floats to integers
  (`×1000`, `×1e6`). Add `-u _printf_float` to `LDFLAGS` if you truly need `%f`.
- If STM32CubeIDE regenerates code, the DSP source wiring and the SAI GCR fix must be
  re-applied — see the "re-add" notes in [BUILD_AND_CONFIG.md](BUILD_AND_CONFIG.md).

---

## Runtime control (over the CDC port)

Send line commands to the CDC port to tune behavior without rebuilding (parsed in
[Src/usbd_cdc_if.c](Src/usbd_cdc_if.c); firmware echoes `CFG …` on the VCP):

- `SET ratio <v>` / `SET abs <v>` / `SET resid <v>` — clap-gate thresholds
  (`g_clap_ratio` / `g_clap_abs` / `g_doa_resid_max`).
- `VOICE 1|0` — voice-follow mode (any band-energy frame votes) vs clap mode
  (impulsive onset only). Default is voice (`g_voice_mode = 1`).
- `SERVO <deg>` — manual aim (clears auto-track); `AUTO 1|0` — resume/stop DOA driving
  the servo.

Defaults reset on power cycle. To change them permanently, edit the `g_clap_*` /
`g_voice_mode` initializers in `main.c` and rebuild.

### PC tools (`tools/`, `pip install pyserial matplotlib numpy`)

| Tool | Port | Purpose |
|------|------|---------|
| [plot_doa.py](tools/plot_doa.py) | VCP | Live DOA arrow on the mic-array figure |
| [record_channels.py](tools/record_channels.py) | CDC | Record 8-ch audio → WAV/npy/png + RMS stats |
| [set_doa_filter.py](tools/set_doa_filter.py) / [doa_filter_gui.py](tools/doa_filter_gui.py) | CDC | Tune clap-gate thresholds (CLI / GUI) |
| [test_mic_order.py](tools/test_mic_order.py), [servo_*.py](tools/), [spectrum_live.py](tools/spectrum_live.py) | CDC | Mic-mapping calibration, servo mapping, live spectrum |

MATLAB helpers in `matlab/` and `tools/*.m` handle offline validation, the delay-table
generator (`gen_delay_table.m` → `g_doa_table`), and the clap high-pass filter design.

---

## Hardware configuration reference

Condensed from `code_ver2_Fs16khz.ioc` + `Src/main.c` (STM32CubeMX 6.17.0).

**Clocks:** HSE 8 MHz (bypass) → PLL1 (M1/N16/P2) → **SYSCLK/HCLK/APB = 64 MHz**
(Scale 3, direct SMPS). PLL3 (M5/N123/P4/R4) → **49.2 MHz SAI clock** → 16 kHz sample
rate (0.09% error). USB on HSI48.

**SAI capture (8 mono channels = 4 stereo pairs):**

| Block | Mode | Sync | Data pin | DMA stream |
|-------|------|------|----------|------------|
| SAI1-A | **Master RX** (clock src) | Async | PE6 (SD), PE4 FS, PE5 SCK | DMA1_Stream0 |
| SAI1-B | Slave RX | Sync to SAI1-A | PE3 | DMA1_Stream1 |
| SAI2-A | Slave RX | Ext-sync SAI1 | PD11 | DMA1_Stream2 |
| SAI2-B | Slave RX | Ext-sync SAI1 | PA0 | DMA1_Stream3 |

Frame params (all blocks): Free protocol, 24-bit data / 32-bit slots, MSB first,
falling-edge strobe, frame length 64, 2 active slots, FS active-low before first bit,
stereo, no companding/PDM. All DMA: periph→mem, circular, word (32-bit), MemInc on,
FIFO disabled. DMA1_Stream0–3 + SAI1 IRQ preempt priority **5** (so `…FromISR` is
legal under FreeRTOS); OTG_HS is 6. **SAI2_IRQn is not enabled** (only DMA IRQs fire).

**Memory placement** (linker `STM32CubeIDE/STM32H7A3ZITXQ_FLASH.ld`; `KEEP()` + `used`
stop `--gc-sections` from dropping the NOLOAD buffers):
- `dma_buf[4][4096]` int32 → `.DMASection` in AXI SRAM `0x24000000` (MPU region 1 =
  non-cacheable, so SAI/DMA writes are coherent with no manual invalidate).
- `mic_data` / `mic_raw` / FFT / GCC buffers → `.DTCMSection` in DTCM `0x20000000`
  (never cached, always fast — the DSP hot path). I/D-cache enabled at boot.
- `usb_snapshot` → AXI SRAM (32 KB, off the DSP hot path).

**GPIO of note:** PB6 = TIM4_CH1 servo PWM (added in code, not CubeMX). PD8/PD9 =
USART3 VCP. PA11/PA12 = USB. LEDs PB0/PB14/PC13, user button PC13/EXTI15_10.

**Init order in `main()`:** MPU → HAL → SystemClock → PeriphClock(PLL3) → GPIO → DMA →
SAI1 → SAI2 → TIM4 + servo boot sweep → RTOS (queue + 5 tasks) → LED/button/COM →
`osKernelStart()`. SAI/DMA start and self-tests happen inside `FFT_Task`, **not** `main()`.

---

## Docs map

- [BUILD_AND_CONFIG.md](BUILD_AND_CONFIG.md) — task-by-task implementation + verification log (the deep "why").
- [README.md](README.md) — task status summary table.
- [DOA_THUAT_TOAN.md](DOA_THUAT_TOAN.md), [docs/NOI_DUNG_LY_THUYET.md](docs/NOI_DUNG_LY_THUYET.md), [docs/LUU_DO_GIAI_THUAT.md](docs/LUU_DO_GIAI_THUAT.md) — DOA theory + algorithm flowcharts (Vietnamese).
- `debug/bugs_encountered.md` — catalog of the hardware/firmware bugs behind the workarounds above.
- `stm32h7a3_task_breakdown.md`, `tasks_done_summary.md` — the original task plan.
</content>
