######################################
# Makefile cho STM32H7A3ZITxQ (NUCLEO-H7A3ZI-Q)
# Build bang arm-none-eabi-gcc (toolchain bundled cua STM32CubeIDE)
# Sinh tu cau hinh trong STM32CubeIDE/.cproject
#
# Dung:
#   make            -> build cau hinh DEBUG (mac dinh)
#   make DEBUG=0    -> build cau hinh RELEASE (-Os, khong -g)
#   make clean
#   make -jN        -> build song song
######################################

TARGET = code_ver2_Fs16khz

# Debug = 1 (mac dinh): -Og -g3 + define DEBUG. Debug = 0: -Os release.
DEBUG ?= 1

BUILD_DIR = build

######################################
# Toolchain
######################################
# GCC_PATH co the duoc set tu ngoai (build.ps1 se set). De trong -> lay tu PATH.
PREFIX = arm-none-eabi-
ifdef GCC_PATH
CC  = $(GCC_PATH)/$(PREFIX)gcc
AS  = $(GCC_PATH)/$(PREFIX)gcc -x assembler-with-cpp
CP  = $(GCC_PATH)/$(PREFIX)objcopy
SZ  = $(GCC_PATH)/$(PREFIX)size
else
CC  = $(PREFIX)gcc
AS  = $(PREFIX)gcc -x assembler-with-cpp
CP  = $(PREFIX)objcopy
SZ  = $(PREFIX)size
endif
HEX = $(CP) -O ihex
BIN = $(CP) -O binary -S

######################################
# CPU / FPU (khop voi .cproject: cortex-m7, fpv5-d16, hard float)
######################################
CPU       = -mcpu=cortex-m7
FPU       = -mfpu=fpv5-d16
FLOAT-ABI = -mfloat-abi=hard
MCU       = $(CPU) -mthumb $(FPU) $(FLOAT-ABI)

######################################
# Source files
######################################
# Code ung dung
C_SOURCES  = $(wildcard Src/*.c)
C_SOURCES += $(wildcard STM32CubeIDE/Application/User/*.c)

# HAL drivers (bo qua cac file *_template.c)
C_SOURCES += $(filter-out %_template.c,$(wildcard Drivers/STM32H7xx_HAL_Driver/Src/*.c))

# BSP Nucleo
C_SOURCES += Drivers/BSP/STM32H7xx_Nucleo/stm32h7xx_nucleo.c

# USB Device Library (Core + CDC, bo qua *_template.c)
C_SOURCES += Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_core.c
C_SOURCES += Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ctlreq.c
C_SOURCES += Middlewares/ST/STM32_USB_Device_Library/Core/Src/usbd_ioreq.c
C_SOURCES += Middlewares/ST/STM32_USB_Device_Library/Class/CDC/Src/usbd_cdc.c

# FreeRTOS (kernel + port ARM_CM4F + heap_4 + CMSIS-RTOS v2)
FREERTOS = Middlewares/Third_Party/FreeRTOS/Source
C_SOURCES += $(FREERTOS)/croutine.c
C_SOURCES += $(FREERTOS)/event_groups.c
C_SOURCES += $(FREERTOS)/list.c
C_SOURCES += $(FREERTOS)/queue.c
C_SOURCES += $(FREERTOS)/stream_buffer.c
C_SOURCES += $(FREERTOS)/tasks.c
C_SOURCES += $(FREERTOS)/timers.c
C_SOURCES += $(FREERTOS)/portable/GCC/ARM_CM4F/port.c
C_SOURCES += $(FREERTOS)/portable/MemMang/heap_4.c
C_SOURCES += $(FREERTOS)/CMSIS_RTOS_V2/cmsis_os2.c

# CMSIS-DSP: chi build cac file tong hop (*Functions.c include cac arm_*.c con lai)
# Project dung: rfft_fast_f32, cmplx_mag_f32, mult_f32, max_f32
DSP = Drivers/CMSIS/DSP/Source
C_SOURCES += $(DSP)/BasicMathFunctions/BasicMathFunctions.c
C_SOURCES += $(DSP)/ComplexMathFunctions/ComplexMathFunctions.c
C_SOURCES += $(DSP)/FastMathFunctions/FastMathFunctions.c
C_SOURCES += $(DSP)/StatisticsFunctions/StatisticsFunctions.c
C_SOURCES += $(DSP)/SupportFunctions/SupportFunctions.c
C_SOURCES += $(DSP)/TransformFunctions/TransformFunctions.c
C_SOURCES += $(DSP)/CommonTables/CommonTables.c

# Startup (assembly)
ASM_SOURCES = STM32CubeIDE/Application/Startup/startup_stm32h7a3zitxq.s

######################################
# Defines / Includes
######################################
C_DEFS = -DUSE_PWR_DIRECT_SMPS_SUPPLY -DUSE_HAL_DRIVER -DSTM32H7A3xxQ
AS_DEFS =

C_INCLUDES = \
-IInc \
-IDrivers/STM32H7xx_HAL_Driver/Inc \
-IDrivers/STM32H7xx_HAL_Driver/Inc/Legacy \
-IMiddlewares/ST/STM32_USB_Device_Library/Core/Inc \
-IMiddlewares/ST/STM32_USB_Device_Library/Class/CDC/Inc \
-IDrivers/BSP/STM32H7xx_Nucleo \
-IDrivers/CMSIS/Device/ST/STM32H7xx/Include \
-IDrivers/CMSIS/Include \
-IDrivers/CMSIS/DSP/Include \
-IDrivers/CMSIS/DSP/PrivateInclude \
-IMiddlewares/Third_Party/FreeRTOS/Source/include \
-IMiddlewares/Third_Party/FreeRTOS/Source/CMSIS_RTOS_V2 \
-IMiddlewares/Third_Party/FreeRTOS/Source/portable/GCC/ARM_CM4F \
-IDrivers/CMSIS/RTOS2/Include

######################################
# Compiler flags
######################################
ifeq ($(DEBUG), 1)
OPT  = -Og
CDBG = -g3 -gdwarf-2 -DDEBUG
else
OPT  = -Os
CDBG =
endif

# Warning/standard flags theo phong cach STM32CubeIDE
COMMON  = $(MCU) -ffunction-sections -fdata-sections -Wall
ASFLAGS = $(COMMON) $(AS_DEFS) $(C_INCLUDES) $(OPT) $(CDBG)
CFLAGS  = $(COMMON) $(C_DEFS) $(C_INCLUDES) $(OPT) $(CDBG) -std=gnu11
# Sinh file .d de theo doi phu thuoc header
CFLAGS += -MMD -MP -MF"$(@:%.o=%.d)"

######################################
# Linker
######################################
LDSCRIPT = STM32CubeIDE/STM32H7A3ZITXQ_FLASH.ld
LIBS     = -lc -lm -lnosys
LIBDIR   =
LDFLAGS  = $(MCU) -specs=nano.specs -T$(LDSCRIPT) $(LIBDIR) $(LIBS) \
           -Wl,-Map=$(BUILD_DIR)/$(TARGET).map,--cref -Wl,--gc-sections

######################################
# Objects
######################################
OBJECTS  = $(addprefix $(BUILD_DIR)/,$(notdir $(C_SOURCES:.c=.o)))
vpath %.c $(sort $(dir $(C_SOURCES)))
OBJECTS += $(addprefix $(BUILD_DIR)/,$(notdir $(ASM_SOURCES:.s=.o)))
vpath %.s $(sort $(dir $(ASM_SOURCES)))

######################################
# Targets
######################################
all: $(BUILD_DIR)/$(TARGET).elf $(BUILD_DIR)/$(TARGET).hex $(BUILD_DIR)/$(TARGET).bin

$(BUILD_DIR)/%.o: %.c Makefile | $(BUILD_DIR)
	$(CC) -c $(CFLAGS) -Wa,-a,-ad,-alms=$(BUILD_DIR)/$(notdir $(<:.c=.lst)) $< -o $@

$(BUILD_DIR)/%.o: %.s Makefile | $(BUILD_DIR)
	$(AS) -c $(ASFLAGS) $< -o $@

$(BUILD_DIR)/$(TARGET).elf: $(OBJECTS) Makefile
	$(CC) $(OBJECTS) $(LDFLAGS) -o $@
	$(SZ) $@

$(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.elf | $(BUILD_DIR)
	$(HEX) $< $@

$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf | $(BUILD_DIR)
	$(BIN) $< $@

$(BUILD_DIR):
	mkdir $(BUILD_DIR)

clean:
	-rm -fR $(BUILD_DIR)

# Tu dong include file phu thuoc (.d)
-include $(wildcard $(BUILD_DIR)/*.d)

.PHONY: all clean
