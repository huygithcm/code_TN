# Bugs Encountered — Debug Log

Running log of non-obvious bugs hit while building/verifying this project, with
symptom → root cause → fix. Newest first. Append new entries as they come up.

---

## 2026-06-01 — FreeRTOS bring-up (TASK-09, after CubeMX regenerate)

Found while reviewing the project right after enabling FreeRTOS in CubeMX. The RTOS
scaffolding (FreeRTOS middleware, TIM6 timebase, lowered NVIC priorities) generated
correctly, but the regenerate also re-introduced/created the issues below.

### BUG-08 — SAI1 SYNCOUT fix (TASK-05) silently reverted by CubeMX regenerate

- **Where:** `Src/main.c` `MX_SAI1_Init` (lines ~603, ~631).
- **Symptom (predicted):** SAI2 blocks (pair2/pair3) would go dead again (half=full=0),
  exactly the TASK-05 failure — SAI2 are `SAI_SYNCHRONOUS_EXT_SAI1` slaves and need
  SAI1 to export its sync via `GCR.SYNCOUT`.
- **Root cause:** CubeMX regenerates `MX_SAI1_Init` from the `.ioc`, resetting both
  SAI1 blocks to `SynchroExt = SAI_SYNCEXT_DISABLE`. The TASK-05 hand-edit
  (`SAI_SYNCEXT_OUTBLOCKA_ENABLE` on **both** SAI1 A and B) lives only in the generated
  function, so it is wiped on every regenerate. The `.ioc` still has no
  "Synchronization Outputs = Block A" setting.
- **Fix:** re-apply `SynchroExt = SAI_SYNCEXT_OUTBLOCKA_ENABLE` on both SAI1 blocks
  (it is inside USER-CODE-free generated code, so it must be redone after each regen).
  Durable fix: set SAI1 "Synchronization Outputs = Block A" in the `.ioc` so CubeMX
  emits it. (Same root cause as the TASK-05 note in `tasks_done_summary.md`.)

### BUG-07 — Whole capture+FFT+GCC pipeline became dead code after `osKernelStart()`

- **Where:** `Src/main.c` `main()` — `osKernelStart()` at ~line 353; `Audio_Start()`,
  `FFT_SelfTest()`, `GCC_SelfTest()` and the old `while(1)` superloop at ~365–455.
- **Symptom (predicted):** firmware boots into the scheduler and runs only the empty
  CubeMX task stubs (`StartTask02..05` in `Src/freertos.c`); no audio capture, no FFT,
  no USB stream, no VCP heartbeat — the TASK-05/06/07/08 code never executes.
- **Root cause:** CubeMX inserts `osKernelStart()` (which never returns) at the end of
  `main()`, **before** the existing superloop. Everything after it — `Audio_Start`, the
  self-tests, and the `while(1)` deinterleave/FFT/GCC loop — is unreachable. The
  generated tasks are empty stubs.
- **Fix (TASK-09 work, not yet applied):** move `Audio_Start()` + the self-tests into
  task init; put deinterleave+FFT+GCC into `FFT_Task`, USB framing into `USB_Task`;
  have the SAI master-block callback `xTaskNotifyFromISR(fft_task, ...)`; delete the
  dead superloop. See `freertos_cubemx_config.md` §6.

### BUG-06 — Generated task stacks too small for the DSP pipeline

- **Where:** `.ioc` `FREERTOS.Tasks01` / `Src/freertos.c` — FFT_Task stack = **128
  words (512 B)**.
- **Symptom (predicted):** stack overflow once FFT_Task runs the FFT/GCC pipeline +
  `printf` (caught by `configCHECK_FOR_STACK_OVERFLOW=2` if lucky, else a HardFault).
- **Root cause:** CubeMX defaulted every task to 128 words. The big DSP buffers are
  DTCM globals (not on the stack), but the call depth + printf still needs more.
- **Fix:** raise FFT_Task stack to >= 2048 words (USB/DOA 512, Monitor 256), per the
  TASK-09 table. Also `result_queue` is a placeholder (`uint16_t` x16) and must match
  the TDOA item type.

### BUG-05 — `result_queue` item type can't hold the TDOA vector

- **Where:** `Src/main.c` `osMessageQueueNew(16, sizeof(uint16_t), ...)` (~line 303);
  `.ioc` `FREERTOS.Queues01=result_queue,16,uint16_t,...`.
- **Symptom (predicted):** FFT_Task can't pass `g_tdoa_lag[7]` (int32 lags) to DOA_Task
  through the queue — the item is a single `uint16_t`.
- **Root cause:** placeholder type picked in CubeMX. The breakdown intends the queue to
  carry the per-pair TDOA result.
- **Fix:** make the queue item a struct/array sized for the TDOA result (e.g.
  `int32_t lags[GCC_NPAIRS_LIVE]`, or the full 8x8 matrix the breakdown's DOA_Task
  expects), and create the queue with that `sizeof`.

### BUG-04b — DWT cycle counter + Audio_Start stranded in the dead superloop

- **Where:** `Src/main.c` — `Clock_Verify()` (arms `DWT->CYCCNT`) and `Audio_Start()`
  are in the post-`osKernelStart()` dead code (BUG-07).
- **Symptom (predicted):** even after moving the pipeline into tasks, if these two are
  forgotten: (a) **no mic data at all** (DMA never armed by `Audio_Start`), and (b) the
  FFT/GCC timing prints (`g_fft_us`, `g_gcc_us`) read garbage because `DWT->CYCCNT` was
  never enabled (`Clock_Verify` sets `TRCENA` + `CYCCNTENA`).
- **Fix:** arm the DWT counter and call `Audio_Start()` during RTOS init (e.g. top of
  FFT_Task before its loop, or in a one-time init), not in the abandoned superloop.

### BUG-03b — `MX_USB_DEVICE_Init()` now runs inside `StartDefaultTask`

- **Where:** `Src/main.c` `StartDefaultTask` (~line 1163) — CubeMX moved USB init out of
  `main()` into the default task.
- **Symptom (predicted):** USB device is only initialized once the scheduler runs and
  the default task executes; any USB access from another task before that (or from the
  old superloop's `hUsbDeviceHS` use) finds it uninitialized.
- **Root cause:** with FreeRTOS + USB middleware, CubeMX defers `MX_USB_DEVICE_Init()`
  to the default task. Not a bug per se, but a sequencing change to account for.
- **Fix:** when writing USB_Task, gate transmits on the device being ready (the existing
  `hcdc != NULL && TxState == 0` guard already covers the not-yet-ready case); don't
  assume USB is up at `main()` time.

### Note (not a bug) — CubeMX did NOT restructure to `Core/`

This project keeps the flat `Src/` + `Inc/` layout (no `Core/Src`, `Core/Inc`).
The regenerate edited files in place and preserved all USER CODE blocks, so the
TASK-07/08 code in `Src/main.c` USER CODE 4 survived intact. The linker `KEEP()`
sections (`.DTCMSection`/`.DMASection`/`.USBSection`) and 1 MB AXI SRAM region also
survived. (CLI builds still need `Debug/` regenerated with the new FreeRTOS sources
**and** the CMSIS-DSP wiring re-applied — see BUG note in the TASK-07 build section.)

---

## 2026-06-01 — USB CDC test tooling (TASK-06 verification)

### BUG-04 — MATLAB `hann()` needs the Signal Processing Toolbox

- **Where:** `tools/mic_fft_test.m`
- **Symptom:** `mic_fft_test` would `Undefined function 'hann'` on a base MATLAB
  install (no Signal Processing Toolbox).
- **Root cause:** `hann()` lives in the Signal Processing Toolbox, not base MATLAB.
- **Fix:** compute the Hann window inline (same form `read_mic_raw.m` already uses):
  `w = 0.5 - 0.5*cos(2*pi*(0:nsamp-1)'/(nsamp-1));`. Kept the tool dependency-free
  (`fft`, `corrcoef` are base MATLAB).

### BUG-03 — SerialPort read-buffer overflow corrupts CDC frames

- **Where:** `scripts/check_usb_cdc_stream.ps1` (first version)
- **Symptom:** First 1–2 frames parsed fine (seq contiguous), then a frame failed
  the 24-bit range check ("sample out of range"), and the reader never recovered
  within the timeout. Re-running gave the same pattern at a different seq.
- **Root cause:** Each RAW1 frame is ~32 KB but `System.IO.Ports.SerialPort.ReadBufferSize`
  defaults to **4 KB**. Doing per-sample min/max work in PowerShell *while* reading
  was too slow, so the driver buffer overflowed and **dropped bytes mid-frame** →
  the stream lost byte alignment → int32 samples decoded as garbage (out of range).
- **Fix:** two changes:
  1. `\$sp.ReadBufferSize = 4 * 1024 * 1024` (set **before** `Open()`).
  2. Split into a fast **capture phase** (read only, into a `MemoryStream`) and a
     separate **index-based parse phase** (no `List.RemoveRange` shifting). The host
     now always keeps up with the stream.
- **Diagnostic that nailed it:** a bare capture loop (no processing) showed every
  frame clean and exactly 32780 bytes apart — proving the corruption came from the
  reader being too slow, not from the firmware.

### BUG-02 — Stray "RAW1" magic inside the int32 payload

- **Where:** `scripts/check_usb_cdc_stream.ps1`, `tools/read_mic_raw.m` (and so
  `tools/mic_fft_test.m`, which reads via `read_mic_raw`).
- **Symptom:** The frame parser occasionally locked onto a false boundary; magic
  offsets in a raw capture were `8076, 40792, 73572, ...` — the first gap was 32716
  (not 32780), i.e. an extra "RAW1" appeared 64 bytes early. In MATLAB the misalignment
  showed up as a probe with `value OR = 0x31577FFF` and a "sample" of `827801938`
  (= `0x31578252`) — i.e. the magic bytes `57 31` ("W1") had leaked into the int32 data,
  and the data looked like a +16384-DC, clipped 15-bit `[0..32767]` signal.
- **Root cause:** The payload is raw int32 audio; the 4 bytes `52 41 57 31` ("RAW1")
  can occur by coincidence inside sample data. A single-magic search can lock onto it.
- **Fix:** **double-magic anchor** — only accept a frame start at offset `i` if the
  magic also appears at `i + FRAME_BYTES` (32780). A coincidental magic almost never
  has a second one exactly one frame later, so false boundaries are rejected. Applied to
  both the PowerShell check and `read_mic_raw.m` (which previously used single-magic).

### BUG-01.5 — Wrong "mics are 15-bit / 47 Hz test artifact" conclusion (from BUG-02)

- **Symptom:** Early analysis claimed every channel was a uniform, positive-only
  `[0..32767]` ~47 Hz signal near full scale, concluded the mics were not delivering
  real audio (a "test/pickup artifact").
- **Root cause:** That data came from the misaligned reads of BUG-02 (single-magic
  `read_mic_raw`), which fabricated a +16384 DC offset and clipped 15-bit values. An
  early post-boot capture session may also have been in an unsettled state.
- **Truth (after the BUG-02 fix):** properly anchored captures (both the hardened
  PowerShell check and `mic_fft_test`) show **real bipolar 24-bit audio**: DC ≈ 0
  (±30 counts), AC RMS ~2.5-3.2 k, per-channel min/max varying frame to frame, channels
  independent. There is a strong ~47 Hz tone (`prom_dB ≈ 40`, flatness ≈ 0.03) that is
  **50 Hz mains hum** (50 Hz leaks onto the 46.875 Hz FFT bin; common-mode across
  channels). The capture + deinterleave path is correct. Lesson: confirm frame alignment
  (sign distribution, DC near 0, no magic bytes in payload) before judging signal content.

---

## Earlier bugs (already written up in `tasks_done_summary.md`)

These are documented in full in the task summary; listed here for one-stop reference:

- **TASK-01:** custom buffer sections dropped by `--gc-sections` (symbols compiled
  into `main.o` but absent from the ELF). Fix: `KEEP()` in the linker script + `used`
  attribute; `__attribute__((retain))` was ignored on this bare-metal target.
- **TASK-03:** local `__io_putchar` caused a multiple-definition link error — the BSP
  already provides it. Removed the local one. (Note: float `printf` still needs
  `-u _printf_float`.)
- **TASK-05:** SAI2 ext-sync slaves were dead (pair2/3 = 0/0) because `SAI1->GCR.SYNCOUT`
  was never set. Fix: `SynchroExt = SAI_SYNCEXT_OUTBLOCKA_ENABLE` on **both** SAI1 blocks.
- **TASK-06:** firmware hung after the banner — unaligned 16-bit write to
  `usb_tx_frame[9]` via `memcpy(..., &ns, 2)`. Fix: byte-wise little-endian writes.
