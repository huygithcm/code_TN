# STM32H7A3ZI — Task Breakdown

## Overview

```
TASK-01  Project setup & memory map
TASK-02  MPU configuration
TASK-03  Clock verification
TASK-04  SAI + DMA initialization
TASK-05  DMA buffer & ping-pong
TASK-06  SAI callbacks & deinterleave
TASK-07  Hann window & FFT
TASK-08  GCC-PHAT & TDOA
TASK-09  RTOS tasks & IPC
TASK-10  USB CDC transmit
TASK-11  DOA output
TASK-12  Monitor & watchdog
TASK-13  Integration test
```

---

## TASK-01 — Project Setup & Memory Map

**Goal:** Create STM32CubeIDE project, configure linker to place each buffer in the correct SRAM region.

**Steps:**
1. Generate project from `code_ver2_Fs16khz.ioc` via CubeMX → STM32CubeIDE.
2. Set project encoding: right-click project → Properties → Resource → UTF-8.
3. Add custom linker sections to `STM32H7A3ZITxQ_FLASH.ld`:

```ld
MEMORY
{
  FLASH    (rx)  : ORIGIN = 0x08000000, LENGTH = 2048K
  DTCMRAM  (xrw) : ORIGIN = 0x20000000, LENGTH = 128K
  RAM      (xrw) : ORIGIN = 0x24000000, LENGTH = 512K   /* AXI SRAM */
  RAM_D2   (xrw) : ORIGIN = 0x30000000, LENGTH = 288K   /* SRAM1+2  */
}

SECTIONS
{
  .dma_buffers (NOLOAD) :
  {
    *(.DMASection)
  } >RAM        /* AXI SRAM — accessible by DMA1 */

  .usb_buffers (NOLOAD) :
  {
    *(.USBSection)
  } >RAM_D2     /* SRAM1 — USB PMA region */
}
```

4. Declare buffers with section attributes:

```c
/* Place in AXI SRAM (non-cacheable via MPU) */
__attribute__((section(".DMASection")))
uint32_t dma_buf[4][4096];          /* 4 pairs × 4096 words */

__attribute__((section(".DMASection")))
int16_t  usb_out_buf[8][1024];

/* Place in DTCM — fast CPU access, no DMA */
float32_t mic_data[8][1024];
int16_t   usb_in_buf[8][1024];
float32_t hann_window[1024];
float32_t fft_windowed[1024];
float32_t fft_out[1024];
float32_t fft_mag[8][512];
```

**Done when:** Build succeeds, `.map` file shows `dma_buf` at `0x24xxxxxx` and `mic_data` at `0x20xxxxxx`.

---

## TASK-02 — MPU Configuration

**Goal:** Mark AXI SRAM as non-cacheable so DMA writes are immediately visible to CPU.

**Why:** STM32H7 has D-Cache enabled by default. Without MPU, CPU reads stale cached data after DMA writes to `dma_buf`.

```c
void MPU_Config(void)
{
    HAL_MPU_Disable();

    MPU_Region_InitTypeDef cfg = {0};

    /* Region 0: backstop — entire 4 GB, no access (from CubeMX) */
    cfg.Enable           = MPU_REGION_ENABLE;
    cfg.Number           = MPU_REGION_NUMBER0;
    cfg.BaseAddress      = 0x00000000;
    cfg.Size             = MPU_REGION_SIZE_4GB;
    cfg.SubRegionDisable = 0x87;
    cfg.AccessPermission = MPU_REGION_NO_ACCESS;
    cfg.DisableExec      = MPU_INSTRUCTION_ACCESS_DISABLE;
    cfg.IsCacheable      = MPU_ACCESS_NOT_CACHEABLE;
    cfg.IsBufferable     = MPU_ACCESS_NOT_BUFFERABLE;
    cfg.IsShareable      = MPU_ACCESS_NOT_SHAREABLE;
    cfg.TypeExtField     = MPU_TEX_LEVEL0;
    HAL_MPU_ConfigRegion(&cfg);

    /* Region 1: AXI SRAM — non-cacheable, bufferable, full access */
    cfg.Number           = MPU_REGION_NUMBER1;
    cfg.BaseAddress      = 0x24000000;
    cfg.Size             = MPU_REGION_SIZE_512KB;
    cfg.SubRegionDisable = 0x00;
    cfg.AccessPermission = MPU_REGION_FULL_ACCESS;
    cfg.DisableExec      = MPU_INSTRUCTION_ACCESS_DISABLE;
    cfg.IsCacheable      = MPU_ACCESS_NOT_CACHEABLE;   /* <-- key */
    cfg.IsBufferable     = MPU_ACCESS_BUFFERABLE;
    cfg.IsShareable      = MPU_ACCESS_NOT_SHAREABLE;
    cfg.TypeExtField     = MPU_TEX_LEVEL1;
    HAL_MPU_ConfigRegion(&cfg);

    HAL_MPU_Enable(MPU_PRIVILEGED_DEFAULT);
}
```

**Done when:** Writing a known pattern to `dma_buf` from DMA and reading it back from CPU returns the correct value without `SCB_InvalidateDCache_by_Addr`.

---

## TASK-03 — Clock Verification

**Goal:** Confirm SYSCLK = 64 MHz and SAI clock = 49.2 MHz before enabling audio peripherals.

```c
void Clock_Verify(void)
{
    uint32_t sysclk = HAL_RCC_GetSysClockFreq();
    uint32_t hclk   = HAL_RCC_GetHCLKFreq();
    uint32_t pclk1  = HAL_RCC_GetPCLK1Freq();

    /* Print via USART3 VCP (115200 baud) */
    printf("SYSCLK : %lu Hz\r\n", sysclk);   /* expect 64 000 000 */
    printf("HCLK   : %lu Hz\r\n", hclk);     /* expect 64 000 000 */
    printf("PCLK1  : %lu Hz\r\n", pclk1);    /* expect 64 000 000 */

    /* Enable DWT for cycle-accurate benchmarking */
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
    DWT->CYCCNT       = 0;
    DWT->CTRL        |= DWT_CTRL_CYCCNTENA_Msk;
}
```

**Done when:** UART prints `SYSCLK: 64000000`.

---

## TASK-04 — SAI + DMA Initialization

**Goal:** Verify CubeMX-generated `MX_SAI1_Init`, `MX_SAI2_Init`, `MX_DMA_Init` are correct for 8-mic capture.

**Checklist against `.ioc` settings:**

| Parameter | Expected value |
|-----------|---------------|
| SAI1-A mode | Master RX, async |
| SAI1-B mode | Slave RX, sync to SAI1-A |
| SAI2-A/B mode | Slave RX, extern sync (SAI1) |
| Data size | 24-bit |
| Slot size | 32-bit |
| Slot count | 2 (slots 0 & 1) |
| Frame length | 64 bits |
| FS polarity | Active low |
| FS offset | Before first bit |
| DMA width | Word (32-bit) |
| DMA mode | Circular |
| DMA FIFO | Disabled |

**Verify in generated code (`sai.c`):**

```c
/* Should match — example for SAI1-A */
hsai_BlockA1.Init.AudioMode      = SAI_MODEMASTER_RX;
hsai_BlockA1.Init.Synchro        = SAI_ASYNCHRONOUS;
hsai_BlockA1.Init.DataSize       = SAI_DATASIZE_24;
hsai_BlockA1.Init.SlotSize       = SAI_SLOTSIZE_32B;
hsai_BlockA1.Init.NbSlot         = 2;
hsai_BlockA1.Init.SlotActive     = SAI_SLOTACTIVE_0 | SAI_SLOTACTIVE_1;
hsai_BlockA1.Init.FirstBit       = SAI_FIRSTBIT_MSB;
hsai_BlockA1.Init.ClockStrobing  = SAI_CLOCKSTROBING_FALLINGEDGE;
```

**Done when:** No `HAL_ERROR` returned from `MX_SAI1_Init` / `MX_SAI2_Init`.

---

## TASK-05 — DMA Buffer & Ping-Pong

**Goal:** Allocate and validate the ping-pong DMA buffer. Confirm size calculation.

**Size math:**
```
Per pair:
  1024 samples × 2 slots (L+R) = 2048 words  ← one half (PING or PONG)
  2048 × 2                     = 4096 words  ← full circular buffer

4 pairs:
  dma_buf[4][4096]  = 65536 bytes total in AXI SRAM
```

**Buffer regions:**
```c
#define DMA_HALF_WORDS  2048   /* words per half (PING or PONG) */
#define DMA_FULL_WORDS  4096   /* words per pair, passed to HAL  */
```

**Start function — slaves first, master last:**
```c
void Audio_Start(void)
{
    memset((void*)pair_ready, 0, sizeof(pair_ready));
    memset(dma_buf, 0, sizeof(dma_buf));

    /* Arm slaves before master generates FS/SCK */
    HAL_SAI_Receive_DMA(&hsai_BlockB2, (uint8_t*)dma_buf[3], DMA_FULL_WORDS);
    HAL_SAI_Receive_DMA(&hsai_BlockA2, (uint8_t*)dma_buf[2], DMA_FULL_WORDS);
    HAL_SAI_Receive_DMA(&hsai_BlockB1, (uint8_t*)dma_buf[1], DMA_FULL_WORDS);
    HAL_SAI_Receive_DMA(&hsai_BlockA1, (uint8_t*)dma_buf[0], DMA_FULL_WORDS);
}
```

**Done when:** Logic analyzer on PE4 (FS) and PE6 (SD) shows clean I2S-like frames at 16 kHz.

---

## TASK-06 — SAI Callbacks & Deinterleave

**Goal:** In ISR callbacks, extract 1024 samples per mic into `mic_data` and `usb_in_buf`.

```c
static uint8_t Get_Pair(SAI_HandleTypeDef *hsai)
{
    if (hsai->Instance == SAI1_Block_A) return 0;
    if (hsai->Instance == SAI1_Block_B) return 1;
    if (hsai->Instance == SAI2_Block_A) return 2;
    if (hsai->Instance == SAI2_Block_B) return 3;
    return 0xFF;
}

static void Deinterleave(uint32_t *src, uint32_t offset, uint8_t pair)
{
    uint32_t *buf   = src + offset;
    uint8_t   mic_l = pair * 2;
    uint8_t   mic_r = pair * 2 + 1;

    for (int i = 0; i < 1024; i++) {
        /* 24-bit data left-justified: shift right 8 to get signed 24-bit */
        int32_t raw_l = (int32_t)buf[i * 2]     >> 8;
        int32_t raw_r = (int32_t)buf[i * 2 + 1] >> 8;

        mic_data[mic_l][i] = (float32_t)raw_l / 8388608.0f;
        mic_data[mic_r][i] = (float32_t)raw_r / 8388608.0f;

        usb_in_buf[mic_l][i] = (int16_t)(raw_l >> 8);
        usb_in_buf[mic_r][i] = (int16_t)(raw_r >> 8);
    }
}

void HAL_SAI_RxHalfCpltCallback(SAI_HandleTypeDef *hsai)
{
    uint8_t p = Get_Pair(hsai);
    if (p == 0xFF) return;
    Deinterleave(dma_buf[p], 0, p);            /* PING */
    pair_ready[p] = 1;
    Check_And_Notify();
}

void HAL_SAI_RxCpltCallback(SAI_HandleTypeDef *hsai)
{
    uint8_t p = Get_Pair(hsai);
    if (p == 0xFF) return;
    Deinterleave(dma_buf[p], DMA_HALF_WORDS, p); /* PONG */
    pair_ready[p] = 1;
    Check_And_Notify();
}

static void Check_And_Notify(void)
{
    for (int i = 0; i < 4; i++)
        if (!pair_ready[i]) return;

    memcpy(usb_out_buf, usb_in_buf, sizeof(usb_out_buf));
    memset((void*)pair_ready, 0, sizeof(pair_ready));

    BaseType_t woken = pdFALSE;
    xTaskNotifyFromISR(fft_task_handle, FLAG_FFT | FLAG_USB,
                       eSetBits, &woken);
    portYIELD_FROM_ISR(woken);
}
```

**Done when:** `mic_data[0][i]` shows values in `[-1.0, +1.0]` range when mic receives a tone.

---

## TASK-07 — Hann Window & FFT

**Goal:** Apply Hann window and compute 1024-point FFT for all 8 mics using CMSIS-DSP.

**Add to `CMakeLists.txt` or IDE linker:**
```
-larm_cortexM7lfsp_math   (H7A3 = Cortex-M7 with FPU)
-DARM_MATH_CM7
-D__FPU_PRESENT=1
```

```c
static arm_rfft_fast_instance_f32 fft_inst;

void FFT_Task_Init(void)
{
    arm_rfft_fast_init_f32(&fft_inst, 1024);

    /* Pre-compute Hann window once */
    for (int i = 0; i < 1024; i++)
        hann_window[i] = 0.5f * (1.0f - cosf(2.0f * M_PI * i / 1023.0f));
}

void FFT_Task(void *arg)
{
    FFT_Task_Init();
    uint32_t flags;

    while (1) {
        xTaskNotifyWait(0, FLAG_FFT, &flags, portMAX_DELAY);

        uint32_t t0 = DWT->CYCCNT;

        for (int m = 0; m < 8; m++) {
            arm_mult_f32(mic_data[m], hann_window, fft_windowed, 1024);
            arm_rfft_fast_f32(&fft_inst, fft_windowed, fft_out, 0);
            arm_cmplx_mag_f32(fft_out, fft_mag[m], 512);
        }

        uint32_t cycles = DWT->CYCCNT - t0;
        float    ms     = (float)cycles / 64000.0f;  /* @ 64 MHz */
        /* Expected: < 20 ms */

        Compute_GCC_PHAT_All_Pairs();
    }
}
```

**Done when:** Feeding a 1 kHz sine to mic 0 produces `fft_mag[0]` peak at bin 64 (`= 1000 / 16000 × 1024`).

---

## TASK-08 — GCC-PHAT & TDOA

**Goal:** Compute time delay between each mic pair using GCC-PHAT.

```c
/* Temp buffers for cross-spectrum */
static float32_t gcc_in_a[1024];
static float32_t gcc_in_b[1024];
static float32_t gcc_cross[1024];
static float32_t gcc_corr[1024];

/*
 * Returns lag in samples. Positive = signal arrives at mic_a first.
 * Max valid lag = ±(d / 343) × Fs, where d = mic spacing in metres.
 */
int32_t GCC_PHAT(float32_t *mic_a, float32_t *mic_b, int n)
{
    /* FFT both signals */
    arm_rfft_fast_f32(&fft_inst, mic_a, gcc_in_a, 0);
    arm_rfft_fast_f32(&fft_inst, mic_b, gcc_in_b, 0);

    /* Cross-spectrum: X_a × conj(X_b) */
    arm_cmplx_mult_cmplx_f32(gcc_in_a, gcc_in_b, gcc_cross, n / 2);

    /* PHAT weighting: divide by magnitude */
    float32_t mag[512];
    arm_cmplx_mag_f32(gcc_cross, mag, n / 2);
    for (int k = 0; k < n / 2; k++) {
        float32_t m = (mag[k] > 1e-10f) ? mag[k] : 1e-10f;
        gcc_cross[k * 2]     /= m;
        gcc_cross[k * 2 + 1] /= m;
    }

    /* IFFT → correlation */
    arm_rfft_fast_f32(&fft_inst, gcc_cross, gcc_corr, 1);

    /* Find peak → lag */
    float32_t maxVal;
    uint32_t  maxIdx;
    arm_max_f32(gcc_corr, n, &maxVal, &maxIdx);

    int32_t lag = (int32_t)maxIdx;
    if (lag > n / 2) lag -= n;   /* unwrap negative lags */
    return lag;
}

void Compute_GCC_PHAT_All_Pairs(void)
{
    /* 28 unique pairs from 8 mics */
    for (int a = 0; a < 8; a++) {
        for (int b = a + 1; b < 8; b++) {
            int32_t lag = GCC_PHAT(mic_data[a], mic_data[b], 1024);
            float   tdoa = (float)lag / 16000.0f;  /* seconds */

            /* Sanity check: |tdoa| <= mic_spacing / 343 m/s */
            tdoa_result[a][b] = tdoa;
        }
    }
    xQueueSend(result_queue, tdoa_result, 0);
}
```

**Done when:** Synthetic test — `mic_data[1]` shifted by 5 samples → `GCC_PHAT` returns lag = 5 ± 1.

---

## TASK-09 — RTOS Tasks & IPC

**Goal:** Create all tasks, queues, and notification flags.

```c
/* Handles */
TaskHandle_t  fft_task_handle;
TaskHandle_t  usb_task_handle;
TaskHandle_t  doa_task_handle;
TaskHandle_t  monitor_task_handle;
QueueHandle_t result_queue;

#define FLAG_FFT  (1UL << 0)
#define FLAG_USB  (1UL << 1)

void RTOS_Init(void)
{
    result_queue = xQueueCreate(4, sizeof(tdoa_result));

    xTaskCreate(FFT_Task,     "FFT",     2048, NULL, 39, &fft_task_handle);
    xTaskCreate(USB_Task,     "USB",      512, NULL, 40, &usb_task_handle);
    xTaskCreate(DOA_Task,     "DOA",      512, NULL, 24, &doa_task_handle);
    xTaskCreate(Monitor_Task, "MON",      256, NULL,  8, &monitor_task_handle);

    vTaskStartScheduler();
}
```

**Stack sizes in words (×4 = bytes):**

| Task | Words | Bytes |
|------|-------|-------|
| FFT_Task | 2048 | 8 KB |
| USB_Task | 512 | 2 KB |
| DOA_Task | 512 | 2 KB |
| Monitor_Task | 256 | 1 KB |

**Done when:** FreeRTOS task list (via `vTaskList`) shows all 4 tasks in Ready/Blocked state.

---

## TASK-10 — USB CDC Transmit

**Goal:** Send 8-channel PCM data to PC at ~16 Hz frame rate.

**Frame format:**
```
[0x55 0xAA] [seq_hi seq_lo] [ch0..ch7 × 1024 × int16] [crc_hi crc_lo]
  2 bytes       2 bytes              16384 bytes              2 bytes
  ─────────────────────────────────────────────────────────────────────
  Total: 16390 bytes / frame
```

```c
static uint8_t usb_frame[16390];
static uint16_t usb_seq = 0;

void USB_Task(void *arg)
{
    uint32_t flags;
    while (1) {
        xTaskNotifyWait(0, FLAG_USB, &flags, portMAX_DELAY);

        /* Header */
        usb_frame[0] = 0x55;
        usb_frame[1] = 0xAA;
        usb_frame[2] = (uint8_t)(usb_seq >> 8);
        usb_frame[3] = (uint8_t)(usb_seq & 0xFF);
        usb_seq++;

        /* PCM payload */
        memcpy(&usb_frame[4], usb_out_buf, sizeof(usb_out_buf));

        /* CRC16 (optional but recommended) */
        uint16_t crc = CRC16(usb_frame, 16388);
        usb_frame[16388] = (uint8_t)(crc >> 8);
        usb_frame[16389] = (uint8_t)(crc & 0xFF);

        /* Non-blocking send — drop frame if USB busy */
        if (CDC_Transmit_FS(usb_frame, sizeof(usb_frame)) != USBD_OK) {
            BSP_LED_Toggle(LED_RED);   /* visual indicator of dropped frame */
        }
    }
}
```

**Done when:** Python script on PC receives frames with no sequence gap for 60 seconds.

```python
# pc_verify.py
import serial, struct
port = serial.Serial('COM_PORT', timeout=2)
prev_seq = None
while True:
    data = port.read(16390)
    if data[0:2] != b'\x55\xaa': continue
    seq = struct.unpack('>H', data[2:4])[0]
    if prev_seq is not None and seq != (prev_seq + 1) % 65536:
        print(f"DROPPED FRAME: expected {prev_seq+1}, got {seq}")
    prev_seq = seq
```

---

## TASK-11 — DOA Output

**Goal:** Convert TDOA matrix to direction (azimuth θ, elevation φ) and output via UART.

```c
void DOA_Task(void *arg)
{
    float tdoa_buf[8][8];
    while (1) {
        if (xQueueReceive(result_queue, tdoa_buf, portMAX_DELAY) == pdTRUE) {
            float theta, phi;
            Compute_DOA(tdoa_buf, &theta, &phi);

            printf("DOA: theta=%.1f deg  phi=%.1f deg\r\n", theta, phi);
            BSP_LED_Toggle(LED_GREEN);
        }
    }
}
```

**Done when:** Moving a speaker around the mic array changes the reported angle accordingly.

---

## TASK-12 — Monitor & Watchdog

**Goal:** Feed IWDG, count DMA overruns, report stack high-water marks.

```c
volatile uint32_t dma_overrun_count = 0;

void HAL_SAI_ErrorCallback(SAI_HandleTypeDef *hsai)
{
    dma_overrun_count++;
    BSP_LED_On(LED_RED);
}

void Monitor_Task(void *arg)
{
    MX_IWDG_Init();   /* timeout ~1 s */

    while (1) {
        HAL_IWDG_Refresh(&hiwdg);

        printf("[MON] overruns=%lu  fft_stack=%u  usb_stack=%u\r\n",
               dma_overrun_count,
               uxTaskGetStackHighWaterMark(fft_task_handle),
               uxTaskGetStackHighWaterMark(usb_task_handle));

        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
```

**Done when:** `overruns=0` after 60 s of continuous capture, stack high-water mark > 10% of allocated stack.

---

## TASK-13 — Integration Test

**Goal:** End-to-end validation with a real speaker source.

| Test | Input | Expected result | Pass criteria |
|------|-------|-----------------|---------------|
| IT-01 Tone bin | 1 kHz sine → mic 0 | `fft_mag[0]` peak at bin 64 | maxIdx == 64 ± 1 |
| IT-02 Silence | No sound | All `mic_data` ≈ 0 | max < 0.001 |
| IT-03 TDOA synthetic | mic[1] = mic[0] shift 5 samples | lag = 5 | within ±1 sample |
| IT-04 USB continuity | 60 s capture | 0 dropped frames | seq gap == 0 |
| IT-05 DOA sweep | Speaker at 0°, 45°, 90° | Reported angle within ±10° | 3/3 positions correct |
| IT-06 Overrun | Run 10 min | No DMA error | overrun_count == 0 |
| IT-07 Watchdog | Suspend FFT_Task (test only) | MCU resets within 1 s | confirmed by LED blink reset |

---

## Implementation Order

```
TASK-01 → TASK-02 → TASK-03   (setup — no hardware needed beyond UART)
    ↓
TASK-04 → TASK-05              (SAI + DMA — verify with logic analyzer)
    ↓
TASK-06                         (callbacks — verify mic_data values)
    ↓
TASK-07                         (FFT — verify with tone input)
    ↓
TASK-08                         (GCC-PHAT — verify with synthetic delay)
    ↓
TASK-09                         (RTOS wiring)
    ↓
TASK-10 → TASK-11 → TASK-12    (USB, DOA output, monitor)
    ↓
TASK-13                         (full integration)
```

Each task can be unit-tested independently before wiring into the next.
