# Lệnh Clone dự án (Windows)

```bash
git clone -b simplify/doa-code https://github.com/huygithcm/code_TN.git
cd code_TN
```

# Import project vào STM32CubeIDE đúng cách

Project dùng **linked resources** (`Src/`, `Inc/` nằm ở thư mục gốc, ngoài
`STM32CubeIDE/`). Phải import đúng, nếu sai sẽ gãy link và mất file `Src/`.

1. `File ▸ Open Projects from File System...`
2. Ô **Import source**, bấm `Directory...` → chọn thư mục con `code_TN/STM32CubeIDE`
   (trỏ vào `STM32CubeIDE/`, **không** phải thư mục gốc `code_TN`).
3. CubeIDE nhận diện project `code_ver2_Fs16khz` → bấm **Finish**.
4. Các file `Src/*.c`, `Inc/`, `Drivers/` tự xuất hiện dưới nhóm `Application/User`
   và `Drivers` nhờ link `PARENT-1-PROJECT_LOC`.

**Lưu ý:**
- **Không** di chuyển `STM32CubeIDE/` ra khỏi `code_TN` (link dùng đường dẫn tương
  đối lùi 1 cấp `PARENT-1` → tách ra sẽ mất file `Src/`).
- **Không** dùng `Import ▸ Existing Projects` rồi tick *"Copy projects into
  workspace"* → đứt link tới `Src/`. Giữ project **tại chỗ** trong repo.
- Nếu import sai và báo thiếu file: xóa project khỏi workspace (bỏ tick *Delete on
  disk*) rồi import lại theo bước 2.

# Build & nạp firmware

1. Bấm 🔨 (**Build**) để biên dịch.
2. Bấm ▶ (**Run**) hoặc 🐞 (**Debug**) để nạp firmware xuống board qua ST-LINK.

# Cấu trúc thư mục chính

| Thư mục / file | Nội dung |
|----------------|----------|
| `Src/main.c` | Code chính: khởi tạo, audio, FFT, GCC-PHAT, DOA, servo |
| `Src/freertos.c` | Cấu hình FreeRTOS |
| `Src/usbd_cdc_if.c` | USB CDC: stream audio + nhận lệnh `SET` |
| `Inc/` | Header (`main.h`, cấu hình HAL/USB...) |
| `STM32CubeIDE/` | Project CubeIDE + linker script (`*_FLASH.ld`) |
| `Drivers/`, `Middlewares/` | Thư viện HAL, CMSIS, USB, FreeRTOS |
| `tools/` | Công cụ Python (vẽ DOA, ghi âm, chỉnh ngưỡng) |
| `scripts/` | Script PowerShell chẩn đoán phần cứng |
| `matlab/` | Sinh bảng trễ, thiết kế bộ lọc, mô phỏng DOA |
| `docs/` | Tài liệu, lưu đồ giải thuật, lý thuyết |
| `Makefile`, `build.ps1` | Build bằng CLI (không cần CubeIDE) |
| `code_ver2_Fs16khz.ioc` | File cấu hình STM32CubeMX |

# Các hàm chính (`Src/main.c`)

| Hàm | Chức năng |
|-----|-----------|
| `main()` | Khởi tạo MPU, clock, GPIO, DMA, SAI, USB rồi chạy RTOS |
| `SystemClock_Config()` / `PeriphCommonClock_Config()` | Cấu hình PLL1 (64 MHz) và PLL3 (SAI 16 kHz) |
| `MX_SAI1_Init()` / `MX_SAI2_Init()` | Cấu hình 4 block SAI thu 8 kênh mic |
| `MX_DMA_Init()` | DMA vòng đưa dữ liệu SAI vào bộ nhớ |
| `HAL_SAI_RxHalfCpltCallback()` / `RxCpltCallback()` | Báo nửa buffer audio sẵn sàng |
| `Deinterleave_Pair()` | Tách kênh + remap mic về đúng thứ tự Mic1…Mic8 |
| `FFT_ProcessAll()` | FFT cho từng kênh (CMSIS-DSP) |
| `GCC_PHAT()` / `GCC_ProcessPairs()` | Tính trễ giữa các cặp mic đối tâm |
| `DOA_Compute()` | Ước lượng góc tới (azimuth) từ bảng trễ |
| `Servo_PointToAzimuth()` | Quay servo/camera về hướng nguồn âm |
| `StartDefaultTask()` … `StartTask05()` | Các task FreeRTOS chạy pipeline |
