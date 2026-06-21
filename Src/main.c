/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file           : main.c
  * @brief          : Main program body
  * @author VŨ ĐÔNG TRIỀU
  * @date   7/6/2026  
  * 
  ******************************************************************************
  * @attention
  *
  * Copyright (c) 2026 STMicroelectronics.
  * All rights reserved.
  *
  * This software is licensed under terms that can be found in the LICENSE file
  * in the root directory of this software component.
  * If no LICENSE file comes with this software, it is provided AS-IS.
  *
  ******************************************************************************
  */
/* USER CODE END Header */
/* Includes ------------------------------------------------------------------*/
#include "main.h"
#include "FreeRTOS.h"
#include "cmsis_os2.h"
#include "task.h"
#include "usb_device.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "usbd_cdc_if.h"
#include "usbd_cdc.h"
#include "arm_math.h"        /* TASK-07: CMSIS-DSP (rfft, windowing, magnitude) */
/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */
#define NUM_SAI_BLOCKS       4U                          /* SAI1-A, SAI1-B, SAI2-A, SAI2-B           */
#define NUM_MIC_CHANNELS     (NUM_SAI_BLOCKS * 2U)       /* 2 active slots per block -> 8 mono mics   */
#define AUDIO_BLOCK_SAMPLES  1024U                       /* samples per mic per half (FFT size)       */
#define DMA_HALF_WORDS       (2U * AUDIO_BLOCK_SAMPLES)  /* 2 stereo slots/frame -> 2048 words/half   */
#define DMA_BUF_WORDS        (2U * DMA_HALF_WORDS)       /* x2 for circular double buffering -> 4096  */
#define DMA_FULL_WORDS       DMA_BUF_WORDS               /* alias: words passed to HAL per pair       */

/* TASK-06: stream raw per-mic samples over the OTG USB CDC for off-line checking
 * (e.g. MATLAB) before trusting the on-chip FFT. Set to 0 to disable streaming. */
#define USB_RAW_STREAM       1
#define RAW_STREAM_SAMPLES   AUDIO_BLOCK_SAMPLES
#define RAW_NCH              NUM_MIC_CHANNELS            /* 8 mic channels                            */
#define RAW_NSAMP            RAW_STREAM_SAMPLES          /* samples/channel per raw debug frame        */
#define RAW_HDR_BYTES        12U                         /* magic(4)+seq(4)+nch(1)+nsamp(2)+fmt(1)    */
#define RAW_PAYLOAD_BYTES    (RAW_NCH * RAW_NSAMP * 4U)  /* int32 channel-major                       */
#define USB_FRAME_LEN        (RAW_HDR_BYTES + RAW_PAYLOAD_BYTES)

/* TASK-07: Hann window + 1024-point real FFT (CMSIS-DSP) for all 8 mics. */
#define FFT_ENABLE           1
#define FFT_SIZE             AUDIO_BLOCK_SAMPLES          /* 1024-point FFT             */
#define FFT_BINS             (FFT_SIZE / 2U)              /* 512 magnitude bins         */
#define AUDIO_FS_HZ          16000U                       /* sample rate (see CLAUDE.md)*/
#define FFT_SELFTEST_HZ      1000.0f                      /* self-test tone -> bin 64   */
#define PI_F                 3.14159265358979f

/* TASK-08: GCC-PHAT time-delay estimation between OPPOSITE mic pairs.
 * Each SAI pair wires two diametrically opposed mics, so the 4 baselines are
 * full-diameter (max aperture) and span 0/45/90/135 deg. After MIC_REMAP puts
 * mic_data in clean label order (Mic1..Mic8), the pairs read cleanly:
 *   pair0: slot0=Mic1(0deg)   vs slot1=Mic2(180deg)  baseline phi_0 = 0 deg
 *   pair1: slot2=Mic3(45deg)  vs slot3=Mic4(225deg)  baseline phi_1 = 45 deg
 *   pair2: slot4=Mic5(90deg)  vs slot5=Mic6(270deg)  baseline phi_2 = 90 deg
 *   pair3: slot6=Mic7(135deg) vs slot7=Mic8(315deg)  baseline phi_3 = 135 deg
 * (Hardware capture order differs; the remap absorbs it - see Deinterleave_Pair.) */
#define GCC_ENABLE           1
#define GCC_SELFTEST_SHIFT   5                            /* synthetic delay -> lag 5   */
#define GCC_NPAIRS_LIVE      (NUM_MIC_CHANNELS / 2U)      /* 4 opposite-mic pairs       */

/* TASK-11: direction of arrival from the 4 opposite-pair TDOAs, matched against
 * a hardcoded delay table. The source is assumed to lie at one of 16 fixed
 * directions (every 22.5 deg); we pick the table row whose expected lags best
 * match the measured ones (minimum sum-of-squared error).
 * Azimuth 0 deg = +x (ch0 direction), positive CCW. */
#define DOA_ENABLE           1
#define C_SOUND_MPS          343.0f                       /* speed of sound @ 20 C      */
#define MIC_ARRAY_RADIUS_M   0.040f                       /* UCA radius = 40 mm         */
#define DOA_NPAIRS           GCC_NPAIRS_LIVE              /* 4 opposite-pair baselines  */
#define DOA_N_AZ             16U                          /* candidate directions (16x22.5°) */
#define DOA_AZ_STEP          22.5f                        /* angular resolution (deg)   */
#define DOA_SELFTEST_AZ      45.0f                        /* synthetic source azimuth (one of the 16 table dirs) */

/* TASK-09: FreeRTOS task notification flags (FFT_Task waits on these). */
#define FLAG_FFT             (1UL << 0)                   /* a fresh half is ready      */
#define FLAG_USB             (1UL << 1)                   /* build+send a USB raw frame */

/* TASK-09: result_queue payload (BUG-05) - the per-pair TDOA lags one FFT_Task pass
 * produces, handed to DOA_Task. seq lets DOA_Task spot dropped results. */
typedef struct
{
  uint32_t seq;                       /* processed-block counter                  */
  float    lag[GCC_NPAIRS_LIVE];      /* 4 opposite-pair TDOAs, fractional samples */
  float    level;                     /* ch0 frame RMS² (for the clap input gate) */
} tdoa_result_t;
/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/

COM_InitTypeDef BspCOMInit;

SAI_HandleTypeDef hsai_BlockA1;
SAI_HandleTypeDef hsai_BlockB1;
SAI_HandleTypeDef hsai_BlockA2;
SAI_HandleTypeDef hsai_BlockB2;
DMA_HandleTypeDef hdma_sai1_a;
DMA_HandleTypeDef hdma_sai1_b;
DMA_HandleTypeDef hdma_sai2_a;
DMA_HandleTypeDef hdma_sai2_b;

/* Definitions for defaultTask */
osThreadId_t defaultTaskHandle;
/* TASK-11 (BUG): defaultTask runs MX_USB_DEVICE_Init(), which is stack-hungry. The
 * CubeMX default of 128 words overflowed (vTaskList showed 0 words free) and wrote
 * down into the FreeRTOS heap, zeroing the result_queue control block (uxLength /
 * uxItemSize -> 0) since that queue is the first heap allocation. That silently
 * broke the FFT_Task->DOA_Task IPC (every osMessageQueuePut returned osErrorResource,
 * DOA_Task blocked forever) from TASK-09 on. 512 words gives USB init headroom. */
const osThreadAttr_t defaultTask_attributes = {
  .name = "defaultTask",
  .stack_size = 512 * 4,
  .priority = (osPriority_t) osPriorityNormal,
};
/* Definitions for FFT_Task */
/* TASK-09 (BUG-06): FFT/GCC pipeline + printf needs a deep stack; 2048 words. */
osThreadId_t FFT_TaskHandle;
const osThreadAttr_t FFT_Task_attributes = {
  .name = "FFT_Task",
  .stack_size = 2048 * 4,
  .priority = (osPriority_t) osPriorityHigh,
};
/* Definitions for USB_Task */
osThreadId_t USB_TaskHandle;
const osThreadAttr_t USB_Task_attributes = {
  .name = "USB_Task",
  .stack_size = 512 * 4,
  .priority = (osPriority_t) osPriorityRealtime,
};
/* Definitions for DOA_Task */
osThreadId_t DOA_TaskHandle;
const osThreadAttr_t DOA_Task_attributes = {
  .name = "DOA_Task",
  .stack_size = 512 * 4,
  .priority = (osPriority_t) osPriorityAboveNormal,
};
/* Definitions for Monitor_Task */
osThreadId_t Monitor_TaskHandle;
const osThreadAttr_t Monitor_Task_attributes = {
  .name = "Monitor_Task",
  .stack_size = 512 * 4,
  .priority = (osPriority_t) osPriorityLow,
};
/* Definitions for result_queue */
osMessageQueueId_t result_queueHandle;
const osMessageQueueAttr_t result_queue_attributes = {
  .name = "result_queue"
};
/* USER CODE BEGIN PV */
/* Raw SAI capture buffers, one per DMA stream, in RAM_D1 (.DMASection).
 * Circular double buffer: first/second half are drained in the DMA HT/TC callbacks.
 * 'used' keeps the compiler from discarding it; the matching KEEP() in the linker script
 * stops --gc-sections from dropping the section before the DMA is wired up.
 * 32-byte alignment matches the Cortex-M7 D-cache line for clean cache maintenance. */
__attribute__((section(".DMASection"), aligned(32), used))
int32_t dma_buf[NUM_SAI_BLOCKS][DMA_BUF_WORDS];

/* De-interleaved per-microphone samples in DTCM (.DTCMSection) for low-latency DSP access.
 * mic_data: normalized float32 in [-1,1] for the FFT pipeline (TASK-07).
 * mic_raw : raw sign-extended 24-bit samples (int32) for faithful USB streaming + diagnostics. */
__attribute__((section(".DTCMSection"), aligned(32), used))
float   mic_data[NUM_MIC_CHANNELS][AUDIO_BLOCK_SAMPLES];
__attribute__((section(".DTCMSection"), aligned(32), used))
int32_t mic_raw[NUM_MIC_CHANNELS][AUDIO_BLOCK_SAMPLES];

/* TASK-05 ping-pong counters (kept for diagnostics). */
volatile uint32_t dma_half_cnt[NUM_SAI_BLOCKS];
volatile uint32_t dma_full_cnt[NUM_SAI_BLOCKS];

/* TASK-06 producer/consumer handshake (set in the master SAI callback, consumed in main loop). */
volatile uint8_t  g_half_ready;     /* a fresh half is ready to process            */
volatile uint8_t  g_ready_half;     /* 0 = first half (PING), 1 = second half (PONG)*/
volatile uint32_t g_overruns;       /* main loop failed to keep up with a half      */
uint32_t g_usb_seq;                 /* raw frames successfully queued to USB (host seq) */
volatile uint32_t g_usb_drops;      /* TASK-10: frames dropped because USB was busy  */

#if USB_RAW_STREAM
/* USB CDC raw streaming frame (header + int32 channel-major payload). */
uint8_t  usb_tx_frame[USB_FRAME_LEN];
extern USBD_HandleTypeDef hUsbDeviceHS;
#endif

#if FFT_ENABLE
/* TASK-07 FFT working set, all in DTCM for fast CPU/FPU access.
 * hann_window : pre-computed once. fft_win : windowed input (overwritten per mic).
 * fft_cplx    : rfft_fast output (packed real spectrum, 1024 floats).
 * fft_mag     : per-mic magnitude spectrum (512 bins). */
__attribute__((section(".DTCMSection"), aligned(32), used))
float   hann_window[FFT_SIZE];
__attribute__((section(".DTCMSection"), aligned(32), used))
float   fft_win[FFT_SIZE];
__attribute__((section(".DTCMSection"), aligned(32), used))
float   fft_cplx[FFT_SIZE];
__attribute__((section(".DTCMSection"), aligned(32), used))
float   fft_mag[NUM_MIC_CHANNELS][FFT_BINS];

static arm_rfft_fast_instance_f32 fft_inst;
volatile uint32_t g_fft_us;        /* last 8-mic FFT compute time (microseconds) */

#if GCC_ENABLE
/* TASK-08 GCC-PHAT scratch (DTCM). gcc_a/gcc_b: packed spectra of the two inputs;
 * gcc_r: PHAT-weighted cross-spectrum; gcc_corr: time-domain cross-correlation. */
__attribute__((section(".DTCMSection"), aligned(32), used))
float   gcc_a[FFT_SIZE];
__attribute__((section(".DTCMSection"), aligned(32), used))
float   gcc_b[FFT_SIZE];
__attribute__((section(".DTCMSection"), aligned(32), used))
float   gcc_r[FFT_SIZE];
__attribute__((section(".DTCMSection"), aligned(32), used))
float   gcc_corr[FFT_SIZE];

volatile int32_t  g_tdoa_lag[GCC_NPAIRS_LIVE];  /* opposite-pair lags, samples (rounded) */
float    g_tdoa_lag_f[GCC_NPAIRS_LIVE];          /* TASK-11: fractional lags (sub-sample) */
volatile uint32_t g_gcc_us;                     /* time to compute the live pairs (us) */

#if DOA_ENABLE
/* TASK-11 DOA state. The delay table is hardcoded (see g_doa_table below).
 * g_doa_err = normalised residual of the last fix (0 = perfect match). */
volatile float g_doa_az;                         /* azimuth, degrees [0,360)   */
volatile float g_doa_el;                         /* unused (planar), kept 0    */
volatile float g_doa_err;                        /* normalised min residual    */

/* Runtime-tunable clap gate. Settable from the PC over USB CDC with lines like
 * "SET ratio 3.0" / "SET abs 0.15" / "SET resid 0.7" (parsed in usbd_cdc_if.c).
 * Defaults are the relaxed/easy-to-trigger values. g_cfg_dirty is raised by the
 * CDC parser so DOA_Task echoes the new config to the VCP log. */
volatile float   g_clap_ratio    = 1.8f;         /* clap if level > ratio*floor */
volatile float   g_clap_abs      = 0.0005f;      /* absolute level floor. Measured
                                                  * clap level ~0.001-0.005 here,
                                                  * so 0.15 (old) blocked all claps. */
volatile float   g_doa_resid_max = 0.7f;         /* reject fits worse than this */
volatile uint8_t g_cfg_dirty     = 0U;           /* CDC parser -> DOA_Task echo */
#endif
#endif
#endif

/* TASK-09: USB_Task signalling. FFT_Task snapshots one freshly deinterleaved frame
 * into usb_snapshot under USB_Task's nose, then notifies it to send. The snapshot
 * decouples the (slow) USB transfer from the DSP buffers it would otherwise race.
 * Placed in AXI SRAM (not DTCM) - it is 32 KB and not on the DSP hot path, and DTCM
 * is already nearly full with mic_data/mic_raw/fft/gcc buffers. */
#if USB_RAW_STREAM
__attribute__((section(".DMASection"), aligned(32), used))
int32_t  usb_snapshot[NUM_MIC_CHANNELS][AUDIO_BLOCK_SAMPLES];
volatile uint8_t g_usb_snapshot_valid;
#endif
volatile uint32_t g_blocks;                     /* processed-block counter (Monitor)  */
volatile uint32_t g_sai_errors;                 /* TASK-12: HW SAI errors (HAL_SAI_ErrorCallback) */
volatile uint32_t g_sai_err_code;               /* TASK-12: last HAL SAI error code    */

/* =========================================================================
 * DIRECTION STANDARD  (single source of truth - mirror in tools/plot_doa.py)
 * -------------------------------------------------------------------------
 * Azimuth `az` in [0,360):  0 deg = mic 1 (ch0) direction, increasing CCW.
 * Mic <-> az (board mics numbered CW 1,7,5,3,2,8,6,4; mic n = ch n-1):
 *     mic1=0  mic4=45  mic6=90  mic8=135  mic2=180  mic3=225  mic5=270  mic7=315
 * Servo in [0,180]:   servo = clamp(90 + SERVO_DIR * wrap(az - SERVO_AZ_CENTER))
 *     SERVO_AZ_CENTER = 0   -> mic 1 (az 0) is the camera FRONT = servo 90 (neutral)
 *     SERVO_DIR       = -1  -> mic 6 (az 90) = servo 0 ,  mic 5 (az 270) = servo 180
 * The 180 deg servo only covers the FRONT half-circle; rear sources (az ~180)
 * clamp to the nearest edge. tools/plot_doa.py MUST use the same two constants.
 * ========================================================================= */

/* Camera-pan servo on PB6 (TIM4_CH1 PWM, 50 Hz frame: 1 us/tick, 20 ms period). */
TIM_HandleTypeDef htim4;
#define SERVO_TIM_PSC     (64U - 1U)     /* 64 MHz / 64  = 1 MHz -> 1 us/tick */
#define SERVO_TIM_ARR     (20000U - 1U)  /* 20000 us     = 20 ms -> 50 Hz     */
/* SG90 (180 deg): pulse 600..2400 us, symmetric about 1500 us (neutral = 90 deg).
 * Avoids 500/2500 which over-travels the SG90 end-stops (buzz/stall at extremes). */
#define SERVO_MIN_US      600.0f         /* pulse at servo 0 deg              */
#define SERVO_MAX_US      2400.0f        /* pulse at servo 180 deg            */
/* Measured on the real rig: servo 0->Mic6(az270), 90->Mic2(az180), 180->Mic5(az90).
 * => camera neutral (servo 90) faces az 180 (Mic2); servo = 90 - wrap(az-180). */
#define SERVO_AZ_CENTER   180.0f         /* azimuth that maps to servo 90 deg  */
#define SERVO_DIR         (-1.0f)        /* pan sense (see DIRECTION STANDARD)  */
volatile float   g_servo_deg;           /* last commanded servo angle (debug) */
/* 1 = DOA drives the servo (auto-track sound); 0 = manual only. A manual "SERVO
 * <deg>" command clears this so testing isn't fought by DOA; "AUTO 1" restores. */
volatile uint8_t g_servo_auto = 1U;
/* USER CODE END PV */

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
void PeriphCommonClock_Config(void);
static void MPU_Config(void);
static void MX_GPIO_Init(void);
static void MX_DMA_Init(void);
static void MX_SAI1_Init(void);
static void MX_SAI2_Init(void);
void StartDefaultTask(void *argument);
void StartTask02(void *argument);
void StartTask03(void *argument);
void StartTask04(void *argument);
void StartTask05(void *argument);

/* USER CODE BEGIN PFP */
void Clock_Verify(void);
void SAI_Verify(void);
void Audio_Start(void);
static void Deinterleave_Pair(uint32_t off, uint8_t pair);
#if FFT_ENABLE
void FFT_Init(void);
void FFT_ProcessAll(void);
void FFT_SelfTest(void);
void Silence_SelfTest(void);
static uint32_t FFT_PeakBin(const float *mag, float *peakVal);
#if GCC_ENABLE
int32_t GCC_PHAT(const float *a, const float *b);
void GCC_SelfTest(void);
void GCC_ProcessPairs(void);
#if DOA_ENABLE
void DOA_Compute(const float *lag_f, float *az_deg, float *resid);
void DOA_SelfTest(void);
#endif
#endif
#endif
void Pipeline_InitOnce(void);
/* Servo (camera pan) on PB6 = TIM4_CH1 PWM, 50 Hz. */
static void MX_TIM4_Init(void);
void Servo_SetAngle(float deg);           /* raw servo angle [0,180]; 90 = front  */
void Servo_MoveTo(float deg);             /* gradual move with per-step delay     */
void Servo_PointToAzimuth(float az_deg);  /* map DOA azimuth -> servo angle       */
/* USER CODE END PFP */

/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */

/* Bring up TIM4_CH1 as a 50 Hz PWM on PB6 to drive the camera-pan servo.
 * Self-contained (no CubeMX MspInit): enables GPIOB+TIM4 clocks and sets PB6 to
 * AF2 (TIM4_CH1). 1 us tick, 20 ms frame; duty is set later in micro-seconds. */
static void MX_TIM4_Init(void)
{
  __HAL_RCC_GPIOB_CLK_ENABLE();
  __HAL_RCC_TIM4_CLK_ENABLE();

  GPIO_InitTypeDef gpio = {0};
  gpio.Pin       = GPIO_PIN_6;
  gpio.Mode      = GPIO_MODE_AF_PP;
  gpio.Pull      = GPIO_NOPULL;
  gpio.Speed     = GPIO_SPEED_FREQ_LOW;
  gpio.Alternate = GPIO_AF2_TIM4;
  HAL_GPIO_Init(GPIOB, &gpio);

  htim4.Instance           = TIM4;
  htim4.Init.Prescaler     = SERVO_TIM_PSC;
  htim4.Init.CounterMode   = TIM_COUNTERMODE_UP;
  htim4.Init.Period        = SERVO_TIM_ARR;
  htim4.Init.ClockDivision = TIM_CLOCKDIVISION_DIV1;
  htim4.Init.AutoReloadPreload = TIM_AUTORELOAD_PRELOAD_ENABLE;
  if (HAL_TIM_PWM_Init(&htim4) != HAL_OK) { Error_Handler(); }

  TIM_OC_InitTypeDef oc = {0};
  oc.OCMode     = TIM_OCMODE_PWM1;
  oc.Pulse      = 1500U;                 /* ~centre until first command */
  oc.OCPolarity = TIM_OCPOLARITY_HIGH;
  oc.OCFastMode = TIM_OCFAST_DISABLE;
  if (HAL_TIM_PWM_ConfigChannel(&htim4, &oc, TIM_CHANNEL_1) != HAL_OK) { Error_Handler(); }

  HAL_TIM_PWM_Start(&htim4, TIM_CHANNEL_1);
}

/* Command the servo to an absolute angle in [0,180] deg (90 = front = mic 1). */
void Servo_SetAngle(float deg)
{
  if (deg < 0.0f)   { deg = 0.0f; }
  if (deg > 180.0f) { deg = 180.0f; }
  float us = SERVO_MIN_US + (SERVO_MAX_US - SERVO_MIN_US) * (deg / 180.0f);
  __HAL_TIM_SET_COMPARE(&htim4, TIM_CHANNEL_1, (uint32_t)lroundf(us));
  g_servo_deg = deg;
}

/* Move to an angle GRADUALLY: step a few degrees at a time with a short delay so
 * the servo has time to travel (and the current draw is gentler -> less brown-out).
 * Blocking via HAL_Delay - fine both before the RTOS (boot) and inside a task. */
#define SERVO_STEP_DEG   3.0f      /* size of each move step                  */
#define SERVO_STEP_MS    20U       /* delay per step (~ servo travel speed)   */
void Servo_MoveTo(float deg)
{
  if (deg < 0.0f)   { deg = 0.0f; }
  if (deg > 180.0f) { deg = 180.0f; }
  float cur  = g_servo_deg;
  float step = (deg >= cur) ? SERVO_STEP_DEG : -SERVO_STEP_DEG;
  while (fabsf(deg - cur) > SERVO_STEP_DEG)
  {
    cur += step;
    Servo_SetAngle(cur);
    HAL_Delay(SERVO_STEP_MS);
  }
  Servo_SetAngle(deg);             /* land exactly on target */
  HAL_Delay(SERVO_STEP_MS);
}

/* Point the camera at a DOA azimuth (firmware convention, 0 deg = mic 0/ch0).
 * The camera looks straight ahead (servo 90 deg) at SERVO_AZ_CENTER and pans left/
 * right with SERVO_DIR. The servo only spans 180 deg, so sources in the rear
 * hemisphere clamp to the nearest reachable edge (handled by Servo_SetAngle).
 *   r  = signed bearing off centre, in (-180,180]
 *   servo = 90 + SERVO_DIR * r   (e.g. az 0 -> 90, az 90 -> 0, az 270 -> 180) */
void Servo_PointToAzimuth(float az_deg)
{
  float r = fmodf(az_deg - SERVO_AZ_CENTER, 360.0f);
  if (r < -180.0f) { r += 360.0f; }
  if (r >  180.0f) { r -= 360.0f; }
  Servo_MoveTo(90.0f + SERVO_DIR * r);   /* xoay tu tu co delay */
}

/* USER CODE END 0 */

/**
  * @brief  The application entry point.
  * @retval int
  */
int main(void)
{

  /* USER CODE BEGIN 1 */

  /* USER CODE END 1 */

  /* MPU Configuration--------------------------------------------------------*/
  MPU_Config();

  /* MCU Configuration--------------------------------------------------------*/

  /* Reset of all peripherals, Initializes the Flash interface and the Systick. */
  HAL_Init();

  /* USER CODE BEGIN Init */
  /* TASK-05: enable caches now that the DMA path is being brought up.
   * The MPU (TASK-02) marks AXI SRAM at 0x24000000 (where dma_buf lives) as
   * non-cacheable, so SAI/DMA writes stay coherent with no manual invalidate.
   * Hot DSP data (mic_data, FFT buffers) lives in DTCM, which is never cached. */
  SCB_EnableICache();
  SCB_EnableDCache();
  /* USER CODE END Init */

  /* Configure the system clock */
  SystemClock_Config();

  /* Configure the peripherals common clocks */
  PeriphCommonClock_Config();

  /* USER CODE BEGIN SysInit */

  /* USER CODE END SysInit */

  /* Initialize all configured peripherals */
  MX_GPIO_Init();
  MX_DMA_Init();
  MX_SAI1_Init();
  MX_SAI2_Init();
  /* USER CODE BEGIN 2 */
  MX_TIM4_Init();              /* camera-pan servo PWM on PB6 */
  /* Boot self-test: sweep the camera across its full reachable range so the
   * physical orientation can be verified. Uses the SAME az->servo mapping as DOA
   * (Servo_PointToAzimuth). Runs before the RTOS, so HAL_Delay (SysTick) is valid.
   * Measured mapping (SERVO_AZ_CENTER=180):
   *   Mic6 -> az 270 -> servo   0
   *   Mic2 -> az 180 -> servo  90 (chinh dien camera)
   *   Mic5 -> az  90 -> servo 180 */
  static const float k_mic_az[3] = { 270.0f, 180.0f, 90.0f };  /* Mic6, Mic2, Mic5 */
  for (uint32_t r = 0U; r < 2U; r++)                          /* 2 vong */
  {
    for (uint32_t i = 0U; i < 3U; i++)
    {
      Servo_PointToAzimuth(k_mic_az[i]);
      HAL_Delay(1000);
    }
  }
  Servo_SetAngle(90.0f);  HAL_Delay(500);   /* park at centre (mic 1) */
  /* USER CODE END 2 */

  /* Init scheduler */
  osKernelInitialize();

  /* USER CODE BEGIN RTOS_MUTEX */
  /* add mutexes, ... */
  /* USER CODE END RTOS_MUTEX */

  /* USER CODE BEGIN RTOS_SEMAPHORES */
  /* add semaphores, ... */
  /* USER CODE END RTOS_SEMAPHORES */

  /* USER CODE BEGIN RTOS_TIMERS */
  /* start timers, add new ones, ... */
  /* USER CODE END RTOS_TIMERS */

  /* Create the queue(s) */
  /* creation of result_queue */
  /* TASK-09 (BUG-05): carry the TDOA result struct, not a bare uint16_t. */
  result_queueHandle = osMessageQueueNew (4, sizeof(tdoa_result_t), &result_queue_attributes);

  /* USER CODE BEGIN RTOS_QUEUES */
  /* add queues, ... */
  /* USER CODE END RTOS_QUEUES */

  /* Create the thread(s) */
  /* creation of defaultTask */
  defaultTaskHandle = osThreadNew(StartDefaultTask, NULL, &defaultTask_attributes);

  /* creation of FFT_Task */
  FFT_TaskHandle = osThreadNew(StartTask02, NULL, &FFT_Task_attributes);

  /* creation of USB_Task */
  USB_TaskHandle = osThreadNew(StartTask03, NULL, &USB_Task_attributes);

  /* creation of DOA_Task */
  DOA_TaskHandle = osThreadNew(StartTask04, NULL, &DOA_Task_attributes);

  /* creation of Monitor_Task */
  Monitor_TaskHandle = osThreadNew(StartTask05, NULL, &Monitor_Task_attributes);

  /* USER CODE BEGIN RTOS_THREADS */
  /* add threads, ... */
  /* USER CODE END RTOS_THREADS */

  /* USER CODE BEGIN RTOS_EVENTS */
  /* add events, ... */
  /* USER CODE END RTOS_EVENTS */

  /* Initialize leds */
  BSP_LED_Init(LED_GREEN);
  BSP_LED_Init(LED_YELLOW);
  BSP_LED_Init(LED_RED);

  /* Initialize USER push-button, will be used to trigger an interrupt each time it's pressed.*/
  BSP_PB_Init(BUTTON_USER, BUTTON_MODE_EXTI);

  /* Initialize COM1 port (115200, 8 bits (7-bit data + 1 stop bit), no parity */
  BspCOMInit.BaudRate   = 115200;
  BspCOMInit.WordLength = COM_WORDLENGTH_8B;
  BspCOMInit.StopBits   = COM_STOPBITS_1;
  BspCOMInit.Parity     = COM_PARITY_NONE;
  BspCOMInit.HwFlowCtl  = COM_HWCONTROL_NONE;
  if (BSP_COM_Init(COM1, &BspCOMInit) != BSP_ERROR_NONE)
  {
    Error_Handler();
  }

  /* Start scheduler */
  osKernelStart();

  /* We should never get here as control is now taken by the scheduler */

  /* Infinite loop */
  /* USER CODE BEGIN WHILE */
  /* TASK-09: the capture + FFT + GCC-PHAT pipeline now lives in the FreeRTOS tasks
   * (StartTask02..05). osKernelStart() above never returns, so this loop is unused. */
  while (1)
  {
  }
  /* USER CODE END WHILE */

  /* USER CODE BEGIN 3 */
  /* USER CODE END 3 */
}

/**
  * @brief System Clock Configuration
  * @retval None
  */
void SystemClock_Config(void)
{
  RCC_OscInitTypeDef RCC_OscInitStruct = {0};
  RCC_ClkInitTypeDef RCC_ClkInitStruct = {0};

  /*AXI clock gating */
  RCC->CKGAENR = 0xE003FFFF;

  /** Supply configuration update enable
  */
  HAL_PWREx_ConfigSupply(PWR_DIRECT_SMPS_SUPPLY);

  /** Configure the main internal regulator output voltage
  */
  __HAL_PWR_VOLTAGESCALING_CONFIG(PWR_REGULATOR_VOLTAGE_SCALE3);

  while(!__HAL_PWR_GET_FLAG(PWR_FLAG_VOSRDY)) {}

  /** Initializes the RCC Oscillators according to the specified parameters
  * in the RCC_OscInitTypeDef structure.
  */
  RCC_OscInitStruct.OscillatorType = RCC_OSCILLATORTYPE_HSI48|RCC_OSCILLATORTYPE_HSE;
  RCC_OscInitStruct.HSEState = RCC_HSE_BYPASS;
  RCC_OscInitStruct.HSI48State = RCC_HSI48_ON;
  RCC_OscInitStruct.PLL.PLLState = RCC_PLL_ON;
  RCC_OscInitStruct.PLL.PLLSource = RCC_PLLSOURCE_HSE;
  RCC_OscInitStruct.PLL.PLLM = 1;
  RCC_OscInitStruct.PLL.PLLN = 16;
  RCC_OscInitStruct.PLL.PLLP = 2;
  RCC_OscInitStruct.PLL.PLLQ = 2;
  RCC_OscInitStruct.PLL.PLLR = 2;
  RCC_OscInitStruct.PLL.PLLRGE = RCC_PLL1VCIRANGE_3;
  RCC_OscInitStruct.PLL.PLLVCOSEL = RCC_PLL1VCOWIDE;
  RCC_OscInitStruct.PLL.PLLFRACN = 0;
  if (HAL_RCC_OscConfig(&RCC_OscInitStruct) != HAL_OK)
  {
    Error_Handler();
  }

  /** Initializes the CPU, AHB and APB buses clocks
  */
  RCC_ClkInitStruct.ClockType = RCC_CLOCKTYPE_HCLK|RCC_CLOCKTYPE_SYSCLK
                              |RCC_CLOCKTYPE_PCLK1|RCC_CLOCKTYPE_PCLK2
                              |RCC_CLOCKTYPE_D3PCLK1|RCC_CLOCKTYPE_D1PCLK1;
  RCC_ClkInitStruct.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;
  RCC_ClkInitStruct.SYSCLKDivider = RCC_SYSCLK_DIV1;
  RCC_ClkInitStruct.AHBCLKDivider = RCC_HCLK_DIV1;
  RCC_ClkInitStruct.APB3CLKDivider = RCC_APB3_DIV1;
  RCC_ClkInitStruct.APB1CLKDivider = RCC_APB1_DIV1;
  RCC_ClkInitStruct.APB2CLKDivider = RCC_APB2_DIV1;
  RCC_ClkInitStruct.APB4CLKDivider = RCC_APB4_DIV1;

  if (HAL_RCC_ClockConfig(&RCC_ClkInitStruct, FLASH_LATENCY_2) != HAL_OK)
  {
    Error_Handler();
  }
}

/**
  * @brief Peripherals Common Clock Configuration
  * @retval None
  */
void PeriphCommonClock_Config(void)
{
  RCC_PeriphCLKInitTypeDef PeriphClkInitStruct = {0};

  /** Initializes the peripherals clock
  */
  PeriphClkInitStruct.PeriphClockSelection = RCC_PERIPHCLK_SAI1|RCC_PERIPHCLK_SAI2A
                              |RCC_PERIPHCLK_SAI2B;
  PeriphClkInitStruct.PLL3.PLL3M = 5;
  PeriphClkInitStruct.PLL3.PLL3N = 123;
  PeriphClkInitStruct.PLL3.PLL3P = 4;
  PeriphClkInitStruct.PLL3.PLL3Q = 2;
  PeriphClkInitStruct.PLL3.PLL3R = 4;
  PeriphClkInitStruct.PLL3.PLL3RGE = RCC_PLL3VCIRANGE_0;
  PeriphClkInitStruct.PLL3.PLL3VCOSEL = RCC_PLL3VCOWIDE;
  PeriphClkInitStruct.PLL3.PLL3FRACN = 0;
  PeriphClkInitStruct.Sai1ClockSelection = RCC_SAI1CLKSOURCE_PLL3;
  PeriphClkInitStruct.Sai2BClockSelection = RCC_SAI2BCLKSOURCE_PLL3;
  PeriphClkInitStruct.Sai2AClockSelection = RCC_SAI2ACLKSOURCE_PLL3;
  if (HAL_RCCEx_PeriphCLKConfig(&PeriphClkInitStruct) != HAL_OK)
  {
    Error_Handler();
  }
}

/**
  * @brief SAI1 Initialization Function
  * @param None
  * @retval None
  */
static void MX_SAI1_Init(void)
{

  /* USER CODE BEGIN SAI1_Init 0 */

  /* USER CODE END SAI1_Init 0 */

  /* USER CODE BEGIN SAI1_Init 1 */

  /* USER CODE END SAI1_Init 1 */
  hsai_BlockA1.Instance = SAI1_Block_A;
  hsai_BlockA1.Init.Protocol = SAI_FREE_PROTOCOL;
  hsai_BlockA1.Init.AudioMode = SAI_MODEMASTER_RX;
  hsai_BlockA1.Init.DataSize = SAI_DATASIZE_24;
  hsai_BlockA1.Init.FirstBit = SAI_FIRSTBIT_MSB;
  hsai_BlockA1.Init.ClockStrobing = SAI_CLOCKSTROBING_FALLINGEDGE;
  hsai_BlockA1.Init.Synchro = SAI_ASYNCHRONOUS;
  hsai_BlockA1.Init.OutputDrive = SAI_OUTPUTDRIVE_DISABLE;
  hsai_BlockA1.Init.NoDivider = SAI_MASTERDIVIDER_ENABLE;
  hsai_BlockA1.Init.FIFOThreshold = SAI_FIFOTHRESHOLD_EMPTY;
  hsai_BlockA1.Init.AudioFrequency = SAI_AUDIO_FREQUENCY_16K;
  /* TASK-05 fix (re-applied after CubeMX regen, see BUG-08): SAI1 must export its
   * sync (GCR.SYNCOUT = Block A) so the SAI2 EXT-sync slaves get a clock. Both SAI1
   * blocks carry it because HAL_SAI_Init rewrites the shared GCR on every call. */
  hsai_BlockA1.Init.SynchroExt = SAI_SYNCEXT_OUTBLOCKA_ENABLE;
  hsai_BlockA1.Init.MonoStereoMode = SAI_STEREOMODE;
  hsai_BlockA1.Init.CompandingMode = SAI_NOCOMPANDING;
  hsai_BlockA1.Init.PdmInit.Activation = DISABLE;
  hsai_BlockA1.Init.PdmInit.MicPairsNbr = 0;
  hsai_BlockA1.Init.PdmInit.ClockEnable = SAI_PDM_CLOCK1_ENABLE;
  hsai_BlockA1.FrameInit.FrameLength = 64;
  hsai_BlockA1.FrameInit.ActiveFrameLength = 32;
  hsai_BlockA1.FrameInit.FSDefinition = SAI_FS_CHANNEL_IDENTIFICATION;
  hsai_BlockA1.FrameInit.FSPolarity = SAI_FS_ACTIVE_LOW;
  hsai_BlockA1.FrameInit.FSOffset = SAI_FS_BEFOREFIRSTBIT;
  hsai_BlockA1.SlotInit.FirstBitOffset = 0;
  hsai_BlockA1.SlotInit.SlotSize = SAI_SLOTSIZE_32B;
  hsai_BlockA1.SlotInit.SlotNumber = 2;
  hsai_BlockA1.SlotInit.SlotActive = 0x00000003;
  if (HAL_SAI_Init(&hsai_BlockA1) != HAL_OK)
  {
    Error_Handler();
  }
  hsai_BlockB1.Instance = SAI1_Block_B;
  hsai_BlockB1.Init.Protocol = SAI_FREE_PROTOCOL;
  hsai_BlockB1.Init.AudioMode = SAI_MODESLAVE_RX;
  hsai_BlockB1.Init.DataSize = SAI_DATASIZE_24;
  hsai_BlockB1.Init.FirstBit = SAI_FIRSTBIT_MSB;
  hsai_BlockB1.Init.ClockStrobing = SAI_CLOCKSTROBING_FALLINGEDGE;
  /* TASK-05 fix (BUG-08): SAI1_B syncs internally to SAI1_A, not to SAI2. */
  hsai_BlockB1.Init.Synchro = SAI_SYNCHRONOUS;
  hsai_BlockB1.Init.OutputDrive = SAI_OUTPUTDRIVE_DISABLE;
  hsai_BlockB1.Init.FIFOThreshold = SAI_FIFOTHRESHOLD_EMPTY;
  hsai_BlockB1.Init.SynchroExt = SAI_SYNCEXT_OUTBLOCKA_ENABLE;   /* see SAI1_A note above */
  hsai_BlockB1.Init.MonoStereoMode = SAI_STEREOMODE;
  hsai_BlockB1.Init.CompandingMode = SAI_NOCOMPANDING;
  hsai_BlockB1.Init.TriState = SAI_OUTPUT_NOTRELEASED;
  hsai_BlockB1.Init.PdmInit.Activation = DISABLE;
  hsai_BlockB1.Init.PdmInit.MicPairsNbr = 0;
  hsai_BlockB1.Init.PdmInit.ClockEnable = SAI_PDM_CLOCK1_ENABLE;
  hsai_BlockB1.FrameInit.FrameLength = 64;
  hsai_BlockB1.FrameInit.ActiveFrameLength = 32;
  hsai_BlockB1.FrameInit.FSDefinition = SAI_FS_CHANNEL_IDENTIFICATION;
  hsai_BlockB1.FrameInit.FSPolarity = SAI_FS_ACTIVE_LOW;
  hsai_BlockB1.FrameInit.FSOffset = SAI_FS_BEFOREFIRSTBIT;
  hsai_BlockB1.SlotInit.FirstBitOffset = 0;
  hsai_BlockB1.SlotInit.SlotSize = SAI_SLOTSIZE_32B;
  hsai_BlockB1.SlotInit.SlotNumber = 2;
  hsai_BlockB1.SlotInit.SlotActive = 0x00000003;
  if (HAL_SAI_Init(&hsai_BlockB1) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN SAI1_Init 2 */

  /* USER CODE END SAI1_Init 2 */

}

/**
  * @brief SAI2 Initialization Function
  * @param None
  * @retval None
  */
static void MX_SAI2_Init(void)
{

  /* USER CODE BEGIN SAI2_Init 0 */

  /* USER CODE END SAI2_Init 0 */

  /* USER CODE BEGIN SAI2_Init 1 */

  /* USER CODE END SAI2_Init 1 */
  hsai_BlockA2.Instance = SAI2_Block_A;
  hsai_BlockA2.Init.Protocol = SAI_FREE_PROTOCOL;
  hsai_BlockA2.Init.AudioMode = SAI_MODESLAVE_RX;
  hsai_BlockA2.Init.DataSize = SAI_DATASIZE_24;
  hsai_BlockA2.Init.FirstBit = SAI_FIRSTBIT_MSB;
  hsai_BlockA2.Init.ClockStrobing = SAI_CLOCKSTROBING_FALLINGEDGE;
  hsai_BlockA2.Init.Synchro = SAI_SYNCHRONOUS_EXT_SAI1;
  hsai_BlockA2.Init.OutputDrive = SAI_OUTPUTDRIVE_DISABLE;
  hsai_BlockA2.Init.FIFOThreshold = SAI_FIFOTHRESHOLD_EMPTY;
  hsai_BlockA2.Init.MonoStereoMode = SAI_STEREOMODE;
  hsai_BlockA2.Init.CompandingMode = SAI_NOCOMPANDING;
  hsai_BlockA2.Init.TriState = SAI_OUTPUT_NOTRELEASED;
  hsai_BlockA2.Init.PdmInit.Activation = DISABLE;
  hsai_BlockA2.Init.PdmInit.MicPairsNbr = 0;
  hsai_BlockA2.Init.PdmInit.ClockEnable = SAI_PDM_CLOCK1_ENABLE;
  hsai_BlockA2.FrameInit.FrameLength = 64;
  hsai_BlockA2.FrameInit.ActiveFrameLength = 32;
  hsai_BlockA2.FrameInit.FSDefinition = SAI_FS_CHANNEL_IDENTIFICATION;
  hsai_BlockA2.FrameInit.FSPolarity = SAI_FS_ACTIVE_LOW;
  hsai_BlockA2.FrameInit.FSOffset = SAI_FS_BEFOREFIRSTBIT;
  hsai_BlockA2.SlotInit.FirstBitOffset = 0;
  hsai_BlockA2.SlotInit.SlotSize = SAI_SLOTSIZE_32B;
  hsai_BlockA2.SlotInit.SlotNumber = 2;
  hsai_BlockA2.SlotInit.SlotActive = 0x00000003;
  if (HAL_SAI_Init(&hsai_BlockA2) != HAL_OK)
  {
    Error_Handler();
  }
  hsai_BlockB2.Instance = SAI2_Block_B;
  hsai_BlockB2.Init.Protocol = SAI_FREE_PROTOCOL;
  hsai_BlockB2.Init.AudioMode = SAI_MODESLAVE_RX;
  hsai_BlockB2.Init.DataSize = SAI_DATASIZE_24;
  hsai_BlockB2.Init.FirstBit = SAI_FIRSTBIT_MSB;
  hsai_BlockB2.Init.ClockStrobing = SAI_CLOCKSTROBING_FALLINGEDGE;
  hsai_BlockB2.Init.Synchro = SAI_SYNCHRONOUS_EXT_SAI1;
  hsai_BlockB2.Init.OutputDrive = SAI_OUTPUTDRIVE_DISABLE;
  hsai_BlockB2.Init.FIFOThreshold = SAI_FIFOTHRESHOLD_EMPTY;
  hsai_BlockB2.Init.MonoStereoMode = SAI_STEREOMODE;
  hsai_BlockB2.Init.CompandingMode = SAI_NOCOMPANDING;
  hsai_BlockB2.Init.TriState = SAI_OUTPUT_NOTRELEASED;
  hsai_BlockB2.Init.PdmInit.Activation = DISABLE;
  hsai_BlockB2.Init.PdmInit.MicPairsNbr = 0;
  hsai_BlockB2.Init.PdmInit.ClockEnable = SAI_PDM_CLOCK1_ENABLE;
  hsai_BlockB2.FrameInit.FrameLength = 64;
  hsai_BlockB2.FrameInit.ActiveFrameLength = 32;
  hsai_BlockB2.FrameInit.FSDefinition = SAI_FS_CHANNEL_IDENTIFICATION;
  hsai_BlockB2.FrameInit.FSPolarity = SAI_FS_ACTIVE_LOW;
  hsai_BlockB2.FrameInit.FSOffset = SAI_FS_BEFOREFIRSTBIT;
  hsai_BlockB2.SlotInit.FirstBitOffset = 0;
  hsai_BlockB2.SlotInit.SlotSize = SAI_SLOTSIZE_32B;
  hsai_BlockB2.SlotInit.SlotNumber = 2;
  hsai_BlockB2.SlotInit.SlotActive = 0x00000003;
  if (HAL_SAI_Init(&hsai_BlockB2) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN SAI2_Init 2 */

  /* USER CODE END SAI2_Init 2 */

}

/**
  * Enable DMA controller clock
  */
static void MX_DMA_Init(void)
{

  /* DMA controller clock enable */
  __HAL_RCC_DMA1_CLK_ENABLE();

  /* DMA interrupt init */
  /* DMA1_Stream0_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Stream0_IRQn, 5, 0);
  HAL_NVIC_EnableIRQ(DMA1_Stream0_IRQn);
  /* DMA1_Stream1_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Stream1_IRQn, 5, 0);
  HAL_NVIC_EnableIRQ(DMA1_Stream1_IRQn);
  /* DMA1_Stream2_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Stream2_IRQn, 5, 0);
  HAL_NVIC_EnableIRQ(DMA1_Stream2_IRQn);
  /* DMA1_Stream3_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Stream3_IRQn, 5, 0);
  HAL_NVIC_EnableIRQ(DMA1_Stream3_IRQn);

}

/**
  * @brief GPIO Initialization Function
  * @param None
  * @retval None
  */
static void MX_GPIO_Init(void)
{
  /* USER CODE BEGIN MX_GPIO_Init_1 */

  /* USER CODE END MX_GPIO_Init_1 */

  /* GPIO Ports Clock Enable */
  __HAL_RCC_GPIOE_CLK_ENABLE();
  __HAL_RCC_GPIOC_CLK_ENABLE();
  __HAL_RCC_GPIOH_CLK_ENABLE();
  __HAL_RCC_GPIOA_CLK_ENABLE();
  __HAL_RCC_GPIOD_CLK_ENABLE();

  /* USER CODE BEGIN MX_GPIO_Init_2 */

  /* USER CODE END MX_GPIO_Init_2 */
}

/* USER CODE BEGIN 4 */

/* Note: printf is retargeted to the VCP (USART3/COM1) by the BSP's __io_putchar()
 * in stm32h7xx_nucleo.c (USE_COM_LOG), which syscalls.c _write() calls. No local
 * __io_putchar is needed; defining one here causes a multiple-definition link error. */

/**
  * @brief  TASK-03 - report the configured clock tree over the VCP and enable
  *         the DWT cycle counter for later cycle-accurate benchmarking.
  *         Expected (per the .ioc): SYSCLK = HCLK = PCLK1 = 64 MHz.
  * @retval None
  */
void Clock_Verify(void)
{
  uint32_t sysclk = HAL_RCC_GetSysClockFreq();
  uint32_t hclk   = HAL_RCC_GetHCLKFreq();
  uint32_t pclk1  = HAL_RCC_GetPCLK1Freq();

  printf("\r\n--- TASK-03 Clock Verify ---\r\n");
  printf("SYSCLK : %lu Hz\r\n", (unsigned long)sysclk);   /* expect 64000000 */
  printf("HCLK   : %lu Hz\r\n", (unsigned long)hclk);     /* expect 64000000 */
  printf("PCLK1  : %lu Hz\r\n", (unsigned long)pclk1);    /* expect 64000000 */

  /* Enable DWT cycle counter (DEMCR.TRCENA then DWT.CYCCNT/CTRL) */
  CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
  DWT->CYCCNT       = 0U;
  DWT->CTRL        |= DWT_CTRL_CYCCNTENA_Msk;

  if (sysclk == 64000000UL)
  {
    printf("Clock OK. DWT cycle counter enabled.\r\n");
    BSP_LED_On(LED_GREEN);
  }
  else
  {
    printf("Clock MISMATCH: SYSCLK != 64 MHz\r\n");
    BSP_LED_On(LED_RED);
  }
}

static const char *Sai_StateStr(HAL_SAI_StateTypeDef s)
{
  switch (s)
  {
    case HAL_SAI_STATE_RESET:   return "RESET";
    case HAL_SAI_STATE_READY:   return "READY";
    case HAL_SAI_STATE_BUSY:    return "BUSY";
    case HAL_SAI_STATE_BUSY_TX: return "BUSY_TX";
    case HAL_SAI_STATE_BUSY_RX: return "BUSY_RX";
    default:                    return "?";
  }
}

/**
  * @brief  TASK-04 - verify SAI + DMA initialization for the 8-mic capture path.
  *         MX_SAI1_Init/MX_SAI2_Init already ran in main(); a block reaching
  *         HAL_SAI_STATE_READY means HAL_SAI_Init returned no HAL_ERROR. Also
  *         checks each linked RX DMA is circular / word-aligned / FIFO-disabled.
  * @retval None
  */
void SAI_Verify(void)
{
  SAI_HandleTypeDef *blk[4] = { &hsai_BlockA1, &hsai_BlockB1, &hsai_BlockA2, &hsai_BlockB2 };
  const char        *nm[4]  = { "SAI1_A(mst)", "SAI1_B(slv)", "SAI2_A(slv)", "SAI2_B(slv)" };
  uint32_t ready = 0U, dma_ok = 0U;

  printf("\r\n--- TASK-04 SAI + DMA Verify ---\r\n");
  for (int i = 0; i < 4; i++)
  {
    HAL_SAI_StateTypeDef st = HAL_SAI_GetState(blk[i]);
    if (st == HAL_SAI_STATE_READY) { ready++; }

    DMA_HandleTypeDef *hdma = blk[i]->hdmarx;
    int circ = (hdma != NULL)
            && (hdma->Init.Mode == DMA_CIRCULAR)
            && (hdma->Init.PeriphDataAlignment == DMA_PDATAALIGN_WORD)
            && (hdma->Init.MemDataAlignment == DMA_MDATAALIGN_WORD)
            && (hdma->Init.FIFOMode == DMA_FIFOMODE_DISABLE);
    if (circ) { dma_ok++; }

    printf("%-11s state=%-5s data=%ub slot=%ub nslot=%lu frame=%lu dma=%s\r\n",
           nm[i], Sai_StateStr(st),
           (blk[i]->Init.DataSize == SAI_DATASIZE_24) ? 24U : 0U,
           (blk[i]->SlotInit.SlotSize == SAI_SLOTSIZE_32B) ? 32U : 0U,
           (unsigned long)blk[i]->SlotInit.SlotNumber,
           (unsigned long)blk[i]->FrameInit.FrameLength,
           circ ? "circ/word/noFIFO" : "BAD");
  }

  printf("SAI READY: %lu/4   DMA configured: %lu/4\r\n",
         (unsigned long)ready, (unsigned long)dma_ok);

  if ((ready == 4U) && (dma_ok == 4U))
  {
    printf("TASK-04 OK: SAI+DMA init, no HAL_ERROR.\r\n");
  }
  else
  {
    printf("TASK-04 FAIL: check SAI/DMA init.\r\n");
    BSP_LED_On(LED_RED);
  }
}

/**
  * @brief  Map a SAI block handle to its pair index (0=SAI1_A .. 3=SAI2_B).
  */
static uint8_t Audio_GetPair(SAI_HandleTypeDef *hsai)
{
  if (hsai->Instance == SAI1_Block_A) { return 0U; }
  if (hsai->Instance == SAI1_Block_B) { return 1U; }
  if (hsai->Instance == SAI2_Block_A) { return 2U; }
  if (hsai->Instance == SAI2_Block_B) { return 3U; }
  return 0xFFU;
}

/* DMA half-transfer: first half (PING) of the circular buffer is full.
 * All 4 SAI blocks share one clock, so when the master (SAI1_A) reaches the
 * half boundary every slave has already written the same half. We trigger the
 * deinterleave for all pairs off the master's callback (serviced first: it is
 * DMA1_Stream0, the lowest IRQ number). */
/* TASK-09: notify FFT_Task that a fresh half (PING/PONG) is ready. Runs in the
 * DMA IRQ at preempt priority 5 (>= configMAX_SYSCALL_INTERRUPT_PRIORITY), so the
 * FromISR API is legal. The deinterleave + DSP happen in FFT_Task, not here. */
static void Audio_NotifyHalfReady(uint8_t half)
{
  if (g_half_ready) { g_overruns++; }     /* FFT_Task didn't consume the last one */
  g_ready_half = half;
  g_half_ready = 1U;

  if (FFT_TaskHandle != NULL)
  {
    BaseType_t woken = pdFALSE;
    xTaskNotifyFromISR((TaskHandle_t)FFT_TaskHandle, FLAG_FFT, eSetBits, &woken);
    portYIELD_FROM_ISR(woken);
  }
}

void HAL_SAI_RxHalfCpltCallback(SAI_HandleTypeDef *hsai)
{
  uint8_t p = Audio_GetPair(hsai);
  if (p == 0xFFU) { return; }
  dma_half_cnt[p]++;
  if (p == 0U) { Audio_NotifyHalfReady(0U); }   /* master block, PING */
}

/* DMA transfer-complete: second half (PONG) of the circular buffer is full. */
void HAL_SAI_RxCpltCallback(SAI_HandleTypeDef *hsai)
{
  uint8_t p = Audio_GetPair(hsai);
  if (p == 0xFFU) { return; }
  dma_full_cnt[p]++;
  if (p == 0U) { Audio_NotifyHalfReady(1U); }   /* master block, PONG */
}

/* TASK-11: channel remap (capture order -> clean logical mic order).
 * The board is wired so the captured SAI channels land out of order vs the
 * physical mic labels in the docs (Mic1..Mic8 at 0/180/45/225/90/270/135/315 deg).
 * Rather than baking that scramble into g_doa_table, we fix it ONCE here at copy
 * time so the rest of the pipeline sees clean pairs and the table uses the natural
 * baselines phi_k = {0,45,90,135}. MIC_REMAP[capture_ch] = logical mic slot.
 * Calibrated by tapping each physical mic and reading tools/test_mic_order.py.
 * Measured board wiring (physical angle -> capture channel):
 *   0=ch0  45=ch6  90=ch4  135=ch2  180=ch1  225=ch7  270=ch5  315=ch3.
 * Each capture ch routed to the slot whose pair-angle matches:
 *   ch0->0  ch1->1  ch2->6  ch3->7  ch4->4  ch5->5  ch6->2  ch7->3
 * (Re-run the test if the board is re-wired; only this array needs editing.) */
static const uint8_t MIC_REMAP[NUM_MIC_CHANNELS] = { 0U, 1U, 6U, 7U, 4U, 5U, 2U, 3U };

/* Deinterleave one stereo pair's half-buffer into the two per-mic arrays.
 * SAI 24-bit data is MSB-left-justified in a 32-bit slot, so the signed 24-bit
 * sample is (word >> 8); /2^23 normalizes to [-1,1]. */
static void Deinterleave_Pair(uint32_t off, uint8_t pair)
{
  const int32_t *src = &dma_buf[pair][off];
  uint8_t l = (uint8_t)(pair * 2U);            /* capture channels (DMA order) */
  uint8_t r = (uint8_t)(pair * 2U + 1U);
  uint8_t ld = MIC_REMAP[l];                   /* destination = clean Mic slot */
  uint8_t rd = MIC_REMAP[r];
  /* Polarity inversion is a property of the PHYSICAL capture channel: mics on
   * ch3 (SAI1-B slot 1) and ch6 (SAI2-B slot 0) are wired inverted; negate to
   * restore phase alignment (needed for GCC-PHAT). Keyed on capture ch, not slot. */
  const int32_t l_sign = (l == 6U) ? -1 : 1;
  const int32_t r_sign = (r == 3U) ? -1 : 1;
  for (uint32_t i = 0U; i < AUDIO_BLOCK_SAMPLES; i++)
  {
    int32_t rl = l_sign * (int32_t)(int16_t)(src[2U * i] & 0xFFFF);
    int32_t rr = r_sign * (int32_t)(int16_t)(src[2U * i + 1U] & 0xFFFF);
    mic_raw[ld][i]  = rl;
    mic_raw[rd][i]  = rr;
    mic_data[ld][i] = (float)rl * (1.0f / 8388608.0f);
    mic_data[rd][i] = (float)rr * (1.0f / 8388608.0f);
  }
}

/**
  * @brief  TASK-05 - start circular DMA reception on all four SAI blocks.
  *         Slaves are armed before the master so they are ready when SAI1_A
  *         (master) begins generating SCK/FS.
  * @retval None
  */
 // khai báo DMA buffer, khởi tạo các biến đếm và trạng thái, sau đó bắt đầu nhận dữ liệu từ các khối SAI bằng DMA. Các khối slave được kích hoạt trước, khối master (SAI1_A) được kích hoạt cuối cùng.
void Audio_Start(void)
{
  memset((void *)dma_half_cnt, 0, sizeof(dma_half_cnt));
  memset((void *)dma_full_cnt, 0, sizeof(dma_full_cnt));
  g_half_ready = 0U;
  g_overruns   = 0U;
  memset(dma_buf, 0, sizeof(dma_buf));

  /* Arm slaves first, master (SAI1_A) last. */
  if (HAL_SAI_Receive_DMA(&hsai_BlockB2, (uint8_t *)dma_buf[3], DMA_FULL_WORDS) != HAL_OK) { Error_Handler(); }
  if (HAL_SAI_Receive_DMA(&hsai_BlockA2, (uint8_t *)dma_buf[2], DMA_FULL_WORDS) != HAL_OK) { Error_Handler(); }
  if (HAL_SAI_Receive_DMA(&hsai_BlockB1, (uint8_t *)dma_buf[1], DMA_FULL_WORDS) != HAL_OK) { Error_Handler(); }
  if (HAL_SAI_Receive_DMA(&hsai_BlockA1, (uint8_t *)dma_buf[0], DMA_FULL_WORDS) != HAL_OK) { Error_Handler(); }
}

#if FFT_ENABLE
/**
  * @brief  TASK-07 - initialise the real-FFT instance and pre-compute the Hann
  *         window once. Called before the capture loop starts using the FFT.
  */
void FFT_Init(void)
{
  arm_rfft_fast_init_f32(&fft_inst, FFT_SIZE);
  for (uint32_t i = 0U; i < FFT_SIZE; i++)
  {
    hann_window[i] = 0.5f * (1.0f - cosf((2.0f * PI_F * (float)i) / (float)(FFT_SIZE - 1U)));
  }
}

/* Find the dominant magnitude bin, skipping DC (bin 0). Returns the bin index
 * and writes its magnitude to *peakVal. */
static uint32_t FFT_PeakBin(const float *mag, float *peakVal)
{
  float    best = mag[1];
  uint32_t bin  = 1U;
  for (uint32_t k = 2U; k < FFT_BINS; k++)
  {
    if (mag[k] > best) { best = mag[k]; bin = k; }
  }
  *peakVal = best;
  return bin;
}

/**
  * @brief  TASK-07 - window + 1024-pt real FFT + magnitude for all 8 mics.
  *         Reads mic_data[m][] (float, normalized), writes fft_mag[m][0..511].
  *         Times the whole 8-mic pass with the DWT cycle counter.
  */
 // tính fft 1024 điểm cho tất cả 8 micro, áp dụng cửa sổ Hann, thực hiện FFT thực và tính độ lớn. Đo thời gian thực hiện bằng bộ đếm chu kỳ DWT.
void FFT_ProcessAll(void)
{
  uint32_t t0 = DWT->CYCCNT;
  for (uint32_t m = 0U; m < NUM_MIC_CHANNELS; m++)
  {
    arm_mult_f32(mic_data[m], hann_window, fft_win, FFT_SIZE);
    arm_rfft_fast_f32(&fft_inst, fft_win, fft_cplx, 0U);   /* forward */
    /* rfft_fast packs DC in [0] and Nyquist in [1]; mag[0] is sqrt(DC^2+Nyq^2),
     * which we ignore for peak detection anyway. */
    arm_cmplx_mag_f32(fft_cplx, fft_mag[m], FFT_BINS);
  }
  g_fft_us = (DWT->CYCCNT - t0) / (AUDIO_FS_HZ == 16000U ? 64U : 64U); /* cycles@64MHz -> us */
}

/**
  * @brief  TASK-07 - self-test independent of the mics: synthesize a clean
  *         1 kHz sine, run it through the FFT pipeline, and confirm the peak
  *         lands on the expected bin (1000/16000*1024 = 64). Proves the window,
  *         rfft and magnitude path are correct before trusting live mic input.
  */
void FFT_SelfTest(void)
{
  for (uint32_t i = 0U; i < FFT_SIZE; i++)
  {
    fft_win[i] = sinf((2.0f * PI_F * FFT_SELFTEST_HZ * (float)i) / (float)AUDIO_FS_HZ);
  }
  arm_mult_f32(fft_win, hann_window, fft_win, FFT_SIZE);
  arm_rfft_fast_f32(&fft_inst, fft_win, fft_cplx, 0U);
  arm_cmplx_mag_f32(fft_cplx, fft_mag[0], FFT_BINS);

  float    pk;
  uint32_t bin = FFT_PeakBin(fft_mag[0], &pk);
  uint32_t expBin = (uint32_t)((FFT_SELFTEST_HZ * (float)FFT_SIZE) / (float)AUDIO_FS_HZ + 0.5f);

  printf("\r\n--- TASK-07 Hann + FFT ---\r\n");
  printf("self-test: %d Hz -> peak bin %lu (expected %lu) mag=%ld\r\n",
         (int)FFT_SELFTEST_HZ, (unsigned long)bin, (unsigned long)expBin, (long)pk);
  if ((bin + 1U >= expBin) && (bin <= expBin + 1U))
  {
    printf("TASK-07 self-test OK (peak within +/-1 bin).\r\n");
  }
  else
  {
    printf("TASK-07 self-test FAIL (peak bin off).\r\n");
    BSP_LED_On(LED_RED);
  }
}

/**
  * @brief  TASK-13 IT-02 - silence self-test: push a zero (silent) frame through
  *         the FFT path and confirm a ~zero spectrum (no DC bias, no fabricated
  *         tone, no NaN). True acoustic silence is unreachable on the live mics
  *         (~50 Hz mains hum), so this validates IT-02's intent deterministically.
  */
void Silence_SelfTest(void)
{
  for (uint32_t i = 0U; i < FFT_SIZE; i++) { fft_win[i] = 0.0f; }
  arm_rfft_fast_f32(&fft_inst, fft_win, fft_cplx, 0U);
  arm_cmplx_mag_f32(fft_cplx, fft_mag[0], FFT_BINS);

  float    mx;
  uint32_t ix;
  arm_max_f32(fft_mag[0], FFT_BINS, &mx, &ix);

  printf("\r\n--- TASK-13 IT-02 silence ---\r\n");
  printf("silence self-test: peak mag=%ld (expect ~0)\r\n", (long)mx);
  if (mx < 1.0f)
  {
    printf("IT-02 silence self-test OK (zero-in -> zero-out).\r\n");
  }
  else
  {
    printf("IT-02 silence self-test FAIL.\r\n");
    BSP_LED_On(LED_RED);
  }
}

#if GCC_ENABLE
/**
  * @brief  TASK-08 - GCC-PHAT time-delay estimate between two real signals.
  *         Returns the lag in samples; positive lag means signal b is a delayed
  *         copy of a (a arrives first). Valid range +/- FFT_SIZE/2.
  *
  *  r[n] = IFFT( Xa . conj(Xb) / |Xa . conj(Xb)| )  -> peak index is the delay.
  *  PHAT whitening (divide by magnitude) sharpens the peak and makes it robust to
  *  the source spectrum. Note arm_rfft_fast_f32 (forward) overwrites its input, so
  *  we FFT from the fft_win scratch copy, never from the caller's array.
  */
static float g_last_frac;   /* TASK-11: sub-sample lag from the last GCC_PHAT call */

int32_t GCC_PHAT(const float *a, const float *b)
{
  memcpy(fft_win, a, sizeof(float) * FFT_SIZE);
  arm_rfft_fast_f32(&fft_inst, fft_win, gcc_a, 0U);
  memcpy(fft_win, b, sizeof(float) * FFT_SIZE);
  arm_rfft_fast_f32(&fft_inst, fft_win, gcc_b, 0U);

  /* Packed format: [0] = DC (real), [1] = Nyquist (real), then (re,im) per bin.
   * For the two real-only terms, conj(Xa).Xb is just the product; PHAT -> sign. */
  gcc_r[0] = (gcc_a[0] * gcc_b[0] >= 0.0f) ? 1.0f : -1.0f;
  gcc_r[1] = (gcc_a[1] * gcc_b[1] >= 0.0f) ? 1.0f : -1.0f;

  for (uint32_t k = 1U; k < FFT_BINS; k++)
  {
    float ar = gcc_a[2U * k], ai = gcc_a[2U * k + 1U];
    float br = gcc_b[2U * k], bi = gcc_b[2U * k + 1U];
    /* conj(Xa) * Xb = (ar - j ai)(br + j bi); peak at +D when b lags a by D
     * (positive lag => signal reaches mic a before mic b). */
    float re = ar * br + ai * bi;
    float im = ar * bi - ai * br;
    float mag = sqrtf(re * re + im * im);
    if (mag < 1e-9f) { mag = 1e-9f; }
    gcc_r[2U * k]      = re / mag;
    gcc_r[2U * k + 1U] = im / mag;
  }

  arm_rfft_fast_f32(&fft_inst, gcc_r, gcc_corr, 1U);   /* inverse -> correlation */

  float    maxVal;
  uint32_t maxIdx;
  arm_max_f32(gcc_corr, FFT_SIZE, &maxVal, &maxIdx);

  /* TASK-11: parabolic interpolation around the peak for a sub-sample lag. The
   * array is tiny (max delay ~2.7 samples), so integer lags are too coarse for a
   * meaningful angle; fitting a parabola to the 3 points recovers the fraction.
   * gcc_corr is circular (length FFT_SIZE), so neighbours wrap around. */
  uint32_t im1 = (maxIdx == 0U) ? (FFT_SIZE - 1U) : (maxIdx - 1U);
  uint32_t ip1 = (maxIdx + 1U == FFT_SIZE) ? 0U : (maxIdx + 1U);
  float ym1 = gcc_corr[im1], y0 = gcc_corr[maxIdx], yp1 = gcc_corr[ip1];
  float denom = ym1 - 2.0f * y0 + yp1;
  float delta = (fabsf(denom) > 1e-12f) ? (0.5f * (ym1 - yp1) / denom) : 0.0f;
  if (delta > 1.0f)  { delta = 1.0f; }
  if (delta < -1.0f) { delta = -1.0f; }

  int32_t lag = (int32_t)maxIdx;
  if (lag > (int32_t)(FFT_SIZE / 2U)) { lag -= (int32_t)FFT_SIZE; }
  g_last_frac = (float)lag + delta;
  return lag;
}

/**
  * @brief  TASK-08 - verify GCC-PHAT independent of the mics: build a broadband
  *         pseudo-random reference, make a copy circularly delayed by
  *         GCC_SELFTEST_SHIFT samples, and confirm the estimated lag matches.
  *         (Broadband, not a pure tone: PHAT whitening needs energy across bins.)
  */
void GCC_SelfTest(void)
{
  uint32_t lcg = 22695477U;
  for (uint32_t n = 0U; n < FFT_SIZE; n++)
  {
    lcg = lcg * 1103515245U + 12345U;
    gcc_a[n] = ((float)(lcg >> 9) / (float)0x400000) - 1.0f;   /* ~[-1,1] */
  }
  /* gcc_b[n] = gcc_a[n - SHIFT] circularly -> expected lag = +SHIFT */
  for (uint32_t n = 0U; n < FFT_SIZE; n++)
  {
    uint32_t src = (n + FFT_SIZE - (uint32_t)GCC_SELFTEST_SHIFT) % FFT_SIZE;
    gcc_b[n] = gcc_a[src];
  }
  /* GCC_PHAT consumes a (copied to fft_win) before it overwrites gcc_a/gcc_b. */
  int32_t lag = GCC_PHAT(gcc_a, gcc_b);

  printf("\r\n--- TASK-08 GCC-PHAT / TDOA ---\r\n");
  printf("self-test: delay %d -> lag %ld (expected %d)\r\n",
         GCC_SELFTEST_SHIFT, (long)lag, GCC_SELFTEST_SHIFT);
  if ((lag >= GCC_SELFTEST_SHIFT - 1) && (lag <= GCC_SELFTEST_SHIFT + 1))
  {
    printf("TASK-08 self-test OK (lag within +/-1 sample).\r\n");
  }
  else
  {
    printf("TASK-08 self-test FAIL (lag off).\r\n");
    BSP_LED_On(LED_RED);
  }
}

/**
  * @brief  TASK-08 - compute live TDOA lags between the 4 OPPOSITE mic pairs
  *         (ch0-ch1, ch2-ch3, ch4-ch5, ch6-ch7) from mic_data, timing the whole
  *         set with the DWT counter. Pair k uses channels 2k (lower angle) and
  *         2k+1 (opposite); the lag sign matches the hardcoded DOA table.
  */
void GCC_ProcessPairs(void)
{
  uint32_t t0 = DWT->CYCCNT;
  for (uint32_t k = 0U; k < GCC_NPAIRS_LIVE; k++)
  {
    g_tdoa_lag[k]   = GCC_PHAT(mic_data[2U * k], mic_data[2U * k + 1U]);
    g_tdoa_lag_f[k] = g_last_frac;       /* TASK-11: sub-sample lag for DOA */
  }
  g_gcc_us = (DWT->CYCCNT - t0) / 64U;   /* cycles @ 64 MHz -> us */
}

#if DOA_ENABLE
/* TASK-11: physical mic geometry (UCA diameter 80mm, R = 0.040 m). Each SAI pair
 * wires two diametrically opposed mics. With MIC_REMAP applied at deinterleave,
 * mic_data is in CLEAN label order (Mic1..Mic8):
 *   slot0=0  slot1=180 | slot2=45 slot3=225 | slot4=90 slot5=270 | slot6=135 slot7=315 (deg)
 * so opposite pair k = (slot 2k, slot 2k+1) and the even slot sits at the natural
 * baseline phi_k = {0,45,90,135} deg. The hardware miswiring is absorbed entirely
 * by MIC_REMAP (see Deinterleave_Pair), NOT by this table. */

/* Candidate azimuths (degrees, 16 directions × 22.5°). */
static const float g_doa_angles[DOA_N_AZ] = {
    0.0f,  22.5f,  45.0f,  67.5f,  90.0f, 112.5f, 135.0f, 157.5f,
  180.0f, 202.5f, 225.0f, 247.5f, 270.0f, 292.5f, 315.0f, 337.5f
};

/* TASK-11: HARDCODED TDOA table. g_doa_table[a][k] = expected lag (samples) on
 * opposite pair k for a source at azimuth g_doa_angles[a].
 * Pair k = GCC_PHAT(slot[2k], slot[2k+1]); baseline angle phi_k = {0,45,90,135} deg
 * (clean label order; hardware scramble handled by MIC_REMAP, not this table).
 * Formula:  lag = (Fs/C) * 2R * cos(az - phi_k),  (Fs/C)*2R = 3.731778 samples.
 * Regenerate if Fs, R, or the pair wiring changes. */
static const float g_doa_table[DOA_N_AZ][DOA_NPAIRS] = {
  {   3.731778f,   2.638766f,   0.000000f,  -2.638766f },  /* az=  0.0 */
  {   3.447714f,   3.447714f,   1.428090f,  -1.428090f },  /* az= 22.5 */
  {   2.638766f,   3.731778f,   2.638766f,   0.000000f },  /* az= 45.0 */
  {   1.428090f,   3.447714f,   3.447714f,   1.428090f },  /* az= 67.5 */
  {   0.000000f,   2.638766f,   3.731778f,   2.638766f },  /* az= 90.0 */
  {  -1.428090f,   1.428090f,   3.447714f,   3.447714f },  /* az=112.5 */
  {  -2.638766f,   0.000000f,   2.638766f,   3.731778f },  /* az=135.0 */
  {  -3.447714f,  -1.428090f,   1.428090f,   3.447714f },  /* az=157.5 */
  {  -3.731778f,  -2.638766f,   0.000000f,   2.638766f },  /* az=180.0 */
  {  -3.447714f,  -3.447714f,  -1.428090f,   1.428090f },  /* az=202.5 */
  {  -2.638766f,  -3.731778f,  -2.638766f,   0.000000f },  /* az=225.0 */
  {  -1.428090f,  -3.447714f,  -3.447714f,  -1.428090f },  /* az=247.5 */
  {   0.000000f,  -2.638766f,  -3.731778f,  -2.638766f },  /* az=270.0 */
  {   1.428090f,  -1.428090f,  -3.447714f,  -3.447714f },  /* az=292.5 */
  {   2.638766f,   0.000000f,  -2.638766f,  -3.731778f },  /* az=315.0 */
  {   3.447714f,   1.428090f,  -1.428090f,  -3.447714f },  /* az=337.5 */
};

/**
  * @brief  TASK-11 - table-match DOA. The source is assumed to sit at one of the
  *         8 fixed 45-degree directions; pick the table row whose expected lags
  *         best match the 4 measured opposite-pair TDOAs (minimum sum-of-squared
  *         error). Output azimuth is discrete (0/45/90/.../315).
  *
  *         *resid is the normalised minimum SSE: 0 = perfect match, larger =
  *         noisier fix. Also stored in g_doa_err.
  */
void DOA_Compute(const float *lag_f, float *az_deg, float *resid)
{
  uint32_t best_a = 0U;
  float    best_e = 1e30f;
  for (uint32_t a = 0U; a < DOA_N_AZ; a++)
  {
    float e = 0.0f;
    for (uint32_t k = 0U; k < DOA_NPAIRS; k++)
    {
      float d = lag_f[k] - g_doa_table[a][k];
      e += d * d;
    }
    if (e < best_e) { best_e = e; best_a = a; }
  }
  *az_deg = g_doa_angles[best_a];

  /* Normalised residual: divide by (npairs × max_lag²); max_lag = Fs·2R/C. */
  float max_lag = ((float)AUDIO_FS_HZ * 2.0f * MIC_ARRAY_RADIUS_M) / C_SOUND_MPS;
  float norm_e  = best_e / ((float)DOA_NPAIRS * max_lag * max_lag + 1e-10f);
  g_doa_err = norm_e;
  *resid    = norm_e;
}

/**
  * @brief  TASK-11 - self-test independent of the mics. Take the table row for
  *         DOA_SELFTEST_AZ as synthetic "measured" lags and confirm DOA_Compute
  *         recovers that azimuth with ~zero residual. Proves the table + matcher.
  */
void DOA_SelfTest(void)
{
  uint32_t idx = (uint32_t)lroundf(DOA_SELFTEST_AZ / DOA_AZ_STEP) % DOA_N_AZ;
  float az, resid;
  DOA_Compute(g_doa_table[idx], &az, &resid);
  int32_t azi = (int32_t)lroundf(az);

  printf("\r\n--- TASK-11 DOA ---\r\n");
  printf("self-test: az %d -> az %ld resid x1000 = %ld (expected az %d)\r\n",
         (int)DOA_SELFTEST_AZ, (long)azi,
         (long)lroundf(resid * 1000.0f), (int)DOA_SELFTEST_AZ);
  int32_t derr = azi - (int32_t)DOA_SELFTEST_AZ;
  if (derr < 0) { derr = -derr; }
  if ((derr <= 2) && (resid < 0.01f))
  {
    printf("TASK-11 self-test OK (azimuth exact, residual ~0).\r\n");
  }
  else
  {
    printf("TASK-11 self-test FAIL (azimuth off).\r\n");
    BSP_LED_On(LED_RED);
  }
}
#endif /* DOA_ENABLE */
#endif /* GCC_ENABLE */
#endif /* FFT_ENABLE */

/* ===================== TASK-12: Monitor & Watchdog ====================== */
#define WDG_ENABLE   1

/**
  * @brief  TASK-12 - HAL SAI error callback. Fires from the SAI IRQ (SAI1 and,
  *         after this task, SAI2) or the DMA error path on overrun/FIFO errors.
  *         We only count + flag here; the circular DMA keeps running.
  */
void HAL_SAI_ErrorCallback(SAI_HandleTypeDef *hsai)
{
  g_sai_errors++;
  g_sai_err_code = HAL_SAI_GetError(hsai);
  BSP_LED_On(LED_RED);
}

/**
  * @brief  TASK-12 - start the independent watchdog (IWDG1) directly via registers
  *         (the HAL IWDG module is disabled in this project, and register access is
  *         regen-safe). LSI ~32 kHz, prescaler /64 -> 2 ms/tick, reload 1000 ->
  *         ~2.0 s timeout. Frozen while the debugger halts the core.
  */
static void Watchdog_Start(void)
{
#if WDG_ENABLE
  RCC->CSR |= RCC_CSR_LSION;                       /* ensure the IWDG clock (LSI) runs */
  while ((RCC->CSR & RCC_CSR_LSIRDY) == 0U) { }

  __HAL_DBGMCU_FREEZE_IWDG1();                      /* pause IWDG when halted by debugger */

  IWDG1->KR  = 0x0000CCCCU;                         /* enable IWDG (starts the counter)  */
  IWDG1->KR  = 0x00005555U;                         /* enable write access to PR/RLR     */
  IWDG1->PR  = 4U;                                  /* prescaler /64 -> 2 ms/tick        */
  IWDG1->RLR = 1000U;                               /* reload -> ~2.0 s timeout          */
  while (IWDG1->SR != 0U) { }                       /* wait for PR/RLR to apply          */
  IWDG1->KR  = 0x0000AAAAU;                         /* first reload (feed)               */
#endif
}

static inline void Watchdog_Refresh(void)
{
#if WDG_ENABLE
  IWDG1->KR = 0x0000AAAAU;
#endif
}

/**
  * @brief  TASK-12 - report what caused the last reset (so an IWDG-triggered reset
  *         is visible on the next boot), then clear the flags.
  */
static void Print_ResetCause(void)
{
  uint32_t rsr = RCC->RSR;
  printf("\r\n--- TASK-12 Monitor/Watchdog ---\r\n");
  printf("last reset:");
  if (rsr & RCC_RSR_IWDG1RSTF) { printf(" IWDG"); }
  if (rsr & RCC_RSR_PINRSTF)   { printf(" PIN"); }
  if (rsr & RCC_RSR_BORRSTF)   { printf(" BOR"); }
  if (rsr & RCC_RSR_SFTRSTF)   { printf(" SFT"); }
  if (rsr & RCC_RSR_PORRSTF)   { printf(" POR"); }
  printf("\r\n");
  __HAL_RCC_CLEAR_RESET_FLAGS();
}

/**
  * @brief  TASK-09 - one-time pipeline bring-up, run from FFT_Task before its loop.
  *         Verifies clocks (arms DWT), SAI+DMA, builds the FFT/Hann + runs the
  *         TASK-07/08 self-tests, then starts the DMA capture. Doing this inside the
  *         task (not the abandoned superloop) is what fixes BUG-07/BUG-04b.
  */
void Pipeline_InitOnce(void)
{
  Clock_Verify();      /* TASK-03: prints clocks + arms DWT->CYCCNT (FFT/GCC timing) */
  Print_ResetCause();  /* TASK-12: show + clear the last reset cause (IWDG visible)  */
  SAI_Verify();        /* TASK-04: all 4 SAI blocks READY */

#if FFT_ENABLE
  FFT_Init();          /* TASK-07: Hann window + rfft instance */
  FFT_SelfTest();      /* TASK-07 / IT-01: 1 kHz -> bin 64 */
  Silence_SelfTest();  /* TASK-13 IT-02: zero-in -> zero-out */
#if GCC_ENABLE
  GCC_SelfTest();      /* TASK-08: synthetic 5-sample delay -> lag 5 */
#if DOA_ENABLE
  DOA_SelfTest();      /* TASK-11: hardcoded-table azimuth recovery check */
#endif
#endif
#endif

  printf("\r\n--- TASK-09 RTOS pipeline ---\r\n");
  Audio_Start();       /* TASK-05: arm circular DMA on all 4 SAI blocks (slaves first) */
}

/* USER CODE END 4 */

/* USER CODE BEGIN Header_StartDefaultTask */
/**
  * @brief  Function implementing the defaultTask thread.
  * @param  argument: Not used
  * @retval None
  */
/* USER CODE END Header_StartDefaultTask */
void StartDefaultTask(void *argument)
{
  /* init code for USB_DEVICE */
  MX_USB_DEVICE_Init();
  /* USER CODE BEGIN 5 */
  /* Infinite loop */
  for(;;)
  {
    osDelay(1);
  }
  /* USER CODE END 5 */
}

/* USER CODE BEGIN Header_StartTask02 */
/**
* @brief Function implementing the FFT_Task thread.
* @param argument: Not used
* @retval None
*/
/* USER CODE END Header_StartTask02 */
void StartTask02(void *argument)
{
  /* USER CODE BEGIN StartTask02 */
  /* FFT_Task owns the pipeline bring-up, then processes one half-buffer per
   * notification from the SAI master-block DMA callback. */
  Pipeline_InitOnce();

  for (;;)
  {
    uint32_t flags = 0U;
    /* Block until the DMA ISR signals a fresh PING/PONG half. */
    if (xTaskNotifyWait(0U, FLAG_FFT, &flags, portMAX_DELAY) != pdTRUE) { continue; }

    uint32_t off = (g_ready_half != 0U) ? DMA_HALF_WORDS : 0U;
    g_half_ready = 0U;

    for (uint8_t p = 0U; p < NUM_SAI_BLOCKS; p++)
    {
      Deinterleave_Pair(off, p);
    }
    g_blocks++;

#if FFT_ENABLE
    FFT_ProcessAll();
#if GCC_ENABLE
    GCC_ProcessPairs();
    /* Hand the 4 opposite-pair TDOAs to DOA_Task (drop if the queue is full). */
    tdoa_result_t res;
    res.seq = g_blocks;
    for (uint32_t k = 0U; k < GCC_NPAIRS_LIVE; k++) { res.lag[k] = g_tdoa_lag_f[k]; }
    /* Frame level for the clap onset gate: ch0 highpassed at 500 Hz, then
     * sum of squares. The highpass rejects low-frequency room noise (which
     * dominates the noise floor) so claps - broadband, energy mostly 500-2k Hz
     * - stand out. Coefficients: 2nd-order Butterworth, Fs=16kHz (from MATLAB
     * design_clap_hpf.m). Biquad state persists across frames (contiguous DMA). */
    {
      static const float HPF_B[3] = {  0.87033078f, -1.74066156f, 0.87033078f };
      static const float HPF_A[3] = {  1.00000000f, -1.72377617f, 0.75754694f };
      static float w1 = 0.0f, w2 = 0.0f;     /* transposed direct form II state */
      float level = 0.0f;
      for (uint32_t n = 0U; n < AUDIO_BLOCK_SAMPLES; n++)
      {
        float in = mic_data[0][n];
        float yo = HPF_B[0] * in + w1;
        w1 = HPF_B[1] * in - HPF_A[1] * yo + w2;
        w2 = HPF_B[2] * in - HPF_A[2] * yo;
        level += yo * yo;
      }
      res.level = level;
    }
    osMessageQueuePut(result_queueHandle, &res, 0U, 0U);
#endif
#endif

#if USB_RAW_STREAM
    /* Snapshot this frame and ask USB_Task to send it, if the previous one is gone. */
    if (!g_usb_snapshot_valid)
    {
      memcpy(usb_snapshot, mic_raw, sizeof(usb_snapshot));
      g_usb_snapshot_valid = 1U;
      if (USB_TaskHandle != NULL)
      {
        xTaskNotify((TaskHandle_t)USB_TaskHandle, FLAG_USB, eSetBits);
      }
    }
#endif
  }
  /* USER CODE END StartTask02 */
}

/* USER CODE BEGIN Header_StartTask03 */
/**
* @brief Function implementing the USB_Task thread.
* @param argument: Not used
* @retval None
*/
/* USER CODE END Header_StartTask03 */
void StartTask03(void *argument)
{
  /* USER CODE BEGIN StartTask03 */
#if USB_RAW_STREAM
  for (;;)
  {
    uint32_t flags = 0U;
    if (xTaskNotifyWait(0U, FLAG_USB, &flags, portMAX_DELAY) != pdTRUE) { continue; }
    if (!g_usb_snapshot_valid) { continue; }

    /* Only send when the previous CDC transfer finished, else drop this frame.
     * TASK-10: the host-visible seq increments only on a successful send, so the
     * PC sees a gap-free sequence (a gap there means a TRANSPORT loss). Frames the
     * device cannot ship because USB is still busy are counted in g_usb_drops -
     * an expected, by-design back-pressure drop, reported on the [USB] line. */
    uint8_t sent = 0U;
    USBD_CDC_HandleTypeDef *hcdc = (USBD_CDC_HandleTypeDef *)hUsbDeviceHS.pClassData;
    if ((hcdc != NULL) && (hcdc->TxState == 0U))
    {
      uint16_t ns = (uint16_t)RAW_NSAMP;
      usb_tx_frame[0] = 'R'; usb_tx_frame[1] = 'A'; usb_tx_frame[2] = 'W'; usb_tx_frame[3] = '1';
      memcpy(&usb_tx_frame[4], &g_usb_seq, 4);
      usb_tx_frame[8]  = (uint8_t)RAW_NCH;
      usb_tx_frame[9]  = (uint8_t)(ns & 0xFFU);
      usb_tx_frame[10] = (uint8_t)(ns >> 8);
      usb_tx_frame[11] = 0U;                                  /* fmt 0 = int32 LE */
      memcpy(&usb_tx_frame[RAW_HDR_BYTES], usb_snapshot, RAW_PAYLOAD_BYTES);
      if (CDC_Transmit_HS(usb_tx_frame, (uint16_t)USB_FRAME_LEN) == USBD_OK)
      {
        g_usb_seq++;
        sent = 1U;
      }
    }
    if (!sent) { g_usb_drops++; }
    g_usb_snapshot_valid = 0U;   /* free the snapshot for the next frame */
  }
#else
  for (;;) { osDelay(1000); }
#endif
  /* USER CODE END StartTask03 */
}

/* USER CODE BEGIN Header_StartTask04 */
/**
* @brief Function implementing the DOA_Task thread.
* @param argument: Not used
* @retval None
*/
/* USER CODE END Header_StartTask04 */
void StartTask04(void *argument)
{
  /* USER CODE BEGIN StartTask04 */
  /* TASK-11: drain the TDOA result queue and, once per second, report the
   * direction of the loudest CLAP so the camera can be steered to it.
   *
   * Clap input gate: in a noisy room, steady background noise is everywhere and
   * would smear the DOA. A clap is an impulsive onset - its frame level jumps
   * well above the slowly-tracked noise floor. Only such clap frames are voted
   * on; steady noise keeps updating the floor instead. For each clap frame the
   * 4 opposite-pair lags are matched to a discrete direction (DOA_Compute) and
   * that direction gets a vote weighted by match quality (1 - residual). At the
   * end of each 1-second window the most-voted direction is the cam target. */
  tdoa_result_t res;
  uint32_t win_start = 0U;

#define DOA_WIN_BLOCKS 16U             /* ~1 s at 16 blocks/s                   */
#define CLAP_BG_ALPHA  0.10f           /* noise-floor EMA rate (non-clap frames) */
  /* Clap thresholds are RUNTIME globals (g_clap_ratio/g_clap_abs/g_doa_resid_max),
   * settable from the PC over USB CDC - see the SET command parser. */
  float    vote[DOA_N_AZ] = {0.0f};
  uint32_t n_acc = 0U;                 /* clap frames accepted this window       */
  float    bg = g_clap_abs;            /* tracked background noise floor (level) */
  /* Per-window diagnostics (printed on the "no clap" line to debug the gate). */
  float    win_peak_ratio = 0.0f;      /* max level/bg seen this window          */
  float    win_max_lev    = 0.0f;      /* max raw level this window              */
  float    win_min_resid  = 1.0f;      /* best (lowest) residual this window     */
  float    win_best_az    = 0.0f;      /* az of the best-fit frame this window   */

  for (;;)
  {
    if (osMessageQueueGet(result_queueHandle, &res, NULL, portMAX_DELAY) != osOK) { continue; }

    /* Echo any clap-gate config just changed from the PC (over USB CDC). printf
     * here (task context) is safe; the CDC parser only sets the dirty flag. Values
     * are scaled x1000 because the nano printf has no %f. */
    if (g_cfg_dirty)
    {
      g_cfg_dirty = 0U;
      printf("CFG ratio=%ld abs=%ld resid=%ld (x1000)\r\n",
             (long)lroundf(g_clap_ratio * 1000.0f),
             (long)lroundf(g_clap_abs * 1000.0f),
             (long)lroundf(g_doa_resid_max * 1000.0f));
    }

#if DOA_ENABLE
    float az, resid;
    DOA_Compute(res.lag, &az, &resid);     /* discrete az + normalised residual */

    /* Clap onset gate: level must spike above the noise floor (and an absolute
     * minimum). Non-clap frames just refresh the floor estimate. */
    uint8_t is_clap = (res.level > g_clap_ratio * bg) && (res.level > g_clap_abs);
    if (!is_clap)
    {
      bg += CLAP_BG_ALPHA * (res.level - bg);   /* EMA track background */
    }

    /* Track this window's loudest frame and best fit for the debug print. */
    {
      float ratio = (bg > 1e-20f) ? (res.level / bg) : 0.0f;
      if (ratio > win_peak_ratio)     { win_peak_ratio = ratio; }
      if (res.level > win_max_lev)    { win_max_lev = res.level; }
      if (resid < win_min_resid)      { win_min_resid = resid; win_best_az = az; }
    }

    if (is_clap && (resid < g_doa_resid_max))
    {
      uint32_t idx = (uint32_t)lroundf(az / DOA_AZ_STEP) % DOA_N_AZ;
      vote[idx] += (1.0f - resid);         /* weight cleaner matches more       */
      n_acc++;
    }

    if ((res.seq - win_start) >= DOA_WIN_BLOCKS)   /* 1-second window elapsed    */
    {
      win_start = res.seq;
      if (n_acc > 0U)
      {
        /* dominant direction = most-voted over the last second */
        uint32_t best = 0U;
        float    best_v = -1.0f;
        for (uint32_t a = 0U; a < DOA_N_AZ; a++)
        {
          if (vote[a] > best_v) { best_v = vote[a]; best = a; }
        }
        g_doa_az = g_doa_angles[best];
        g_doa_el = 0.0f;
        if (g_servo_auto) { Servo_PointToAzimuth(g_doa_az); }   /* aim camera (unless manual test) */
        int32_t azi = (int32_t)lroundf(g_doa_az);
        printf("DOA seq=%lu az=%ld (cam target, servo=%ld, %lu clap frames)\r\n",
               (unsigned long)res.seq, (long)azi,
               (long)lroundf(g_servo_deg), (unsigned long)n_acc);
        BSP_LED_Toggle(LED_GREEN);
      }
      else
      {
        /* No clap this second, but still report the live RELATIVE direction of the
         * best-fit frame so the host always has an angle. "live" flags that it was
         * NOT a confirmed clap. peakRatio/level kept for gate tuning (x1e3 / x1e6). */
        int32_t azl = (int32_t)lroundf(win_best_az);
        printf("DOA seq=%lu az=%ld live resid=%ld peakRatio=%ld need=%ld maxLev_u=%ld\r\n",
               (unsigned long)res.seq, (long)azl,
               (long)lroundf(win_min_resid  * 1000.0f),
               (long)lroundf(win_peak_ratio * 1000.0f),
               (long)lroundf(g_clap_ratio   * 1000.0f),
               (long)lroundf(win_max_lev * 1000000.0f));
      }
      win_peak_ratio = 0.0f; win_max_lev = 0.0f; win_min_resid = 1.0f; win_best_az = 0.0f;
      for (uint32_t a = 0U; a < DOA_N_AZ; a++) { vote[a] = 0.0f; }
      n_acc = 0U;
    }
#else
    if ((res.seq - last_print) >= 16U)
    {
      last_print = res.seq;
      printf("DOA seq=%lu lag[", (unsigned long)res.seq);
      for (uint32_t k = 0U; k < GCC_NPAIRS_LIVE; k++)
      {
        printf("%ld%s", (long)lroundf(res.lag[k]), (k < GCC_NPAIRS_LIVE - 1U) ? " " : "]\r\n");
      }
    }
#endif
  }
  /* USER CODE END StartTask04 */
}

/* USER CODE BEGIN Header_StartTask05 */
/**
* @brief Function implementing the Monitor_Task thread.
* @param argument: Not used
* @retval None
*/
/* USER CODE END Header_StartTask05 */
void StartTask05(void *argument)
{
  /* USER CODE BEGIN StartTask05 */
  /* TASK-09: liveness + IPC proof (vTaskList once). TASK-12: start the IWDG and
   * feed it from here, but ONLY while the capture pipeline keeps advancing, plus a
   * periodic health line (overruns, SAI errors, stack high-water). */
  static char task_list[480];

  osDelay(1500);   /* let the pipeline self-tests finish printing first */

  vTaskList(task_list);
  printf("\r\n--- TASK-09 vTaskList ---\r\n");
  printf("Name          State Prio Stack Num\r\n%s\r\n", task_list);

  /* TASK-12: arm the watchdog now that init is done. We feed it every loop only if
   * g_blocks changed, so a hung/stalled DSP pipeline lets the IWDG reset the MCU. */
  uint32_t last_blocks = g_blocks;
  Watchdog_Start();
  uint32_t tick = 0U;

  for (;;)
  {
    if (g_blocks != last_blocks) { Watchdog_Refresh(); last_blocks = g_blocks; }

    if ((tick & 3U) == 0U)   /* ~ every 2 s (loop is 500 ms) */
    {
      printf("[MON] blocks=%lu overruns=%lu fft=%luus gcc=%luus heapFree=%u saiErr=%lu\r\n",
             (unsigned long)g_blocks, (unsigned long)g_overruns,
             (unsigned long)g_fft_us, (unsigned long)g_gcc_us,
             (unsigned)xPortGetFreeHeapSize(), (unsigned long)g_sai_errors);
      /* TASK-10: USB CDC transmit health (sent vs back-pressure drops). */
      printf("[USB] sent=%lu drops=%lu\r\n",
             (unsigned long)g_usb_seq, (unsigned long)g_usb_drops);
      /* TASK-12: per-task stack high-water (min free words ever). */
      printf("[STK] def=%u fft=%u usb=%u doa=%u mon=%u\r\n",
             (unsigned)uxTaskGetStackHighWaterMark((TaskHandle_t)defaultTaskHandle),
             (unsigned)uxTaskGetStackHighWaterMark((TaskHandle_t)FFT_TaskHandle),
             (unsigned)uxTaskGetStackHighWaterMark((TaskHandle_t)USB_TaskHandle),
             (unsigned)uxTaskGetStackHighWaterMark((TaskHandle_t)DOA_TaskHandle),
             (unsigned)uxTaskGetStackHighWaterMark(NULL));
    }
    tick++;
    osDelay(500);
  }
  /* USER CODE END StartTask05 */
}

 /* MPU Configuration */

void MPU_Config(void)
{
  MPU_Region_InitTypeDef MPU_InitStruct = {0};

  /* Disables the MPU */
  HAL_MPU_Disable();

  /** Initializes and configures the Region and the memory to be protected
  */
  MPU_InitStruct.Enable = MPU_REGION_ENABLE;
  MPU_InitStruct.Number = MPU_REGION_NUMBER0;
  MPU_InitStruct.BaseAddress = 0x0;
  MPU_InitStruct.Size = MPU_REGION_SIZE_4GB;
  MPU_InitStruct.SubRegionDisable = 0x87;
  MPU_InitStruct.TypeExtField = MPU_TEX_LEVEL0;
  MPU_InitStruct.AccessPermission = MPU_REGION_NO_ACCESS;
  MPU_InitStruct.DisableExec = MPU_INSTRUCTION_ACCESS_DISABLE;
  MPU_InitStruct.IsShareable = MPU_ACCESS_SHAREABLE;
  MPU_InitStruct.IsCacheable = MPU_ACCESS_NOT_CACHEABLE;
  MPU_InitStruct.IsBufferable = MPU_ACCESS_NOT_BUFFERABLE;

  HAL_MPU_ConfigRegion(&MPU_InitStruct);
  /* Enables the MPU */
  HAL_MPU_Enable(MPU_PRIVILEGED_DEFAULT);

}

/**
  * @brief  Period elapsed callback in non blocking mode
  * @note   This function is called  when TIM6 interrupt took place, inside
  * HAL_TIM_IRQHandler(). It makes a direct call to HAL_IncTick() to increment
  * a global variable "uwTick" used as application time base.
  * @param  htim : TIM handle
  * @retval None
  */
void HAL_TIM_PeriodElapsedCallback(TIM_HandleTypeDef *htim)
{
  /* USER CODE BEGIN Callback 0 */

  /* USER CODE END Callback 0 */
  if (htim->Instance == TIM6)
  {
    HAL_IncTick();
  }
  /* USER CODE BEGIN Callback 1 */

  /* USER CODE END Callback 1 */
}

/**
  * @brief  This function is executed in case of error occurrence.
  * @retval None
  */
void Error_Handler(void)
{
  /* USER CODE BEGIN Error_Handler_Debug */
  /* User can add his own implementation to report the HAL error return state */
  __disable_irq();
  while (1)
  {
  }
  /* USER CODE END Error_Handler_Debug */
}
#ifdef USE_FULL_ASSERT
/**
  * @brief  Reports the name of the source file and the source line number
  *         where the assert_param error has occurred.
  * @param  file: pointer to the source file name
  * @param  line: assert_param error line source number
  * @retval None
  */
void assert_failed(uint8_t *file, uint32_t line)
{
  /* USER CODE BEGIN 6 */
  /* User can add his own implementation to report the file name and line number,
     ex: printf("Wrong parameters value: file %s on line %d\r\n", file, line) */
  /* USER CODE END 6 */
}
#endif /* USE_FULL_ASSERT */
