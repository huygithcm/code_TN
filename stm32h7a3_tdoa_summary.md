# STM32H7A3ZI — 8-Mic TDOA System Summary

## Hardware

| Item | Value |
|------|-------|
| MCU | STM32H7A3ZITxQ @ 64 MHz |
| Board | NUCLEO-H7A3ZI-Q |
| Microphones | 8 × INMP441 (I2S PDM, 24-bit) |
| Audio interface | SAI1 + SAI2 (4 blocks × 2 slots) |
| USB | OTG_HS in FS mode — CDC Virtual COM |

---

## Clock

| Domain | Source | Frequency |
|--------|--------|-----------|
| SYSCLK | PLL1 (HSE 8 MHz × 16 ÷ 2) | 64 MHz |
| SAI1/2 | PLL3-P (M5 N123 P4) | 49.2 MHz |
| USB | HSI48 | 48 MHz |
| Sample rate | — | 16.015 kHz (error 0.09 %) |

---

## SAI Configuration

| Block | Role | Data pin | Mic pair |
|-------|------|----------|----------|
| SAI1 Block A | Master RX | PE6 | mic 0 (L), mic 1 (R) |
| SAI1 Block B | Slave RX (sync SAI1-A) | PE3 | mic 2 (L), mic 3 (R) |
| SAI2 Block A | Slave RX (extern sync) | PD11 | mic 4 (L), mic 5 (R) |
| SAI2 Block B | Slave RX (extern sync) | PA0 | mic 6 (L), mic 7 (R) |

**Frame:** 64-bit frame / 32-bit active / 2 slots / 24-bit data left-justified in 32-bit word.

**Startup order:** start slaves first (SAI2B → SAI2A → SAI1B), then master (SAI1A) last to avoid sync loss.

---

## DMA

| Stream | Source | Width | Mode |
|--------|--------|-------|------|
| DMA1_Stream0 | SAI1_A | Word (32-bit) | Circular |
| DMA1_Stream1 | SAI1_B | Word (32-bit) | Circular |
| DMA1_Stream2 | SAI2_A | Word (32-bit) | Circular |
| DMA1_Stream3 | SAI2_B | Word (32-bit) | Circular |

**Buffer layout per pair:**
```
dma_buf[pair][4096]  =  PING[2048 words] | PONG[2048 words]
                         1024 samples × 2 slots (L+R)
```

**IRQ priority:** all DMA streams at preempt 0, sub 0.

---

## Memory Layout

| Region | Address | Size | Contents |
|--------|---------|------|----------|
| FLASH | 0x08000000 | 2 MB | Code, Hann LUT |
| DTCM | 0x20000000 | 128 KB | Stack, `mic_data`, `fft_*` |
| AXI SRAM | 0x24000000 | 512 KB | `dma_buf`, `usb_out_buf` |
| SRAM1/2 | 0x30000000 | 288 KB | USB PMA, CDC buffer |

**MPU:** AXI SRAM region set non-cacheable so DMA writes are immediately visible to CPU without manual cache invalidation.

---

## Buffer Chain

```
DMA circular (Word 32-bit)
    └─► dma_buf[4][4096]          ping-pong, AXI SRAM

HAL_SAI_RxHalfCpltCallback / RxCpltCallback  (ISR)
    └─► Deinterleave_And_Copy()
            ├─► mic_data[8][1024]  float32, DTCM   → FFT path
            └─► usb_in_buf[8][1024] int16, DTCM    → USB path

Check_And_Notify()  — fires when all 4 pairs ready
    ├─► memcpy(usb_out_buf ← usb_in_buf)
    ├─► xTaskNotify FLAG_FFT → FFT_Task
    └─► xTaskNotify FLAG_USB → USB_Task
```

---

## Sample Extraction (Deinterleave)

INMP441 outputs 24-bit audio **left-justified** inside a 32-bit SAI word:

```
Bit 31 ──────── Bit 8 │ Bit 7 ── Bit 0
  [    24-bit signed   │   zeros        ]
```

```c
int32_t raw_l = (int32_t)dma_buf[pair][i*2]     >> 8;  // arithmetic shift
int32_t raw_r = (int32_t)dma_buf[pair][i*2 + 1] >> 8;

// float32 for FFT  (-1.0 … +1.0)
mic_data[mic_l][i] = (float32_t)raw_l / 8388608.0f;   // ÷ 2^23

// int16 for USB PCM
usb_in_buf[mic_l][i] = (int16_t)(raw_l >> 8);
```

---

## RTOS Tasks

| Task | Priority | Stack | Trigger | Output |
|------|----------|-------|---------|--------|
| ISR (DMA) | — (hw) | — | DMA half/full | flags + memcpy |
| USB_Task | HIGH+1 (40) | 1 KB | FLAG_USB | CDC_Transmit_FS |
| FFT_Task | HIGH (39) | 8 KB | FLAG_FFT | fft_mag, TDOA |
| DOA_Task | NORMAL (24) | 1 KB | result queue | UART / LED |
| Monitor_Task | LOW (8) | 512 B | 1 s timer | IWDG, overrun count |

**IPC:**
- `FLAG_FFT` / `FLAG_USB` — `xTaskNotifyFromISR` (bitfield)
- `result_queue` — `xQueueSend` from FFT_Task to DOA_Task

---

## FFT Pipeline (per frame)

```
1. Hann window      arm_mult_f32()           × 8 mic
2. FFT 1024-pt      arm_rfft_fast_f32()      × 8 mic
3. Magnitude        arm_cmplx_mag_f32()      × 8 mic
4. GCC-PHAT         cross-spectrum + IFFT    × 28 pairs
5. TDOA             argmax of correlation    → lag × (1/Fs)
6. DOA              SRP or least-squares     → (θ, φ)
```

**Hann window** (computed once at init):
```c
hann[i] = 0.5f * (1.0f - cosf(2.0f * PI * i / (FFT_SIZE - 1)));
```

---

## Timing Budget @ 64 MHz

| Stage | Estimated time |
|-------|---------------|
| Fill 1024 samples (DMA) | 64 ms |
| ISR deinterleave × 4 pairs | < 1 ms |
| FFT × 8 mic | ~ 15 ms |
| GCC-PHAT × 28 pairs | ~ 20 ms |
| USB transmit | < 5 ms |
| **Total budget** | **64 ms/frame (16 Hz update)** |

> At 64 MHz (vs 480 MHz on H743), FFT is ~7× slower. If latency is critical, consider reducing to 512-point FFT or enabling the FPU prefetch aggressively.

---

## USB CDC Frame Format

```
Byte offset   Field            Size
0–1           Magic 0xAA55     2 B
2–3           Sequence number  2 B   (uint16, wraps at 65535)
4–16387       PCM data         16384 B  (8 ch × 1024 × int16)
16388–16389   CRC16            2 B
─────────────────────────────────────
Total                          16390 B / frame
```

**Bandwidth:** 8 × 1024 × 16-bit × 16 kHz = **2.62 Mbit/s** — within USB FS 12 Mbit/s limit.

USB_Task drops the frame (does not block) if `CDC_Transmit_FS` returns `USBD_BUSY`.

---

## Key Implementation Notes

1. **Start slaves before master** — SAI1A drives FS/SCK; slaves must be armed first.
2. **DMA unit is Word (32-bit)** — pass `DMA_FULL_WORDS` (4096) to `HAL_SAI_Receive_DMA`, not byte count.
3. **Non-cacheable AXI SRAM** — add MPU region for `0x24000000` (512 KB, non-cacheable, bufferable) to avoid stale reads.
4. **`pair_ready[]` must reset** after every notify — otherwise the second frame fires immediately.
5. **FFT stack ≥ 8 KB** — CMSIS-DSP `arm_rfft_fast_f32` uses significant stack at 1024-point.
6. **Benchmark with DWT** — `DWT->CYCCNT / 64000` gives milliseconds at 64 MHz.

---

## Quick Debug Checklist

| Check | Expected | Method |
|-------|----------|--------|
| `mic_data[m]` max ≠ 0 | Signal present | `arm_max_f32` in FFT_Task |
| FFT peak bin for 1 kHz tone | bin 64 (= 1000/16000 × 1024) | `arm_max_f32` on `fft_mag` |
| USB sequence gap | 0 dropped frames | Python: `seq[i+1]-seq[i]==1` |
| DMA overrun | 0 errors | count in `HAL_SAI_ErrorCallback` |
| TDOA synthetic 5-sample delay | lag = 5 ± 1 | inject shifted signal in code |
