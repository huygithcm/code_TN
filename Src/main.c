/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file           : main.c
  * @brief          : Main program body
  * @author VŨ ĐÔNG TRIỀU
  *
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
#include "usb_device.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include <stdio.h>
#include <string.h>
#include "usbd_cdc_if.h"
#include "usbd_cdc.h"
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
uint32_t g_usb_seq;                 /* raw frames successfully queued to USB        */

#if USB_RAW_STREAM
/* USB CDC raw streaming frame (header + int32 channel-major payload). */
uint8_t  usb_tx_frame[USB_FRAME_LEN];
extern USBD_HandleTypeDef hUsbDeviceHS;
#endif
/* USER CODE END PV */

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
void PeriphCommonClock_Config(void);
static void MPU_Config(void);
static void MX_GPIO_Init(void);
static void MX_DMA_Init(void);
static void MX_SAI1_Init(void);
static void MX_SAI2_Init(void);
/* USER CODE BEGIN PFP */
void Clock_Verify(void);
void SAI_Verify(void);
void Audio_Start(void);
static void Deinterleave_Pair(uint32_t off, uint8_t pair);
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
  MX_USB_DEVICE_Init();
  /* USER CODE BEGIN 2 */

  /* USER CODE END 2 */

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

  /* Infinite loop */
  /* USER CODE BEGIN WHILE */
  /* TASK-03: verify clock tree and arm the DWT cycle counter (COM1/VCP now up) */
  Clock_Verify();
  /* TASK-04: confirm SAI + DMA init succeeded for all 4 blocks */
  SAI_Verify();

  /* TASK-05: start the SAI DMA ping-pong capture and confirm callbacks fire */
  Audio_Start();
  HAL_Delay(1000);
  printf("\r\n--- TASK-05 DMA Ping-Pong ---\r\n");
  uint32_t live = 0U;
  for (int i = 0; i < (int)NUM_SAI_BLOCKS; i++)
  {
    printf("pair%d: half=%lu full=%lu\r\n", i,
           (unsigned long)dma_half_cnt[i], (unsigned long)dma_full_cnt[i]);
    if ((dma_half_cnt[i] > 0U) && (dma_full_cnt[i] > 0U)) { live++; }
  }
  if (live == NUM_SAI_BLOCKS)
  {
    printf("TASK-05 OK: all 4 DMA streams ping-ponging.\r\n");
  }
  else
  {
    printf("TASK-05 FAIL: %lu/4 streams active.\r\n", (unsigned long)live);
    BSP_LED_On(LED_RED);
  }

  /* TASK-06: deinterleave each ready half into per-mic buffers; optionally stream raw to USB. */
  __disable_irq();
  g_half_ready = 0U;
  g_overruns = 0U;
  __enable_irq();

  printf("\r\n--- TASK-06 Deinterleave%s ---\r\n",
         USB_RAW_STREAM ? " + raw USB CDC stream" : "");
  uint32_t blocks = 0U;

  while (1)
  {
    if (g_half_ready)
    {
      uint32_t off = (g_ready_half != 0U) ? DMA_HALF_WORDS : 0U;
      g_half_ready = 0U;

      for (uint8_t p = 0U; p < NUM_SAI_BLOCKS; p++)
      {
        Deinterleave_Pair(off, p);
      }
      blocks++;

      /* ~1 Hz VCP heartbeat before optional USB work, so USB faults are visible. */
      if ((blocks % 16U) == 0U)
      {
        int32_t mn = mic_raw[0][0], mx = mic_raw[0][0];
        for (uint32_t i = 1U; i < AUDIO_BLOCK_SAMPLES; i++)
        {
          if (mic_raw[0][i] < mn) { mn = mic_raw[0][i]; }
          if (mic_raw[0][i] > mx) { mx = mic_raw[0][i]; }
        }
        printf("blk=%lu mic0[min=%ld max=%ld] usb_seq=%lu overruns=%lu\r\n",
               (unsigned long)blocks, (long)mn, (long)mx,
               (unsigned long)g_usb_seq, (unsigned long)g_overruns);
      }

#if USB_RAW_STREAM
      /* Only (re)build and send when the previous CDC transfer has finished, so we never
       * overwrite usb_tx_frame while it is in flight. Frames are dropped if USB is busy. */
      USBD_CDC_HandleTypeDef *hcdc = (USBD_CDC_HandleTypeDef *)hUsbDeviceHS.pClassData;
      if ((hcdc != NULL) && (hcdc->TxState == 0U))
      {
        uint16_t ns = (uint16_t)RAW_NSAMP;
        usb_tx_frame[0] = 'R'; usb_tx_frame[1] = 'A'; usb_tx_frame[2] = 'W'; usb_tx_frame[3] = '1';
        memcpy(&usb_tx_frame[4], &g_usb_seq, 4);
        usb_tx_frame[8] = (uint8_t)RAW_NCH;
        usb_tx_frame[9] = (uint8_t)(ns & 0xFFU);
        usb_tx_frame[10] = (uint8_t)(ns >> 8);
        usb_tx_frame[11] = 0U;                                   /* fmt 0 = int32 LE          */
        memcpy(&usb_tx_frame[RAW_HDR_BYTES], mic_raw, RAW_PAYLOAD_BYTES);
        if (CDC_Transmit_HS(usb_tx_frame, (uint16_t)USB_FRAME_LEN) == USBD_OK)
        {
          g_usb_seq++;
        }
      }
#endif

    }
    /* USER CODE END WHILE */

    /* USER CODE BEGIN 3 */
  }
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
  /* TASK-05 fix: export SAI1 block A sync (GCR.SYNCOUT) so SAI2 (SYNCHRONOUS_EXT_SAI1)
   * receives FS/SCK. Must be set on BOTH SAI1 blocks because HAL_SAI_Init rewrites the
   * shared SAI1->GCR on every call and the last (block B) init would otherwise clear it. */
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
  HAL_NVIC_SetPriority(DMA1_Stream0_IRQn, 0, 0);
  HAL_NVIC_EnableIRQ(DMA1_Stream0_IRQn);
  /* DMA1_Stream1_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Stream1_IRQn, 0, 0);
  HAL_NVIC_EnableIRQ(DMA1_Stream1_IRQn);
  /* DMA1_Stream2_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Stream2_IRQn, 0, 0);
  HAL_NVIC_EnableIRQ(DMA1_Stream2_IRQn);
  /* DMA1_Stream3_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA1_Stream3_IRQn, 0, 0);
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
void HAL_SAI_RxHalfCpltCallback(SAI_HandleTypeDef *hsai)
{
  uint8_t p = Audio_GetPair(hsai);
  if (p == 0xFFU) { return; }
  dma_half_cnt[p]++;
  if (p == 0U)                       /* master block */
  {
    if (g_half_ready) { g_overruns++; }
    g_ready_half = 0U;               /* PING */
    g_half_ready = 1U;
  }
}

/* DMA transfer-complete: second half (PONG) of the circular buffer is full. */
void HAL_SAI_RxCpltCallback(SAI_HandleTypeDef *hsai)
{
  uint8_t p = Audio_GetPair(hsai);
  if (p == 0xFFU) { return; }
  dma_full_cnt[p]++;
  if (p == 0U)                       /* master block */
  {
    if (g_half_ready) { g_overruns++; }
    g_ready_half = 1U;               /* PONG */
    g_half_ready = 1U;
  }
}

/* Deinterleave one stereo pair's half-buffer into the two per-mic arrays.
 * SAI 24-bit data is MSB-left-justified in a 32-bit slot, so the signed 24-bit
 * sample is (word >> 8); /2^23 normalizes to [-1,1]. */
static void Deinterleave_Pair(uint32_t off, uint8_t pair)
{
  const int32_t *src = &dma_buf[pair][off];
  uint8_t l = (uint8_t)(pair * 2U);
  uint8_t r = (uint8_t)(pair * 2U + 1U);
  for (uint32_t i = 0U; i < AUDIO_BLOCK_SAMPLES; i++)
  {
    int32_t rl = src[2U * i]      >> 8;
    int32_t rr = src[2U * i + 1U] >> 8;
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

/* USER CODE END 4 */

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

  /* USER CODE BEGIN MPU_Regions */
  /* TASK-02: Region 1 — AXI SRAM (RAM_D1, 0x24000000, 1 MB).
   * Marked Normal/non-cacheable (TEX=001, C=0, B=1) so SAI/DMA writes to
   * dma_buf are immediately coherent with CPU reads, with no need for
   * SCB_InvalidateDCache_by_Addr. Region 1 > Region 0 priority, so it
   * overrides the 4 GB backstop for this range. Covers the full 1024 KB
   * declared in STM32H7A3ZITXQ_FLASH.ld (dma_buf sits at 0x24002220). */
  MPU_InitStruct.Enable           = MPU_REGION_ENABLE;
  MPU_InitStruct.Number           = MPU_REGION_NUMBER1;
  MPU_InitStruct.BaseAddress      = 0x24000000;
  MPU_InitStruct.Size             = MPU_REGION_SIZE_1MB;
  MPU_InitStruct.SubRegionDisable = 0x00;
  MPU_InitStruct.TypeExtField     = MPU_TEX_LEVEL1;
  MPU_InitStruct.AccessPermission = MPU_REGION_FULL_ACCESS;
  MPU_InitStruct.DisableExec      = MPU_INSTRUCTION_ACCESS_DISABLE;
  MPU_InitStruct.IsShareable      = MPU_ACCESS_NOT_SHAREABLE;
  MPU_InitStruct.IsCacheable      = MPU_ACCESS_NOT_CACHEABLE;
  MPU_InitStruct.IsBufferable     = MPU_ACCESS_BUFFERABLE;
  HAL_MPU_ConfigRegion(&MPU_InitStruct);
  /* USER CODE END MPU_Regions */

  /* Enables the MPU */
  HAL_MPU_Enable(MPU_PRIVILEGED_DEFAULT);

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
