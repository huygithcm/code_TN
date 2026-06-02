# Bugs Encountered — Debug Log

Running log of non-obvious bugs hit while building/verifying this project, with
symptom → root cause → fix. Newest first. Append new entries as they come up.

---

## 2026-06-01 — TASK-11 DOA

### BUG-12 — defaultTask stack overflow zeroed the result_queue control block (DOA IPC dead since TASK-09)

- **Where:** `Src/main.c`, `defaultTask_attributes.stack_size` (was `128 * 4`) and the
  `FFT_Task -> result_queue -> DOA_Task` IPC path.
- **Symptom:** TASK-11's DOA **self-test printed OK**, but **no live `DOA seq=` lines** ever
  appeared. The same was silently true back in TASK-09 (its `vTaskList` showed `DOA_Task` blocked
  and its report has zero DOA lines — the check just never asserted them).
- **Diagnosis:** Instrumented the queue with VCP counters → `puts=0 putfail=ALL gets=0`, every
  `osMessageQueuePut` returning `osErrorResource` (−3, "queue full") while `DOA_Task` stayed
  blocked on an apparently empty queue. `osMessageQueueGetCapacity` reported **0**. An ST-LINK read
  of the queue control block (`-r32 <handle>`) showed the **storage pointers still sized for 4×32**
  (pcTail = pcHead + 128) but `uxLength`/`uxItemSize` **zeroed** → created correctly, then corrupted.
- **Root cause:** `defaultTask` had only **128 words** of stack but runs `MX_USB_DEVICE_Init()`
  (stack-hungry). It overflowed (TASK-09's `vTaskList` literally showed `defaultTask` stack-free
  = **0**) and wrote **down past its stack into the FreeRTOS heap**, hitting the `result_queue`
  control block — the *first* heap allocation, sitting at the very start of `ucHeap` — and zeroing
  `uxLength`/`uxItemSize`. With `uxLength = 0` every send sees a "full" queue and every receive
  blocks forever.
- **Fix:** raise `defaultTask` stack to **512 words**. After that `cap=4`, every put/get succeeds,
  and live DOA flows. (General lesson: a task whose `vTaskList` stack-free hits 0 is overflowing;
  on this project it corrupts the heap-resident queue/TCBs, not the task's own data, so the failure
  shows up far from the cause.)
- **Note:** the TASK-09 summary claim that "DOA_Task drains result_queue and prints live lag
  vectors" was therefore never actually exercised end-to-end; TASK-11 is where the IPC first runs.

---

## 2026-06-01 — CMSIS-DSP build integration into the CubeIDE project model (TASK-07/09)

Hit while rebuilding TASK-09 on a fresh checkout and then making it build from the
STM32CubeIDE GUI (not just the CLI). Net result: the five CMSIS-DSP aggregate units are
now registered as **linked source files** in `STM32CubeIDE/.project`, with a per-folder
`-O2` override in `STM32CubeIDE/.cproject`, so CubeIDE (GUI *and* headless) regenerates the
DSP build rules and links automatically. This **supersedes** the old TASK-07 note that said
to re-apply the CLI `subdir.mk` / `objects.list` / `makefile` wiring by hand after every regen.

### BUG-11 — CubeIDE per-folder `-O2` override silently drops inherited `-I` / `-D`

- **Where:** `STM32CubeIDE/.cproject`, Debug config, the per-folder `<folderInfo
  resourcePath="Drivers/CMSIS/DSP">` override.
- **Symptom:** After registering the DSP units as linked sources and adding a `-O2` folder
  override, the headless/GUI build regenerated `Debug/Drivers/CMSIS/DSP/subdir.mk` with
  `-c -O2` but **no `-I` include paths and no `-D` defines** → `arm_math.h` not found,
  11 compile errors on the DSP `.o` files.
- **Root cause:** In CDT managed build, a per-resource (folder) `<tool>` that redefines the
  compiler via `superClass` does **not** inherit option *instances* (include paths, defines)
  from the root `folderInfo` — it starts from the tool superClass defaults, which are empty.
  Only the one option I set (optimization) was applied; everything else was lost for that folder.
- **Fix:** embed the full `Include paths (-I)` and `Define symbols (-D)` option lists into the
  override tool *alongside* the optimization option (copied from the root C-compiler tool).
  After that the regenerated rule carries `-O2` + all `-I` + `USE_HAL_DRIVER`/`STM32H7A3xxQ`,
  and links clean (`text=179356`). Verified with headless
  `org.eclipse.cdt.managedbuilder.core.headlessbuild -cleanBuild`.
- **Side notes:** (a) also added `Drivers/CMSIS/DSP/PrivateInclude` to the C-compiler include
  paths (Debug **and** Release) — some component `.c` files pulled in by the aggregates need it;
  (b) the headless `-import` drops a stray generic `.project` (named `code_TN`) at the repo root
  for the parent folder — delete it, it is not part of the project.

### BUG-10 — Hand-written `subdir.mk`: "output filename may not be empty"

- **Where:** `Debug/Drivers/CMSIS/DSP/subdir.mk` (the interim hand-written CLI version, before
  BUG-11's project-model fix).
- **Symptom:** `arm-none-eabi-gcc: fatal error: output filename may not be empty` for all five
  DSP units; the echoed command showed `-MF"" -MT"" ... -o ""`.
- **Root cause:** I put the compile flags — including `-MF"$(@:%.o=%.d)" -MT"$@" -o "$@"` — into a
  `:=` (immediately-expanded) make variable. `$@` and `$(@:%.o=%.d)` are automatic variables that
  only exist inside a recipe; with `:=` they expand at parse time, where they are empty.
- **Fix:** define the flags variable with `=` (deferred expansion) so `$@` resolves per-target
  when the recipe runs. (Moot after BUG-11 — CubeIDE now generates the rules.)

### BUG-09 — CLI link fails: CMSIS-DSP symbols undefined on a fresh checkout

- **Where:** CLI `make` build under `STM32CubeIDE/Debug/`; references from `Src/main.c`
  `FFT_Init` / `FFT_ProcessAll` / `FFT_SelfTest` / `GCC_PHAT`.
- **Symptom:** `undefined reference to 'arm_rfft_fast_init_f32'` (also `arm_mult_f32`,
  `arm_rfft_fast_f32`, `arm_cmplx_mag_f32`, `arm_max_f32`), plus
  `Unknown destination type (ARM/Thumb)` and `dangerous relocation: unsupported relocation`,
  ending in `collect2.exe: error: ld returned 1 exit status`.
- **Root cause:** `Debug/` is **gitignored**, so a fresh checkout has none of the CMSIS-DSP build
  wiring — the five aggregate units were never compiled and `objects.list`/`makefile` didn't
  reference them. The DSP *source* is in the repo (`Drivers/CMSIS/DSP/Source`) but nothing built it.
  (The `Unknown destination type` noise is the linker reacting to calls to symbols it never got an
  object for.)
- **Fix (interim, CLI):** create `Debug/Drivers/CMSIS/DSP/subdir.mk` (compile the 5 units at `-O2`),
  add `-include Drivers/CMSIS/DSP/subdir.mk` to `Debug/makefile`, and add the 5 `.o` to
  `Debug/objects.list`. **Durable fix:** BUG-11 — register the units in the project model so any
  CubeIDE/CLI build regenerates the wiring (no more gitignored hand-edits).

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
survived. (CMSIS-DSP is now part of the project model, so CLI/IDE builds regenerate the
DSP wiring automatically — see BUG-09/BUG-11 above; no hand-editing of `Debug/` needed.)

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
