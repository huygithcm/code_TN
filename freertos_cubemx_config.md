# FreeRTOS Configuration Guide (TASK-09) — STM32H7A3ZI

Step-by-step guide to add FreeRTOS to this project **by hand via STM32CubeMX** (the `.ioc` shipped
without an RTOS), wire the existing capture + FFT + GCC-PHAT pipeline into tasks, and verify it.

This is the detailed companion to the TASK-09 section in `tasks_done_summary.md`. Read the two
"MANDATORY" steps (timebase + NVIC priorities) first — they are this project's main crash traps.

---

## 0. Context

| Item | Current (superloop) | After TASK-09 (FreeRTOS) |
|------|---------------------|--------------------------|
| Scheduler | bare-metal `while(1)` in `main()` | FreeRTOS, `osKernelStart()` |
| HAL timebase | SysTick | TIM6 (SysTick handed to FreeRTOS) |
| Block trigger | `g_half_ready` flag polled in loop | `xTaskNotifyFromISR` from SAI callback |
| Pipeline | deinterleave + FFT + GCC inline | FFT_Task / USB_Task / DOA_Task / Monitor_Task |
| TDOA hand-off | none | `result_queue` (FFT_Task -> DOA_Task) |

Pre-flight checklist:

- [ ] Working tree committed (TASK-01..08 are on `develop`).
- [ ] Know that CubeMX regenerates `STM32CubeIDE/Debug/` — the CMSIS-DSP build wiring (TASK-07) is lost
      on regen and must be re-applied (section 5).

---

## 1. Enable FreeRTOS

1. Open `code_ver2_Fs16khz.ioc` in STM32CubeMX (or CubeIDE's `.ioc` editor).
2. **Middleware and Software Packs → FREERTOS**.
3. **Interface = CMSIS_V2** (recommended — the v2 wrapper plays well with current HAL and gives
   `osThreadNew`, `osMessageQueueNew`, etc. You can still call native `xTaskCreate`/`xTaskNotify` in
   USER CODE).
4. Memory management: **heap_4** (default; coalescing first-fit, good general choice).

---

## 2. MANDATORY — move the HAL timebase off SysTick

FreeRTOS owns SysTick (it provides `SysTick_Handler` for the tick). HAL also defaults to SysTick for
`HAL_GetTick()`/`HAL_Delay()`. Leaving both on SysTick makes HAL timeouts unreliable and can hang.

- **System Core → SYS → Timebase Source → `TIM6`** (TIM7 is equally fine; both are basic timers unused
  here).
- CubeMX then: generates `HAL_InitTick()` on TIM6, calls `HAL_IncTick()` from `TIM6_DAC_IRQHandler`,
  removes the SysTick `HAL_IncTick` path, and maps `vPortSVCHandler`/`xPortPendSVHandler`/
  `xPortSysTickHandler` to the real handlers in `FreeRTOSConfig.h`.

Verify after generate: `stm32h7xx_it.c` no longer increments HAL tick in `SysTick_Handler`, and
`TIM6_DAC_IRQHandler` calls `HAL_IncTick()`.

---

## 3. MANDATORY — fix NVIC interrupt priorities

FreeRTOS port rule: **any ISR that calls a `...FromISR()` API must have a preempt priority numerically
>= `configMAX_SYSCALL_INTERRUPT_PRIORITY`** (default 5). Lower numbers = higher priority = *above* the
RTOS-safe ceiling = illegal for FromISR calls (trips `configASSERT`, or silently corrupts the scheduler
if asserts are off).

This project currently runs the audio IRQs at **preempt priority 0** (see `CLAUDE.md`). The SAI
callback will call `xTaskNotifyFromISR`, so those IRQs **must be lowered**.

**System Core → NVIC → NVIC** (keep Priority Group = 4 bits, group `NVIC_PRIORITYGROUP_4`):

| Interrupt | Preempt priority — now | Preempt priority — set to | Reason |
|-----------|------------------------|---------------------------|--------|
| DMA1_Stream0..3 | 0 | **5** | fires the SAI HT/TC callbacks that notify FFT_Task |
| SAI1 global | 0 | **5** | error/overrun callbacks (TASK-12) may notify |
| SAI2 global | (not enabled) | **5** | enable + set when TASK-12 turns it on |
| EXTI15_10 (button) | 0 | **5** | button handler may signal a task |
| OTG_HS | 0 | **6** | USB stack; keep below the FromISR ceiling too |

> Anything ≥ 5 is fine; 5/6 leave headroom. Do **not** leave any FromISR-calling IRQ at 0–4.

---

## 4. FreeRTOS config parameters + tasks/queue

**Config parameters tab:**

| Parameter | Value | Why |
|-----------|-------|-----|
| `configCPU_CLOCK_HZ` | 64000000 | auto from clock tree (SYSCLK) |
| `configTICK_RATE_HZ` | 1000 | 1 ms tick |
| `configTOTAL_HEAP_SIZE` | 32768 | 4 task stacks + TCBs + queue; lands in AXI SRAM |
| `configMAX_SYSCALL_INTERRUPT_PRIORITY` | (default, 5) | matches section 3 |
| `configUSE_TRACE_FACILITY` | Enabled | required by `vTaskList` |
| `configUSE_STATS_FORMATTING_FUNCTIONS` | Enabled | required by `vTaskList` |
| `INCLUDE_uxTaskGetStackHighWaterMark` | Enabled | Monitor_Task stack reporting (TASK-12) |
| `configCHECK_FOR_STACK_OVERFLOW` | 2 | catch stack overflow during bring-up |
| `configUSE_MALLOC_FAILED_HOOK` | Enabled | catch heap exhaustion |

**Tasks and Queues tab** (matches `stm32h7a3_task_breakdown.md`):

| Task entry | CMSIS_V2 priority | Stack (words) | Role |
|------------|-------------------|---------------|------|
| FFT_Task | osPriorityHigh | 2048 | deinterleave + FFT + GCC-PHAT, send TDOA |
| USB_Task | osPriorityRealtime | 512 | build + `CDC_Transmit_HS` |
| DOA_Task | osPriorityAboveNormal | 512 | TDOA → angle (TASK-11) |
| Monitor_Task | osPriorityLow | 256 | watchdog, overruns, stack marks (TASK-12) |

- Queue: `result_queue`, length **4**, item size = `sizeof(tdoa_result)`.
- The big DSP buffers (`mic_data`, `mic_raw`, `fft_*`, `gcc_*`) stay as DTCM globals — they are **not**
  on task stacks, so 2048 words for FFT_Task is plenty.

> **Tip:** to stay close to the breakdown's native task-notification design, you may create only
> `defaultTask` in CubeMX and `xTaskCreate()` the four tasks yourself in `USER CODE`, using notify bits
> `#define FLAG_FFT (1UL<<0)` / `#define FLAG_USB (1UL<<1)`.

Then **Generate Code**.

---

## 5. After regenerate — re-apply the CMSIS-DSP build wiring

CubeMX rewrote `STM32CubeIDE/Debug/`, dropping the TASK-07 FFT integration. Re-apply (see the TASK-07
section of `tasks_done_summary.md` and memory `cmsis-dsp-build-integration`):

1. Recreate `STM32CubeIDE/Debug/Drivers/CMSIS/DSP/subdir.mk` (compiles the five aggregate units at -O2).
2. Add `-include Drivers/CMSIS/DSP/subdir.mk` to `STM32CubeIDE/Debug/makefile`.
3. Add the five DSP `.o` paths to `STM32CubeIDE/Debug/objects.list`.

> **Better long-term:** add CMSIS-DSP via CubeMX (Software Packs → CMSIS → select DSP) or in the
> `.cproject`, so it is tracked and survives regen. The hand-edited `Debug/` files are gitignored.

Memory budget after regen: FreeRTOS heap (~32 KB) is in AXI SRAM; the DTCM working set (~108 KB) still
fits the 128 KB DTCM.

---

## 6. Move the pipeline into tasks (USER CODE)

Skeletons — adapt names to whatever CubeMX generated. The deinterleave moves **out of the ISR** into
FFT_Task to keep the ISR short.

**Notify from the SAI master-block callback** (replaces the `g_half_ready` flag):

```c
/* in HAL_SAI_RxHalfCpltCallback / RxCpltCallback, for the master block (pair 0) */
BaseType_t woken = pdFALSE;
g_ready_half = (half == 0) ? 0U : 1U;          /* which half is full */
xTaskNotifyFromISR(fft_task_handle, FLAG_FFT | FLAG_USB, eSetBits, &woken);
portYIELD_FROM_ISR(woken);
```

**FFT_Task:**

```c
void FFT_Task(void *arg)
{
    FFT_Init();
    FFT_SelfTest();         /* keep TASK-07 verifiable */
    GCC_SelfTest();         /* keep TASK-08 verifiable */

    for (;;) {
        uint32_t flags;
        xTaskNotifyWait(0, FLAG_FFT, &flags, portMAX_DELAY);

        uint32_t off = (g_ready_half != 0U) ? DMA_HALF_WORDS : 0U;
        for (uint8_t p = 0; p < NUM_SAI_BLOCKS; p++) Deinterleave_Pair(off, p);

        FFT_ProcessAll();
        GCC_ProcessPairs();                       /* fills g_tdoa_lag[] */
        xQueueSend(result_queue, (void *)g_tdoa_lag, 0);
        xTaskNotify(usb_task_handle, FLAG_USB, eSetBits);   /* hand off frame build */
    }
}
```

**USB_Task:** move the existing RAW1 frame build + `CDC_Transmit_HS` here, gated on `FLAG_USB`.

**DOA_Task / Monitor_Task:** stubs for now (TASK-11 / TASK-12).

**main():** keep init order; call `Audio_Start()` **before** `osKernelStart()`; delete the old
`while(1)` loop body (the scheduler runs instead).

> Concurrency note: `mic_data`/`fft_mag`/`g_tdoa_lag` are produced in FFT_Task and read elsewhere — pass
> a snapshot through `result_queue` (copy by value) rather than sharing the live globals, or guard with
> a mutex. The queue item is the simplest safe hand-off.

---

## 7. Verify ("Done when")

Print the task list from Monitor_Task (or temporarily from defaultTask) over the VCP:

```c
char list[400];
vTaskList(list);
printf("\r\nTask          State Prio Stack Num\r\n%s\r\n", list);
```

Expected: all four tasks present, each in **R**eady or **B**locked state, with non-trivial free stack.
A check script analogous to `scripts/check_task07_fft.ps1` can flash + read and assert the four task
names appear.

---

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| HardFault / `configASSERT` on first SAI callback | DMA/SAI IRQ priority < 5 calling FromISR | section 3 — set preempt priority ≥ 5 |
| `HAL_Delay` hangs, no tick | HAL still on SysTick | section 2 — timebase → TIM6 |
| Hangs in `vPortStartFirstTask` / nothing runs | `osKernelStart()` not reached, or stacks too big for heap | check `configTOTAL_HEAP_SIZE`; malloc-failed hook |
| `vTaskList` prints nothing | trace facility off | enable `USE_TRACE_FACILITY` + `USE_STATS_FORMATTING_FUNCTIONS` |
| Link error: `arm_rfft_fast_f32` undefined | CMSIS-DSP wiring lost on regen | section 5 — re-apply DSP subdir.mk/objects.list |
| `overruns` climbing | FFT+GCC per block too slow for 64 ms | compute fewer pairs / cache mic0 spectrum / raise FFT_Task priority |
| USB frames stop | `CDC_Transmit_HS` called while busy | keep the `TxState==0` guard; drop frame if busy |
