# STM32H7A3ZI — Project Configuration Summary

Generated from `code_ver2_Fs16khz.ioc` + `Src/main.c` using STM32CubeMX 6.17.0.

---

## Target Hardware

| Item | Value |
|------|-------|
| MCU | STM32H7A3ZITxQ |
| Package | LQFP144 |
| Board | NUCLEO-H7A3ZI-Q |
| Firmware pack | STM32Cube FW_H7 V1.13.0 |
| Toolchain | STM32CubeIDE / GCC |

---

## Clock Tree

### System Clock (PLL1)

| Parameter | Value |
|-----------|-------|
| Clock source | HSE — 8 MHz (bypass / external clock via PH0) |
| HSI48 | Enabled (USB) |
| PLL1 M / N / P | 1 / 16 / 2 |
| VCO1 input | 8 MHz |
| VCO1 output | 128 MHz |
| SYSCLK | **64 MHz** |
| AHB / APB1–4 | 64 MHz (all divider = 1) |
| Voltage scale | Scale 3 |
| Power supply | Direct SMPS |

### SAI Audio Clock (PLL3)

| Parameter | Value |
|-----------|-------|
| PLL3 M / N / P / R | 5 / 123 / 4 / 4 |
| VCO3 input | 1.6 MHz |
| VCO3 output | 196.8 MHz |
| SAI clock (PLL3-P) | **49.2 MHz** |
| Target sample rate | 16 kHz (actual 16.015 kHz, error 0.09 %) |
| USB clock | HSI48 → 48 MHz |

---

## SAI Peripherals — Audio Input

All four blocks receive audio (RX). SAI1 Block A is the sole master; all others are slaves.

| Block | Mode | Sync | Pins |
|-------|------|------|------|
| SAI1 Block A | **Master RX** | Async (clock source) | PE4 (FS), PE5 (SCK), PE6 (SD) |
| SAI1 Block B | Slave RX | Sync to SAI1-A | PE3 (SD) |
| SAI2 Block A | Slave RX | Sync extern SAI1 | PD11 (SD) |
| SAI2 Block B | Slave RX | Sync extern SAI1 | PA0 (SD) |

### Common SAI Frame Parameters (all blocks)

| Parameter | Value |
|-----------|-------|
| Protocol | Free (I2S-like) |
| Data size | 24-bit |
| Bit order | MSB first |
| Clock strobing | Falling edge |
| Frame length | 64 bits |
| Active frame length | 32 bits |
| FS definition | Channel identification |
| FS polarity | Active low |
| FS offset | Before first bit |
| Slot size | 32-bit |
| Slot count | 2 (slots 0 & 1 active) |
| Mode | Stereo |
| Companding | None |
| PDM | Disabled |
| MCK output | Disabled |

**Effective capture**: 4 SAI blocks × 2 slots = **8 mono channels** (4 stereo pairs) at 16 kHz / 24-bit.

---

## DMA Configuration

Each SAI block has a dedicated DMA stream (all on DMA1).

| Stream | SAI source | Direction | Mode | Data width | Priority |
|--------|-----------|-----------|------|------------|----------|
| DMA1_Stream0 | SAI1_A | Periph → Memory | Circular | Word (32-bit) | Low |
| DMA1_Stream1 | SAI1_B | Periph → Memory | Circular | Word (32-bit) | Low |
| DMA1_Stream2 | SAI2_A | Periph → Memory | Circular | Word (32-bit) | Low |
| DMA1_Stream3 | SAI2_B | Periph → Memory | Circular | Word (32-bit) | Low |

Memory address auto-increment enabled; peripheral address fixed. FIFO disabled.

### DMA / NVIC Priorities

| IRQ | Preempt priority | Sub-priority |
|-----|-----------------|--------------|
| DMA1_Stream0–3 | 0 | 0 |
| SAI1 | 0 | 0 |
| EXTI15_10 (user button) | 0 | 0 |
| OTG_HS | 0 | 0 |
| NVIC group | NVIC_PRIORITYGROUP_4 | — |

---

## USB

| Parameter | Value |
|-----------|-------|
| Peripheral | USB_OTG_HS (HS core, FS PHY) |
| Mode | Device Only FS |
| Class | CDC (Virtual COM Port) |
| Pins | PA11 (DM), PA12 (DP) |
| Clock source | HSI48 (48 MHz) |

---

## GPIO Port Assignments

| Pin | Signal | Note |
|-----|--------|------|
| PH0 | RCC_OSC_IN | HSE external clock input |
| PH1 | RCC_OSC_OUT | HSE out |
| PC14 | RCC_OSC32_IN | 32 kHz in |
| PC15 | RCC_OSC32_OUT | 32 kHz out |
| PE4 | SAI1_FS_A | Frame sync (master) |
| PE5 | SAI1_SCK_A | Bit clock (master) |
| PE6 | SAI1_SD_A | Data A master |
| PE3 | SAI1_SD_B | Data B slave |
| PA0 | SAI2_SD_B | Data B SAI2 slave |
| PD11 | SAI2_SD_A | Data A SAI2 slave |
| PA11 | USB_OTG_HS_DM | USB D− |
| PA12 | USB_OTG_HS_DP | USB D+ |
| PD8 | USART3_TX | VCP TX (Nucleo ST-Link) |
| PD9 | USART3_RX | VCP RX (Nucleo ST-Link) |
| PB0 | LED_GREEN | BSP LED1 |
| PB14 | LED_RED | BSP LED3 |
| PC13 | LED_YELLOW | BSP LED2 / button |

---

## BSP (Board Support Package)

```c
BSP_LED_Init(LED_GREEN);
BSP_LED_Init(LED_YELLOW);
BSP_LED_Init(LED_RED);
BSP_PB_Init(BUTTON_USER, BUTTON_MODE_EXTI);  // PC13, triggers EXTI15_10

// COM1 = USART3 via ST-Link VCP
BspCOMInit.BaudRate   = 115200;
BspCOMInit.WordLength = COM_WORDLENGTH_8B;
BspCOMInit.StopBits   = COM_STOPBITS_1;
BspCOMInit.Parity     = COM_PARITY_NONE;
```

---

## MPU Configuration

One region covers the entire 4 GB address space as a backstop (no access, non-cacheable, non-bufferable). Sub-regions `0x87` disable the lower 256 MB so normal Flash/RAM regions remain accessible with default attributes. Privileged default mode is enabled after MPU setup.

| Field | Value |
|-------|-------|
| Region | 0 |
| Base | 0x00000000 |
| Size | 4 GB |
| Sub-region disable | 0x87 |
| Access | No access |
| Execute never | Yes |
| Cacheable | No |
| Bufferable | No |
| Post-enable mode | `MPU_PRIVILEGED_DEFAULT` |

---

## Initialization Order (`main`)

1. `MPU_Config()` — set up memory protection
2. `HAL_Init()` — reset peripherals, init SysTick
3. `SystemClock_Config()` — PLL1 → 64 MHz SYSCLK
4. `PeriphCommonClock_Config()` — PLL3 → 49.2 MHz for SAI1/2
5. `MX_GPIO_Init()` — enable GPIO clocks (E, C, H, A, D)
6. `MX_DMA_Init()` — enable DMA1, configure Stream 0–3 IRQs
7. `MX_SAI1_Init()` — configure SAI1 A (master) + B (slave)
8. `MX_SAI2_Init()` — configure SAI2 A + B (both extern-sync slaves)
9. `MX_USB_DEVICE_Init()` — start CDC HS device
10. BSP LED, button, COM1 init
