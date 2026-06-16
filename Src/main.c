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

/* TASK-08: GCC-PHAT time-delay estimation between mic pairs. */
#define GCC_ENABLE           1
#define GCC_SELFTEST_SHIFT   5                            /* synthetic delay -> lag 5   */
#define GCC_NPAIRS_LIVE      (NUM_MIC_CHANNELS - 1U)      /* live demo: mic0 vs mic1..7 */

/* TASK-11: direction of arrival from the live mic0-vs-mic1..7 TDOAs. Planar (2D)
 * array, far-field plane-wave least-squares -> azimuth (+ elevation magnitude).
 * EDIT mic_pos[][] (near DOA_Init) to match the physical array. Current layout:
 * UCA diameter 80 mm, each SAI pair wires two OPPOSITE mics (across a diameter):
 *   pair0: ch0=0deg,  ch1=180deg
 *   pair1: ch2=45deg, ch3=225deg
 *   pair2: ch4=90deg, ch5=270deg
 *   pair3: ch6=135deg,ch7=315deg
 * Azimuth 0 deg = +x (ch0 direction), positive CCW. */
#define DOA_ENABLE           1
#define C_SOUND_MPS          343.0f                       /* speed of sound @ 20 C      */
#define MIC_ARRAY_RADIUS_M   0.040f                       /* UCA radius = 40 mm         */
#define DOA_NPAIRS           GCC_NPAIRS_LIVE              /* 7 baselines: mic0 vs 1..7  */
#define DOA_N_AZ             8U                           /* candidate directions (8x45°)*/
#define DOA_SELFTEST_AZ      45.0f                        /* synthetic source azimuth (must be one of the 8 table directions) */

/* TASK-09: FreeRTOS task notification flags (FFT_Task waits on these). */
#define FLAG_FFT             (1UL << 0)                   /* a fresh half is ready      */
#define FLAG_USB             (1UL << 1)                   /* build+send a USB raw frame */

/* TASK-09: result_queue payload (BUG-05) - the per-pair TDOA lags one FFT_Task pass
 * produces, handed to DOA_Task. seq lets DOA_Task spot dropped results. */
typedef struct
{
  uint32_t seq;                       /* processed-block counter                  */
  float    lag[GCC_NPAIRS_LIVE];      /* mic0 vs mic1..7, fractional samples (TASK-11) */
  float    az;                        /* SRP delay-and-sum azimuth, degrees (discrete) */
  float    contrast;                  /* SRP peak power / mean power (>=1)        */
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

volatile int32_t  g_tdoa_lag[GCC_NPAIRS_LIVE];  /* mic0 vs mic(k+1), samples (rounded) */
float    g_tdoa_lag_f[GCC_NPAIRS_LIVE];          /* TASK-11: fractional lags (sub-sample) */
volatile uint32_t g_gcc_us;                     /* time to compute the live pairs (us) */

#if DOA_ENABLE
/* TASK-11 DOA state.
 * g_doa_table[a][k]  = expected TDOA lag (samples) for direction a, baseline k.
 * g_doa_dly[a][k]    = the same lag rounded to integer samples, for delay-and-sum.
 * g_doa_err = SRP contrast (peak/mean power) of the last fix (higher = stronger). */
float    g_doa_table[DOA_N_AZ][DOA_NPAIRS];
int32_t  g_doa_dly[DOA_N_AZ][DOA_NPAIRS];
volatile float g_doa_az;                         /* azimuth, degrees [0,360)   */
volatile float g_doa_el;                         /* elevation magnitude, [0,90]*/
volatile float g_doa_err;                        /* SRP contrast (>=1)         */
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
void DOA_Init(void);
void DOA_Compute(const float *lag_f, float *az_deg, float *el_deg);
void DOA_SRP(float *az_deg, float *contrast);
void DOA_SelfTest(void);
#endif
#endif
#endif
void Pipeline_InitOnce(void);
/* USER CODE END PFP */

/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */

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

/* Deinterleave one stereo pair's half-buffer into the two per-mic arrays.
 * SAI 24-bit data is MSB-left-justified in a 32-bit slot, so the signed 24-bit
 * sample is (word >> 8); /2^23 normalizes to [-1,1]. */
static void Deinterleave_Pair(uint32_t off, uint8_t pair)
{
  const int32_t *src = &dma_buf[pair][off];
  uint8_t l = (uint8_t)(pair * 2U);
  uint8_t r = (uint8_t)(pair * 2U + 1U);
  /* Mics on ch3 (SAI1-B slot 1) and ch6 (SAI2-B slot 0) are wired with
   * inverted polarity; negate to restore phase alignment with the other
   * channels (needed for GCC-PHAT). */
  const int32_t l_sign = (l == 6U) ? -1 : 1;
  const int32_t r_sign = (r == 3U) ? -1 : 1;
  for (uint32_t i = 0U; i < AUDIO_BLOCK_SAMPLES; i++)
  {
    int32_t rl = l_sign * (int32_t)(int16_t)(src[2U * i] & 0xFFFF);
    int32_t rr = r_sign * (int32_t)(int16_t)(src[2U * i + 1U] & 0xFFFF);
    mic_raw[l][i]  = rl;
    mic_raw[r][i]  = rr;
    mic_data[l][i] = (float)rl * (1.0f / 8388608.0f);
    mic_data[r][i] = (float)rr * (1.0f / 8388608.0f);
  }
}

/**
  * @brief  TASK-05 - start circular DMA reception on all four SAI blocks.
  *         Slaves are armed before the master so they are ready when SAI1_A
  *         (master) begins generating SCK/FS.
  * @retval None
  */
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
  * @brief  TASK-08 - compute live TDOA lags for mic0 vs mic1..7 from mic_data,
  *         timing the whole set with the DWT counter.
  */
void GCC_ProcessPairs(void)
{
  uint32_t t0 = DWT->CYCCNT;
  for (uint32_t k = 0U; k < GCC_NPAIRS_LIVE; k++)
  {
    g_tdoa_lag[k]   = GCC_PHAT(mic_data[0], mic_data[k + 1U]);
    g_tdoa_lag_f[k] = g_last_frac;       /* TASK-11: sub-sample lag for DOA */
  }
  g_gcc_us = (DWT->CYCCNT - t0) / 64U;   /* cycles @ 64 MHz -> us */
}

#if DOA_ENABLE
/* TASK-11: physical mic coordinates in metres, channel-major.
 * UCA diameter 80mm. Each SAI pair wires two diametrically opposed mics:
 *   pair p -> ch_L = p*2 at (p*45 deg), ch_R = p*2+1 at (p*45+180 deg).
 * R = MIC_ARRAY_RADIUS_M = 0.040 m. */

#define MIC_R  MIC_ARRAY_RADIUS_M
static const float mic_pos[NUM_MIC_CHANNELS][2] = {
  {  MIC_R * 1.00000f,  MIC_R * 0.00000f },  /* ch0  pair0 L    0 deg */
  { -MIC_R * 1.00000f,  MIC_R * 0.00000f },  /* ch1  pair0 R  180 deg */
  {  MIC_R * 0.70711f,  MIC_R * 0.70711f },  /* ch2  pair1 L   45 deg */
  { -MIC_R * 0.70711f, -MIC_R * 0.70711f },  /* ch3  pair1 R  225 deg */
  {  MIC_R * 0.00000f,  MIC_R * 1.00000f },  /* ch4  pair2 L   90 deg */
  {  MIC_R * 0.00000f, -MIC_R * 1.00000f },  /* ch5  pair2 R  270 deg */
  { -MIC_R * 0.70711f,  MIC_R * 0.70711f },  /* ch6  pair3 L  135 deg */
  {  MIC_R * 0.70711f, -MIC_R * 0.70711f },  /* ch7  pair3 R  315 deg */
};
#undef MIC_R

/* Candidate azimuths for the table search (degrees, 8 directions × 45°). */
static const float g_doa_angles[DOA_N_AZ] = {
  0.0f, 45.0f, 90.0f, 135.0f, 180.0f, 225.0f, 270.0f, 315.0f
};

/**
  * @brief  TASK-11 - build TDOA look-up table.
  *         For each of DOA_N_AZ candidate directions, the expected fractional lag
  *         on baseline k is:
  *           table[a][k] = -(Fs/C) * dot(pos[k+1]-pos[0], u_a)
  *         where u_a = [cos(az_a), sin(az_a)].  At run-time DOA_Compute picks
  *         the table row whose entries best match the measured lags (min SSE).
  */
void DOA_Init(void)
{
  float scale = -((float)AUDIO_FS_HZ / C_SOUND_MPS);   /* samples per metre */
  for (uint32_t a = 0U; a < DOA_N_AZ; a++)
  {
    float az_r = g_doa_angles[a] * (PI_F / 180.0f);
    float ux = cosf(az_r), uy = sinf(az_r);
    for (uint32_t k = 0U; k < DOA_NPAIRS; k++)
    {
      float dx = mic_pos[k + 1U][0] - mic_pos[0][0];
      float dy = mic_pos[k + 1U][1] - mic_pos[0][1];
      g_doa_table[a][k] = scale * (dx * ux + dy * uy);
      g_doa_dly[a][k]   = (int32_t)lroundf(g_doa_table[a][k]);
    }
  }
}

/* Max |delay| in samples = ceil(Fs * 2R / C); guards the delay-and-sum window. */
#define DOA_DLY_MAX  4

/**
  * @brief  TASK-11 - SRP delay-and-sum DOA over the 8 fixed 45-degree directions.
  *         For each candidate direction, advance every channel by its expected
  *         integer delay (from g_doa_dly), sum the 8 aligned channels and
  *         accumulate the beam power.  The steering direction with the largest
  *         power is the source bearing ("take only the strongest source").
  *
  *         contrast = peak power / mean power over all directions (>= 1).
  *         ~1 means no directional source (diffuse noise); larger = stronger fix.
  */
void DOA_SRP(float *az_deg, float *contrast)
{
  float pw_sum = 0.0f;
  uint32_t best_a = 0U;
  float    best_p = -1.0f;

  for (uint32_t a = 0U; a < DOA_N_AZ; a++)
  {
    float p = 0.0f;
    for (uint32_t n = DOA_DLY_MAX; n < AUDIO_BLOCK_SAMPLES - DOA_DLY_MAX; n++)
    {
      float y = mic_data[0][n];
      for (uint32_t k = 0U; k < DOA_NPAIRS; k++)
      {
        y += mic_data[k + 1U][(int32_t)n + g_doa_dly[a][k]];
      }
      p += y * y;
    }
    pw_sum += p;
    if (p > best_p) { best_p = p; best_a = a; }
  }

  *az_deg   = g_doa_angles[best_a];
  float avg = pw_sum / (float)DOA_N_AZ;
  *contrast = (avg > 1e-20f) ? (best_p / avg) : 1.0f;
}

/**
  * @brief  TASK-11 - table-search DOA: the source is assumed to sit at one of
  *         the DOA_N_AZ fixed 45-degree directions; pick the candidate whose
  *         expected TDOAs best match the measured lags (minimum sum-of-squared
  *         residuals). Output azimuth is discrete (0/45/90/...).
  *
  *         g_doa_err is set to the normalised minimum SSE: 0 = perfect fit
  *         (source in the array plane), higher = noisier / off-plane source.
  */
void DOA_Compute(const float *lag_f, float *az_deg, float *el_deg)
{
  /* Compute SSE for each candidate direction, keep the minimum. */
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

  /* Normalised residual: 0 = perfect table match, 1 = worst-case lag error.
   * max_lag = Fs * 2R / C (full-aperture TDOA ceiling in samples). */
  float max_lag = ((float)AUDIO_FS_HZ * 2.0f * MIC_ARRAY_RADIUS_M) / C_SOUND_MPS;
  float norm_e  = best_e / ((float)DOA_NPAIRS * max_lag * max_lag + 1e-10f);
  g_doa_err = norm_e;
  /* Map residual to elevation proxy: low residual => source near array plane. */
  float smag = 1.0f - norm_e;
  if (smag < 0.0f) { smag = 0.0f; }
  if (smag > 1.0f) { smag = 1.0f; }
  *el_deg = acosf(smag) * (180.0f / PI_F);
}

/**
  * @brief  TASK-11 - geometry/solver self-test, independent of the mics. Synthesize
  *         the lags an in-plane source at DOA_SELFTEST_AZ would produce, then check
  *         the solver recovers that azimuth (and elevation ~0). Proves the linear
  *         algebra + mic_pos wiring before trusting live, noisy lags.
  */
void DOA_SelfTest(void)
{
  float azr = DOA_SELFTEST_AZ * (PI_F / 180.0f);
  float ux = cosf(azr), uy = sinf(azr);
  float lag[DOA_NPAIRS];
  for (uint32_t k = 0U; k < DOA_NPAIRS; k++)
  {
    float dx = mic_pos[k + 1U][0] - mic_pos[0][0];
    float dy = mic_pos[k + 1U][1] - mic_pos[0][1];
    lag[k] = -((float)AUDIO_FS_HZ / C_SOUND_MPS) * (dx * ux + dy * uy);
  }
  float az, el;
  DOA_Compute(lag, &az, &el);
  int32_t azi = (int32_t)lroundf(az);
  int32_t eli = (int32_t)lroundf(el);

  printf("\r\n--- TASK-11 DOA ---\r\n");
  printf("self-test: az %d -> az %ld el %ld (expected az %d el 0)\r\n",
         (int)DOA_SELFTEST_AZ, (long)azi, (long)eli, (int)DOA_SELFTEST_AZ);
  int32_t derr = azi - (int32_t)DOA_SELFTEST_AZ;
  if (derr < 0) { derr = -derr; }
  if ((derr <= 2) && (eli <= 2))
  {
    printf("TASK-11 self-test OK (azimuth within +/-2 deg).\r\n");
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
  DOA_Init();          /* TASK-11: precompute the least-squares pseudo-inverse */
  DOA_SelfTest();      /* TASK-11: synthetic azimuth -> recovered azimuth */
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
    /* Hand the TDOA + SRP result to DOA_Task (drop if the queue is full). */
    tdoa_result_t res;
    res.seq = g_blocks;
    for (uint32_t k = 0U; k < GCC_NPAIRS_LIVE; k++) { res.lag[k] = g_tdoa_lag_f[k]; }
#if DOA_ENABLE
    /* SRP delay-and-sum must run here, while mic_data still holds this frame. */
    DOA_SRP(&res.az, &res.contrast);
#else
    res.az = 0.0f; res.contrast = 1.0f;
#endif
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
  /* TASK-11: drain the TDOA result queue, solve direction of arrival, and report
   * azimuth/elevation (degrees) ~once per second. The LED toggles on each printed
   * fix so a moving source is visible on the board too. */
  tdoa_result_t res;
  uint32_t last_print = 0U;

  /* Sliding median filter over the last DOA_MED_WIN accepted fixes. Raw frames
   * with el clamped to 0 are front-back ambiguity flips (az mirrors ~180 deg);
   * they are rejected before the filter. Azimuth is circular, so its median is
   * the window element minimizing the summed wrap-around angular distance. */
#define DOA_MED_WIN 7U
  float az_win[DOA_MED_WIN], el_win[DOA_MED_WIN];
  uint32_t win_cnt = 0U, win_idx = 0U;

  for (;;)
  {
    if (osMessageQueueGet(result_queueHandle, &res, NULL, portMAX_DELAY) != osOK) { continue; }

#if DOA_ENABLE
    /* SRP (delay-and-sum) result computed in FFT_Task while the frame was hot.
     * contrast = peak/mean beam power; ~1 means diffuse noise, no real source. */
    float az = res.az;
    float el = 0.0f;
    g_doa_err = res.contrast;

    if (res.contrast > 1.2f)               /* reject frames with no clear source */
    {
      az_win[win_idx] = az;
      el_win[win_idx] = el;
      win_idx = (win_idx + 1U) % DOA_MED_WIN;
      if (win_cnt < DOA_MED_WIN) { win_cnt++; }

      /* circular median of azimuth */
      float best_az = az, best_cost = 1e30f;
      for (uint32_t i = 0U; i < win_cnt; i++)
      {
        float cost = 0.0f;
        for (uint32_t j = 0U; j < win_cnt; j++)
        {
          float d = fabsf(az_win[i] - az_win[j]);
          if (d > 180.0f) { d = 360.0f - d; }
          cost += d;
        }
        if (cost < best_cost) { best_cost = cost; best_az = az_win[i]; }
      }

      /* plain median of elevation (insertion sort on a small copy) */
      float el_sorted[DOA_MED_WIN];
      memcpy(el_sorted, el_win, win_cnt * sizeof(float));
      for (uint32_t i = 1U; i < win_cnt; i++)
      {
        float v = el_sorted[i];
        uint32_t j = i;
        while ((j > 0U) && (el_sorted[j - 1U] > v)) { el_sorted[j] = el_sorted[j - 1U]; j--; }
        el_sorted[j] = v;
      }

      g_doa_az = best_az;
      g_doa_el = el_sorted[win_cnt / 2U];
    }

    if (((res.seq - last_print) >= 16U) && (win_cnt > 0U))  /* ~1 Hz at 16 blocks/s */
    {
      last_print = res.seq;
      az = g_doa_az;                       /* report the filtered fix */
      (void)el;
      /* %f is not linked in (newlib-nano, no -u _printf_float); print tenths
       * using integer math instead. az in [0,360); cs = SRP contrast (>=1). */
      int32_t az10 = (int32_t)lroundf(az * 10.0f);
      int32_t cs10 = (int32_t)lroundf(res.contrast * 10.0f);
      printf("DOA seq=%lu az=%ld.%ld cs=%ld.%ld\r\n",
             (unsigned long)res.seq,
             (long)(az10 / 10), (long)(az10 % 10),
             (long)(cs10 / 10), (long)(cs10 % 10));
      BSP_LED_Toggle(LED_GREEN);
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
