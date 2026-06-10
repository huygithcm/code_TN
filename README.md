
# STM32H7A3 8-Mic Audio DOA System - Code Workflow Summary

## Project Overview
This is a **Direction of Arrival (DOA) detection system** for an **8-microphone array** running on an **STM32H7A3ZI-TQ** microcontroller. The system captures synchronized audio from 8 microphones, processes it through FFT and GCC-PHAT algorithms to estimate time differences of arrival (TDOA), and computes the sound source direction using least-squares geometry.

**Key Specifications:**
- **Microphone Configuration:** 8 mono channels (4 stereo SAI pairs)
- **Sample Rate:** 16 kHz
- **Block Size:** 1024 samples (64 ms per frame)
- **Audio Bit Depth:** 24-bit (stored in 32-bit words)
- **Memory:** Hot DSP buffers in DTCM (tightly coupled); DMA buffers in AXI SRAM (non-cacheable)

---

## Hardware Architecture

### SAI (Serial Audio Interface) Configuration
The system uses **4 SAI blocks** in a hierarchical master/slave topology:

| Block | Role | Input | Sync |
|-------|------|-------|------|
| SAI1_A | Master, RX | Channels 0-1 (Pair 0) | Generates clock/frame sync (exports to SAI2) |
| SAI1_B | Slave, RX | Channels 2-3 (Pair 1) | Synced internally to SAI1_A |
| SAI2_A | Slave, RX | Channels 4-5 (Pair 2) | External sync from SAI1_A (SYNCHRONOUS_EXT_SAI1) |
| SAI2_B | Slave, RX | Channels 6-7 (Pair 3) | External sync from SAI1_A (SYNCHRONOUS_EXT_SAI1) |

**Frame Format:** 64 bits per frame (2 active 32-bit slots per SAI block)
- Each slot holds: 24-bit audio (MSB-left-justified) + 8-bit padding
- Slave blocks are armed **before** the master so they are ready when SAI1_A generates the first clock pulse

### DMA Configuration
- **4 DMA streams** (one per SAI block), all on DMA1
- **Mode:** Circular double-buffering (PING/PONG)
- **Transfer Size:** 2048 words per half-buffer, 4096 words full buffer
- **Alignment:** Word (32-bit)
- **FIFO:** Disabled
- **Buffer Location:** AXI SRAM (non-cacheable, DMA-safe)

**Interrupt Priority:** DMA1 streams at preempt priority 5 (higher than configMAX_SYSCALL_INTERRUPT_PRIORITY, safe to use FromISR APIs)

### Clocking
- **System Clock:** 64 MHz (via PLL1 from HSE)
- **SAI Clock:** 983.04 kHz (via PLL3, achieves 16 kHz @ 61.44 MHz SAI master clock)
- **DWT Cycle Counter:** Armed at startup for cycle-accurate benchmarking

---

## Memory Layout

### Data Sections
1. **DTCM (Data TCM, 128 KB)** - Low-latency DSP hot path
   - `mic_data[8][1024]`: Normalized float32 [-1,1] per-mic samples (FFT input)
   - `mic_raw[8][1024]`: Raw int32 24-bit samples (USB streaming)
   - `hann_window[1024]`: Pre-computed Hann window
   - FFT scratch: `fft_win[1024]`, `fft_cplx[1024]`, `fft_mag[8][512]`
   - GCC-PHAT scratch: `gcc_a[1024]`, `gcc_b[1024]`, `gcc_r[1024]`, `gcc_corr[1024]`

2. **AXI SRAM (512 KB)** - Slower, DMA-safe
   - `dma_buf[4][4096]`: Raw SAI/DMA circular buffers
   - `usb_snapshot[8][1024]`: One-frame USB buffer (decouples DMA from USB)

### Cache Configuration
- **I-Cache:** Enabled
- **D-Cache:** Enabled
- **AXI SRAM:** Marked non-cacheable (MPU region) → DMA writes stay coherent
- **DTCM:** Never cached → always coherent with CPU

---

## FreeRTOS Task Architecture

The system uses **5 tasks** orchestrated by **task notifications** and a **message queue**:

### 1. **defaultTask** (Normal Priority, 512×4 words stack)
```
Purpose: Initialize USB device and idle
- Calls MX_USB_DEVICE_Init() at startup
- Then loops with 1 ms delays (low CPU burden)
```

### 2. **FFT_Task** (High Priority, 2048×4 words stack) ⭐ **Core DSP Pipeline**
```
Workflow:
  1. Call Pipeline_InitOnce() once:
     - Verify clocks + enable DWT
     - Verify SAI/DMA configuration
     - Initialize FFT, Hann window
     - Run self-tests (FFT, GCC-PHAT, DOA)
     - Start audio capture (arm circular DMA)
  
  2. Wait for DMA notification (FLAG_FFT):
     - Block until SAI1_A DMA half/full interrupt signals a fresh half-buffer
  
  3. Deinterleave all 4 SAI pairs:
     - Extract per-mic samples from circular DMA buffer
     - Convert 24-bit fixed-point to normalized float32
     - Populate mic_data[] and mic_raw[]
  
  4. FFT_ProcessAll():
     - Apply Hann window to each mic
     - Compute 1024-point real FFT
     - Extract magnitude spectrum (512 bins)
  
  5. GCC_ProcessPairs():
     - Compare mic 0 vs mics 1-7 using GCC-PHAT
     - Estimate fractional time delay (sub-sample via parabolic interpolation)
     - Store TDOA results in g_tdoa_lag_f[]
  
  6. Queue TDOA results → DOA_Task via result_queue
  
  7. Snapshot USB frame if not already in-flight (trigger USB_Task)
```
**Timing:** ~16 ms per half-buffer (10 FFT + 2 GCC-PHAT @ 16 blocks/s)

### 3. **USB_Task** (Real-Time Priority, 512×4 words stack)
```
Workflow (USB_RAW_STREAM enabled):
  1. Wait for FLAG_USB notification from FFT_Task
  
  2. Check if previous USB transfer is complete (CDC TxState == 0)
     - If yes: assemble and send new raw frame
     - If no: drop frame (back-pressure, counted in g_usb_drops)
  
  3. Frame format:
     - Header (12 bytes): 'RAW1' magic + seq + nch (8) + nsamp (1024) + fmt (int32 LE)
     - Payload (32 KB): 8 channels × 1024 samples × 4 bytes per sample
     - Total: ~32 KB per frame @ 16 frames/s ≈ 4 Mbps USB HS
  
  4. Increment g_usb_seq only on successful send (host sees gap-free sequence)
```

### 4. **DOA_Task** (Above-Normal Priority, 512×4 words stack)
```
Workflow:
  1. Block on result_queue (wait for TDOA results from FFT_Task)
  
  2. Call DOA_Compute(tdoa_lags):
     - Linear least-squares: u = M · lag_f (2×7 matrix-vector product)
     - u = unit direction (x, y components in array plane)
     - Azimuth: atan2(uy, ux) → [0, 360) degrees
     - Elevation magnitude: arccos(|u|) → [0, 90] degrees (planar array ambiguity)
  
  3. Print result once per ~16 frames (~1 Hz):
     - "DOA seq=XXX az=YY.Y el=ZZ.Z"
     - Toggle green LED on each print (visible motion indicator)
```

### 5. **Monitor_Task** (Low Priority, 512×4 words stack)
```
Workflow:
  1. Wait 1.5 s for self-tests to finish
  
  2. Print vTaskList (task names, states, priorities, stack usage) once
  
  3. Arm Independent Watchdog (IWDG):
     - 2-second timeout (configured via LSI prescaler /64 → 2 ms/tick × 1000)
     - Refreshed only when g_blocks advances
     - Frozen when debugger halts MCU
  
  4. Loop every 500 ms:
     - Refresh watchdog if pipeline is alive (g_blocks changed)
     - Print health every ~2 s:
       - Block count, overruns, FFT/GCC timing
       - USB sent/drops, free heap size, SAI errors
       - Per-task stack high-water marks
```

---

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ Audio Input: 8 Microphones (2×4 SAI pairs)                  │
└──────────────────────┬──────────────────────────────────────┘
                       │ I²S Audio (24-bit @ 16 kHz)
                       ▼
        ┌──────────────────────────────┐
        │ SAI1_A (Master, Pair 0-1)     │  Generates clock/frame sync
        │ SAI1_B (Slave, Pair 2-3)      │  Synced to SAI1_A
        │ SAI2_A (Slave, Pair 4-5)      │  External sync from SAI1_A
        │ SAI2_B (Slave, Pair 6-7)      │  External sync from SAI1_A
        └──────┬───────────────────────┘
               │ (synchronized, < 1 sample skew)
               ▼
        ┌──────────────────────────────────────────┐
        │ DMA1 (4 streams, circular double-buffer) │
        │ dma_buf[4][4096] in AXI SRAM             │
        │ Half-transfer (PING) & Full (PONG)       │
        └──────┬────────────────────────────────────┘
               │ (DMA ISR on SAI1_A half/full)
               ▼
        ┌────────────────────────────────────────────┐
        │ FFT_Task (xTaskNotifyFromISR FLAG_FFT)    │
        │ Deinterleave 4 pairs → mic_data, mic_raw  │
        └──────┬─────────────────────────────────────┘
               │
         ┌─────┴──────┐
         │             │
         ▼             ▼
    FFT Path      USB Path
    (DTCM)        (Snapshot)
         │             │
         ▼             ▼
    ┌─────────────┐  ┌──────────────────┐
    │ Hann Window │  │ usb_snapshot[8]  │ (one frame)
    │ + FFT 1024  │  │ Copy from mic_raw │
    │ → fft_mag   │  └────────┬──────────┘
    └──────┬──────┘           │ (xTaskNotify FLAG_USB)
           │                  ▼
           │          ┌─────────────────────┐
           │          │ USB_Task            │
           │          │ Assemble + Send CDC │
           │          │ 12B hdr + 32KB data │
           │          └────────┬────────────┘
           │                   │ (g_usb_seq++)
           │                   ▼
           │            Host (PC MATLAB/Python)
           │
           ▼
    ┌────────────────────────┐
    │ GCC-PHAT (7 pairs)     │
    │ mic[0] vs mic[1..7]    │
    │ → fractional TDOA lags │
    └────────┬───────────────┘
             │ (pack tdoa_result_t)
             ▼
    ┌──────────────────────────────┐
    │ result_queue (4 slots)       │
    │ → DOA_Task                   │
    └──────┬───────────────────────┘
           │
           ▼
    ┌──────────────────────────────┐
    │ DOA_Task                     │
    │ DOA_Compute(lags → az/el)    │
    │ Print: "DOA seq=X az=Y el=Z" │
    │ Toggle green LED             │
    └──────────────────────────────┘
```

---

## Key Algorithms

### FFT (Task-07)
- **Algorithm:** CMSIS-DSP arm_rfft_fast_f32 (1024-point real FFT)
- **Window:** Hann (pre-computed once at init)
- **Input:** `mic_data[m][]` (float32, normalized [-1,1])
- **Output:** `fft_mag[m][512]` (magnitude spectrum, DC at [0])
- **Self-Test:** 1 kHz sine → peak at bin 64 (expected)

### GCC-PHAT (Task-08)
- **Algorithm:** Generalized Cross-Correlation with Phase Alignment Transform
  ```
  r[n] = IFFT( Xa · conj(Xb) / |Xa · conj(Xb)| )
  ```
- **PHAT Whitening:** Divide cross-spectrum by magnitude → sharpens delay peak
- **Sub-Sample Resolution:** Parabolic interpolation around peak
- **Output:** Fractional lag in samples (positive = signal b is delayed)
- **Self-Test:** Circular shift by 5 samples → recovered lag ≈ 5

### DOA (Task-11)
- **Model:** Far-field plane-wave, 2D array (planar geometry)
- **Method:** Least-squares solution: `u = M · lag_f`
  - M = 2×7 pseudo-inverse rows (precomputed from mic_pos and C_SOUND_MPS)
  - lag_f = 7 fractional TDOA lags
- **Output:**
  - **Azimuth:** atan2(uy, ux) ∈ [0, 360)° (0° = +x axis, 90° = +y, counter-clockwise)
  - **Elevation:** arccos(|u|) ∈ [0, 90]° (0° = in-plane, 90° = overhead)
  - Planar array cannot resolve above/below → elevation is magnitude
- **Self-Test:** Synthetic source at 30° → recovered azimuth within ±2°

### Deinterleaving
- **Input:** `dma_buf[pair][offset..offset+2047]` (stereo pairs, MSB-left-justified 24-bit in 32-bit slots)
- **Process:**
  - Extract low 16 bits (sign-extended 24-bit: `(word & 0xFFFF)`)
  - Store raw int32 in `mic_raw[ch][]`
  - Normalize to float32: `(int32 >> 8) / 2^23` → [-1,1] in `mic_data[ch][]`
- **Channel Mapping:** ch = pair×2 + side (0=L, 1=R per pair)

---

## Configuration Constants

```c
#define NUM_SAI_BLOCKS       4           /* SAI1-A/B, SAI2-A/B */
#define NUM_MIC_CHANNELS     8           /* 4 pairs × 2 = 8 mono */
#define AUDIO_BLOCK_SAMPLES  1024        /* FFT size, 64 ms @ 16 kHz */
#define AUDIO_FS_HZ          16000       /* Sample rate */

#define FFT_SIZE             1024        /* 1024-point real FFT */
#define FFT_BINS             512         /* Magnitude bins (size/2) */

#define GCC_NPAIRS_LIVE      7           /* mic0 vs mic1..7 */
#define C_SOUND_MPS          343.0f      /* Speed of sound @ 20°C */
#define MIC_PAIR_SPACING_M   0.01937f    /* 19.37 mm (x-axis) */
#define MIC_INPAIR_SPACING_M 0.02710f    /* 27.1 mm (y-axis) */

#define USB_RAW_STREAM       1           /* Stream raw frames to host */
#define RAW_STREAM_SAMPLES   1024        /* Samples per channel */
#define USB_FRAME_LEN        12 + 8×1024×4 ≈ 32 KB
```

---

## Error Handling & Watchdog

### SAI/DMA Error Callback
- `HAL_SAI_ErrorCallback()` fires on overrun/FIFO errors
- Increments `g_sai_errors`, stores error code, lights red LED
- DMA continues running (non-fatal)

### Independent Watchdog (IWDG)
- **Timeout:** ~2 seconds (LSI @ 32 kHz, /64 prescaler → 2 ms/tick × 1000 ticks)
- **Refresh:** Only when `g_blocks` advances (pipeline is alive)
- **Reset Cause:** Printed on next boot (IWDG, PIN, BOR, POR, SFT)
- **Debugger:** Frozen while halted (no spurious resets during debugging)

### Back-Pressure Drops
- **USB:** If CDC TxState ≠ 0 (previous transfer still in-flight), drop frame
  - Counted in `g_usb_drops`
  - Host still sees gap-free sequence (only incremented on successful send)
- **FFT:** If FFT_Task doesn't consume the previous half-buffer before a new one arrives
  - Counted in `g_overruns`
  - Indicates real-time deadline miss

---

## Performance Targets

| Metric | Value | Notes |
|--------|-------|-------|
| FFT (8 mic) | ~10 µs | CMSIS-DSP optimized |
| GCC-PHAT (7 pairs) | ~2 µs | IFFT + peak detection |
| DOA Compute | < 1 µs | 2×7 matrix-vector MACs |
| Full DSP per frame | ~12 µs | All three combined |
| USB Latency | ~30 ms | USB HS, 32 KB frame |
| Frame Rate | 16 frames/s | 1024 samples @ 16 kHz |
| Real-Time Headroom | High | Tasks complete well before next interrupt |

---

## Testing & Self-Tests

All core algorithms run deterministic self-tests at startup (in `Pipeline_InitOnce()`):

1. **TASK-03:** Clock configuration (expect 64 MHz SYSCLK)
2. **TASK-04:** SAI/DMA hardware (all 4 blocks READY, DMA circular/word-aligned)
3. **TASK-07 (IT-01):** FFT self-test (1 kHz sine → bin 64 ±1)
4. **TASK-13 (IT-02):** Silence test (zero-in → zero-out)
5. **TASK-08:** GCC-PHAT self-test (5-sample delay → lag 5 ±1)
6. **TASK-11:** DOA self-test (synthetic 30° source → recovered azimuth ±2°)

Green LED = all tests pass; Red LED = first failure halts boot.

---

## Known Issues & Fixes

| Bug | Task | Issue | Fix |
|-----|------|-------|-----|
| BUG-04b | 09 | Pipeline init in main loop → USB heap overflow | Moved to FFT_Task (inside RTOS) |
| BUG-05 | 09 | Queue payload wrong struct → silent queue failure | Changed to carry full tdoa_result_t |
| BUG-07 | 09 | DMA started before RTOS ready | Deferred to FFT_Task at runtime |
| BUG-08 | 05 | SAI1 sync export lost after CubeMX regen | Re-apply SynchroExt fix on SAI1_A/B init |

---

## Build & Run

1. **IDE:** STM32CubeIDE (STM32CubeMX .ioc file: `code_ver2_Fs16khz.ioc`)
2. **Linker Script:** `STM32H7A3ZITXQ_FLASH.ld` (applies .DMASection → AXI SRAM, .DTCMSection → DTCM)
3. **USB:** Virtual COM port (CDC), 115200 baud UART fallback
4. **Monitor:** vTaskList + health log to UART every ~2 seconds
5. **Output:** Live DOA angles + USB raw mic frames to host

---

## Summary
This is a **real-time embedded DSP system** tightly orchestrated by FreeRTOS task notifications and a message queue. The FFT_Task is the heartbeat—it waits for DMA interrupts, deinterleaves, runs FFT/GCC-PHAT in <20 µs, and hands results to DOA_Task and USB_Task in parallel. All memory is carefully placed (DTCM for hot DSP, AXI SRAM for DMA, cache disabled on DMA regions). Self-tests at boot validate the entire pipeline before live capture. A watchdog guards against pipeline hangs.