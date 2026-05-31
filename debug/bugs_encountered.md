# Bugs Encountered — Debug Log

Running log of non-obvious bugs hit while building/verifying this project, with
symptom → root cause → fix. Newest first. Append new entries as they come up.

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
