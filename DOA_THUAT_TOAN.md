# Thuật toán định hướng nguồn âm (DOA) — Phát hiện vỗ tay, xoay camera

Tài liệu mô tả thuật toán **Sound Source Localization (SSL)** trong firmware
STM32H7A3: phát hiện **tiếng vỗ tay** trong môi trường ồn, xác định **hướng** của
nó bằng TDOA giữa các cặp mic đối diện + so khớp bảng trễ, và **mỗi 1 giây** xuất
ra hướng nguồn mạnh nhất để **xoay camera** về phía đó.

> Nhánh này phát triển bản firmware cho góc cố định 22.5° (16 hướng).
> Code MATLAB cũ đã loại khỏi nhánh; còn các script phân tích/sinh bảng/kiểm thử.

---

## 1. Tổng quan & luồng xử lý

```
mic_data (8 kênh) ──► [Cổng clap]  ──► [TDOA + khớp bảng]  ──► [Bầu chọn 1 giây]
                       highpass 500Hz   GCC-PHAT 4 cặp         hướng được bầu
                       onset detection   → 1 trong 16 hướng     nhiều nhất
                       (chỉ frame clap)                         = góc xoay cam
```

Mỗi frame (1024 mẫu, ~64 ms):
1. **Cổng clap**: lọc ch0 highpass 500 Hz, tính mức năng lượng; chỉ frame có
   mức vượt hẳn nền nhiễu (xung vỗ tay) mới được xử lý tiếp.
2. **Định hướng**: đo 4 độ trễ giữa các cặp mic đối diện (GCC-PHAT), so khớp bảng
   trễ 16 hướng → 1 hướng rời rạc.
3. **Bầu chọn 1 giây**: gom phiếu theo hướng; hết mỗi giây chọn hướng được bầu
   nhiều nhất = hướng nguồn mạnh nhất → xuất góc xoay camera.

---

## 2. Hình học mảng micro

- Mảng tròn đều (UCA), **bán kính R = 40 mm** (đường kính 80 mm).
- 8 mic cách nhau 45°. Mỗi cặp stereo SAI nối **hai mic đối diện** qua tâm:

| Cặp | Kênh trái (góc) | Kênh phải (góc) | Baseline φ |
|-----|-----------------|-----------------|------------|
| 0 | ch0 (0°)   | ch1 (180°) | 0°   |
| 1 | ch2 (45°)  | ch3 (225°) | 45°  |
| 2 | ch4 (90°)  | ch5 (270°) | 90°  |
| 3 | ch6 (135°) | ch7 (315°) | 135° |

- Azimuth 0° = hướng +x (theo ch0), chiều dương ngược chiều kim đồng hồ (CCW).
- Mỗi cặp nối 2 mic đối diện → baseline = cả đường kính (khẩu độ lớn nhất).

---

## 3. Cổng lọc đầu vào — phát hiện vỗ tay

Trong phòng nhiều tạp âm, nhiễu nền lan khắp nơi và làm nhiễu DOA. Vỗ tay là
**xung đột ngột, băng rộng**. Cổng clap chỉ cho qua các frame vỗ tay:

**a) Highpass 500 Hz** (loại nhiễu tần thấp):
- Phân tích bản ghi thực: nhiễu nền tập trung <400 Hz, clap trải 500–2000 Hz.
- Lọc biquad bậc 2 Butterworth trên ch0 trước khi đo mức → tỉ số clap/nền tăng
  ~3.5× (95k → 333k), loại đúng các xung tần thấp không phải clap.
- Hệ số (Fs=16kHz, thiết kế bằng `matlab/design_clap_hpf.m`):
  ```
  b = [ 0.87033078, -1.74066156, 0.87033078 ]
  a = [ 1.00000000, -1.72377617, 0.75754694 ]
  ```

**b) Phát hiện onset** (mức vượt nền nhiễu):
```
level   = Σ (highpass(ch0))²              (trên 1 frame)
nền bg  = EMA của level trên các frame KHÔNG phải clap
là clap nếu:  level > CLAP_RATIO × bg   VÀ   level > CLAP_ABS_MIN
```
- `CLAP_RATIO` (mặc định 6): clap vượt nền bao nhiêu lần.
- `CLAP_ABS_MIN` (mặc định 0.5): ngưỡng tuyệt đối, chống kích hoạt khi im lặng.
  **Cần căn lại trên phần cứng** (thang mic_data 24-bit khác micro PC).
- Frame không phải clap chỉ cập nhật nền `bg`, không tham gia định hướng.

---

## 4. Công thức TDOA & bảng trễ

Sóng phẳng tới từ góc α, trễ giữa 2 mic cách nhau d: `t = d·cos(α)/c`,
đổi ra mẫu: `D = t·fs`. Trễ cực đại `D_max = (2R·fs)/c ≈ 3.73 mẫu`.

Baseline cặp k ở góc φ_k = k·45°. Trễ kỳ vọng cho nguồn ở azimuth `az`:

```
lag_k(az) = (fs/c) · 2R · cos(az − φ_k) = 3.731778 · cos(az − φ_k)   [mẫu]
```

Tính cho 16 hướng × 4 cặp → **bảng 16×4** hardcode trong code (`g_doa_table`):

| az (°) | cặp0 (0°) | cặp1 (45°) | cặp2 (90°) | cặp3 (135°) |
|-------:|----------:|-----------:|-----------:|------------:|
| 0.0   |  3.731778 |  2.638766 |  0.000000 | −2.638766 |
| 22.5  |  3.447714 |  3.447714 |  1.428090 | −1.428090 |
| 45.0  |  2.638766 |  3.731778 |  2.638766 |  0.000000 |
| 67.5  |  1.428090 |  3.447714 |  3.447714 |  1.428090 |
| 90.0  |  0.000000 |  2.638766 |  3.731778 |  2.638766 |
| 112.5 | −1.428090 |  1.428090 |  3.447714 |  3.447714 |
| 135.0 | −2.638766 |  0.000000 |  2.638766 |  3.731778 |
| 157.5 | −3.447714 | −1.428090 |  1.428090 |  3.447714 |
| 180.0 | −3.731778 | −2.638766 |  0.000000 |  2.638766 |
| 202.5 | −3.447714 | −3.447714 | −1.428090 |  1.428090 |
| 225.0 | −2.638766 | −3.731778 | −2.638766 |  0.000000 |
| 247.5 | −1.428090 | −3.447714 | −3.447714 | −1.428090 |
| 270.0 |  0.000000 | −2.638766 | −3.731778 | −2.638766 |
| 292.5 |  1.428090 | −1.428090 | −3.447714 | −3.447714 |
| 315.0 |  2.638766 |  0.000000 | −2.638766 | −3.731778 |
| 337.5 |  3.447714 |  1.428090 | −1.428090 | −3.447714 |

> Sinh lại bảng bằng `matlab/gen_delay_table.m` khi đổi fs, R, hoặc cách đấu cặp.

---

## 5. Ước lượng trễ thực tế: GCC-PHAT + nội suy

Với mỗi cặp đối diện, tương quan chéo làm trắng PHAT:

```
G(f) = X(f)·conj(Y(f)) / |X(f)·conj(Y(f))|
r(τ) = IFFT{ G(f) }          →     đỉnh của r(τ) là trễ
```

Vì trễ tối đa chỉ ±3.73 mẫu, dùng **nội suy parabol** quanh đỉnh để lấy trễ
dưới mẫu — cần thiết để phân biệt bước 22.5°.

> **Quy ước dấu** (đã kiểm chứng bằng `test_doa_algorithm.m`):
> firmware `GCC_PHAT(a,b)` trả **+D** khi b trễ hơn a, khớp đúng dấu bảng. MATLAB
> `ifft(X·conj(Y))` cho dấu ngược → khi mô phỏng phải đảo dấu lag.

---

## 6. So khớp bảng (table matching)

```
với mỗi hướng a (0..15):
    e(a) = Σ_k ( lag[k] − bảng[a][k] )²
hướng nguồn = argmin_a e(a)
```
Sai số chuẩn hoá: `resid = e_min / (4 · D_max²)`. Frame có `resid ≥ 0.5` bị loại.

---

## 7. Bầu chọn dominant trong 1 giây (xoay camera)

Mỗi cửa sổ **16 frame (~1 giây)**:
```
mỗi frame clap được nhận (resid < 0.5):
    idx = round(az / 22.5)
    vote[idx] += (1 − resid)        // frame khớp sạch tính điểm cao hơn
hết 1 giây:
    nếu có frame clap:  g_doa_az = hướng có vote lớn nhất  → góc xoay cam
    nếu không:          "no clap this second"
    reset vote
```
Vì nguồn vỗ tay to chi phối đỉnh GCC-PHAT mỗi frame, độ trễ liên tục khớp về cùng
một hướng → hướng đó được bầu nhiều nhất. **Định hướng dựa hoàn toàn vào độ trễ
thời gian**, không dùng năng lượng (năng lượng chỉ dùng cho cổng clap).

Output VCP (COM3, ~1 Hz):
```
DOA seq=... az=135 (cam target, 3 clap frames)
DOA seq=... no clap this second
```

---

## 8. Bản đồ triển khai (firmware `Src/main.c`)

| Thành phần | Vị trí | Vai trò |
|-----------|--------|---------|
| Highpass + `res.level` | FFT_Task | Lọc ch0 500Hz + tính mức cho cổng clap |
| `GCC_PHAT()` | TASK-08 | Tương quan chéo PHAT + nội suy parabol |
| `GCC_ProcessPairs()` | TASK-08 | 4 trễ cặp đối diện `GCC_PHAT(ch[2k], ch[2k+1])` |
| `g_doa_angles[16]`, `g_doa_table[16][4]` | TASK-11 | 16 góc + bảng trễ hardcode |
| `DOA_Compute()` | TASK-11 | Khớp bảng (min-SSE) → azimuth rời rạc + residual |
| `StartTask04` (DOA_Task) | TASK-11 | Cổng clap + bầu chọn 1 giây + in góc cam |
| `StartTask03` (USB_Task) | TASK-10 | Stream raw 8 kênh qua USB CDC (debug, COM12) |

---

## 9. Tham số chính

| Tham số | Giá trị | Ghi chú |
|---------|---------|---------|
| Tần số lấy mẫu fs | 16 000 Hz | |
| Frame N | 1024 mẫu | 64 ms |
| Số kênh | 8 | 4 cặp đối diện |
| Bán kính R | 40 mm | đường kính 80 mm |
| Số hướng | 16 | bước 22.5° |
| Trễ cực đại | ±3.73 mẫu | (2R·fs)/c |
| `DOA_RESID_MAX` | 0.5 | ngưỡng loại frame khớp kém |
| `DOA_WIN_BLOCKS` | 16 | cửa sổ ~1 giây |
| Highpass clap | 500 Hz | biquad bậc 2 Butterworth |
| `CLAP_RATIO` | 6 | clap khi vượt 6× nền nhiễu |
| `CLAP_ABS_MIN` | 0.5 | **cần căn trên phần cứng** |
| `CLAP_BG_ALPHA` | 0.10 | tốc độ thích nghi nền nhiễu |

---

## 10. Công cụ MATLAB (thư mục `matlab/`)

| File | Vai trò |
|------|---------|
| `gen_delay_table.m` | Sinh bảng trễ (in ra dạng C để dán vào `g_doa_table`) |
| `doa_array_table.m` | Vẽ hình học mảng mic + in bảng trễ |
| `test_doa_algorithm.m` | Mô phỏng + kiểm chứng toàn pipeline trước khi flash |
| `record_claps.m` | Ghi 20s từ micro PC + phân tích mức để căn ngưỡng |
| `optimize_clap_filter.m` | Phân tích phổ clap vs nền, quét `CLAP_RATIO` |
| `design_clap_hpf.m` | Thiết kế highpass + sinh hệ số biquad cho firmware |

---

## 11. So sánh với spec gốc (slide `fomular/`)

| | Slide gốc | Bản này |
|---|-----------|---------|
| Số hướng | 16 (22.5°) | 16 (22.5°) ✓ |
| Phương pháp | TDOA cặp đối diện + table matching | giống ✓ |
| Lọc đầu vào | — | + highpass 500Hz + cổng clap |
| Đường kính | 52 mm | 80 mm |
| Đơn vị bảng | ×4 (fractional resample) | 1× mẫu (nội suy parabol) |

> Nếu phần cứng thực tế là 52 mm → sửa `MIC_ARRAY_RADIUS_M = 0.026f` và chạy lại
> `gen_delay_table(0.026, 16)` để sinh bảng mới.
