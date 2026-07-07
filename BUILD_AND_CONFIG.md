# Build & Cấu hình — STM32H7A3ZI DOA

Tóm tắt cách build, nạp firmware và cấu hình hệ định hướng âm thanh (DOA) cho
NUCLEO-H7A3ZI-Q. Xem thêm [CLAUDE.md](CLAUDE.md) cho cấu hình peripheral chi tiết.

---

## 1. Build firmware

Có 2 cách, dùng **chung source** (`Src/ Inc/ Drivers/ Middlewares/`) và **chung
linker script** `STM32CubeIDE/STM32H7A3ZITXQ_FLASH.ld` — sửa code một chỗ, cả hai
cách đều thấy.

### A. Bằng script (CLI / AI agent) — khuyến nghị
Không cần cài ARM GCC riêng; `build.ps1` tự dò toolchain bundled trong STM32CubeIDE.

```powershell
.\build.ps1              # build Debug -> build/code_ver2_Fs16khz.elf/.hex/.bin/.map
.\build.ps1 -Release     # build Release (-Os)
.\build.ps1 rebuild      # clean + build
.\build.ps1 clean
.\build.ps1 flash        # nạp .hex qua ST-LINK (tự build nếu chưa có)
```

- [Makefile](Makefile): build standalone bằng `arm-none-eabi-gcc` (cờ CPU `cortex-m7
  / fpv5-d16 / hard`, defines `STM32H7A3xxQ USE_HAL_DRIVER USE_PWR_DIRECT_SMPS_SUPPLY`).
- [build.ps1](build.ps1): wrapper dò gcc/make/STM32_Programmer_CLI trong `C:\ST\STM32CubeIDE_*`.
- Output ở `build/` (đã .gitignore).

### B. Bằng STM32CubeIDE (thủ công, có debug GUI)
1. `File ▸ Open Projects from File System` → trỏ vào thư mục `STM32CubeIDE/`.
2. Bấm 🔨 Build, hoặc ▶/🐞 để nạp + debug qua ST-LINK.

---

## 2. Hai cổng COM (quan trọng)

Board hiện 2 cổng USB khác nhau:

| Cổng | VID:PID | Vai trò |
|------|---------|---------|
| **ST-Link VCP** | `0483:374E` | `printf` / log DOA (`az=...`). Mặc định ~**COM5** |
| **USB CDC** | `0483:5740` | Stream audio thô 8 kênh **+ nhận lệnh `SET`**. Mặc định ~**COM7** |

Các tool Python tự dò cổng theo VID:PID nên không cần nhớ số COM.

---

## 3. Cấu hình DOA (firmware — `Src/main.c`)

### Hình học mảng mic (UCA 8 mic, R = 40 mm)
Nhãn mic theo quy ước **chuẩn (như hình thiết kế)**:

```
Mic1=0°  Mic2=180° | Mic3=45° Mic4=225° | Mic5=90° Mic6=270° | Mic7=135° Mic8=315°
```
Phần cứng nối nhầm nên kênh thu DMA không đúng thứ tự nhãn; firmware sửa **một chỗ**
bằng `MIC_REMAP = {0,1,3,2,5,4,7,6}` lúc deinterleave (xem `Src/main.c`). Nhờ vậy
`mic_data[]` về đúng thứ tự Mic1…Mic8, cặp đối tâm sạch, baseline φ = [0,45,90,135]°.
Bảng trễ `g_doa_table` sinh từ `lag = (Fs/C)·2R·cos(az − φ_k)`, φ = [0,45,90,135]°.
Quy ước góc: 0° = +x (mic số 1), CCW dương.

### Ngưỡng clap-gate (biến runtime, chỉnh được lúc chạy)
| Biến | Mặc định | Ý nghĩa |
|------|----------|---------|
| `g_clap_ratio` | **1.8** | clap khi mức > ratio × nền nhiễu |
| `g_clap_abs` | **0.0005** | ngưỡng tuyệt đối (mức `level` thực ~0.001–0.005) |
| `g_doa_resid_max` | **0.7** | loại khung khớp tệ hơn ngưỡng |

> Lưu ý lịch sử: `g_clap_abs` cũ = 0.15 **sai thang ~30×** nên chặn sạch mọi clap.
> Đã sửa về 0.0005. Reset/cấp nguồn lại board → các biến về mặc định trên.

### Xuất log DOA (mỗi giây, kể cả chưa clap)
- Có clap: `DOA seq=.. az=248 (cam target, N clap frames)`
- Chưa clap: `DOA seq=.. az=270 live resid=.. peakRatio=.. need=.. maxLev_u=..`
  (góc tương đối của khung khớp tốt nhất + số liệu chẩn đoán gate)

### Đổi mặc định cố định
Sửa giá trị khởi tạo `g_clap_ratio/g_clap_abs/g_doa_resid_max` trong `Src/main.c`
rồi `.\build.ps1 rebuild; .\build.ps1 flash`.

---

## 4. Chỉnh ngưỡng lúc chạy (không cần build lại)

Gửi lệnh `SET ratio|abs|resid <giá_trị>` tới board qua cổng **CDC**. Firmware xác
nhận bằng dòng `CFG ratio=.. abs=.. resid=.. (x1000)` trên cổng **VCP**.

```powershell
# CLI
python tools/set_doa_filter.py --ratio 1.5 --abs 0.0002
python tools/set_doa_filter.py --easy            # preset rất nhạy

# GUI (nút nhấn / thanh trượt)
python tools/doa_filter_gui.py
```

---

## 5. Công cụ Python (`tools/`)

| Tool | Cổng | Chức năng |
|------|------|-----------|
| [plot_doa.py](tools/plot_doa.py) | VCP | Vẽ hướng DOA realtime trên hình mảng mic. Mũi tên xanh=góc live, đỏ + chấm cam=clap xác nhận. Phím `c` xóa lịch sử chấm. |
| [record_channels.py](tools/record_channels.py) | CDC | Ghi sóng âm 8 kênh → WAV (8ch + mono từng kênh) + npy + waveform png + thống kê RMS/peak. |
| [set_doa_filter.py](tools/set_doa_filter.py) | CDC | Set ngưỡng clap-gate bằng CLI. |
| [doa_filter_gui.py](tools/doa_filter_gui.py) | CDC | Set ngưỡng bằng GUI (thanh trượt + preset). |

Cài phụ thuộc: `pip install pyserial matplotlib numpy` (tkinter có sẵn).

> Cùng lúc: `plot_doa.py` (VCP) chạy song song thoải mái với tool CDC. Nhưng
> **không** chạy 2 tool CDC cùng lúc (record + set/gui) vì tranh cổng COM7.

### Script chẩn đoán phần cứng (`scripts/`, PowerShell)
- `mic_tap_test.ps1` — gõ từng mic xem kênh nào sáng (đọc CDC).
- `diag_mic_channels.ps1`, `check_usb_cdc_stream.ps1` — chẩn đoán kênh/luồng.

---

## 6. Quy trình điển hình

```powershell
.\build.ps1 rebuild ; .\build.ps1 flash      # build + nạp
python tools/plot_doa.py                       # mở cửa sổ hướng DOA
python tools/doa_filter_gui.py                 # (tuỳ chọn) chỉnh ngưỡng bằng nút
# -> vỗ tay: mũi tên đỏ + chấm cam hiện đúng hướng nguồn
```
