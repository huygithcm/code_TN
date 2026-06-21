# CHƯƠNG 2 — CƠ SỞ LÝ THUYẾT (nội dung viết theo đúng code firmware)

> Mọi công thức, hằng số và con số dưới đây được lấy trực tiếp từ `Src/main.c`.
> Tham số gốc: `Fs = 16 kHz`, `N = 1024`, `R = 0.040 m`, `C = 343 m/s`,
> 8 micro INMP441 (UCA), 4 cặp đối tâm, 16 hướng rời rạc (bước 22.5°).

---

## 2.1. Phương pháp TDOA

### 2.1.1. Nguyên lý cơ bản của phương pháp TDOA

TDOA (Time Difference Of Arrival — hiệu thời gian đến) định vị nguồn âm dựa trên
**độ trễ thời gian** của một sóng âm khi đến hai micro đặt cách nhau. Nếu nguồn âm
ở xa (sóng phẳng) tới mảng theo phương hợp với baseline của cặp micro một góc θ,
sóng phải đi thêm một quãng đường `d·cos θ` để tới micro xa hơn, ứng với độ trễ:

```
τ = (d / C) · cos θ        [giây]
```

với `d` là khoảng cách giữa hai micro, `C` là tốc độ âm. Quy đổi sang **số mẫu**
(đơn vị code dùng để xử lý) bằng cách nhân tần số lấy mẫu `Fs`:

```
lag = Fs · τ = (Fs / C) · d · cos θ   [mẫu]
```

Khi đo được `lag`, ta suy ngược ra góc θ → đó là hướng đến của nguồn âm (DOA).
Trong đề tài, mỗi cặp dùng **hai micro đối tâm** nên `d = 2R` (đường kính mảng) để
đạt khẩu độ lớn nhất, cho độ phân giải góc tốt nhất.

### 2.1.2. Mô hình hình học mảng microphone

8 micro bố trí đều trên một đường tròn (Uniform Circular Array) bán kính
`R = 40 mm`, cách nhau 45°. Quy ước hệ trục: **azimuth 0° = hướng +x (mic 1),
chiều dương ngược kim đồng hồ**.

**Bố trí vật lý** (đọc vòng quanh đường tròn theo góc tăng dần):

| Góc  | 0° | 45° | 90° | 135° | 180° | 225° | 270° | 315° |
|------|----|----|----|----|----|----|----|----|
| Mic  | 1  | 4  | 6  | 8  | 2  | 3  | 5  | 7  |
| Kênh | ch0| ch3| ch5| ch7| ch1| ch2| ch4| ch6|

Do cách đấu dây của board, các kênh thu DMA (ch0…ch7) **không** xếp đúng theo nhãn
micro. Thay vì đảo dấu rải rác trong bảng độ trễ, firmware sửa lỗi nối dây **một
chỗ duy nhất** — lúc copy dữ liệu vào bộ nhớ (`Deinterleave_Pair`) — bằng một mảng
hoán vị:

```
MIC_REMAP[kênh_thu] = { 0, 1, 3, 2, 5, 4, 7, 6 }   // ch -> slot logic (Mic order)
```

Nhờ đó `mic_data[]` luôn ở **đúng thứ tự nhãn Mic1…Mic8** như hình, và bốn cặp đối
tâm (slot `2k`, `2k+1`) trở nên sạch (mỗi cặp lệch đúng 180°, baseline qua tâm `2R`):

| Cặp k | φ_k (góc baseline) | Slot chẵn = mic (góc) | Slot lẻ = mic đối tâm (góc) |
|-------|------|------|------|
| 0 | 0°   | Mic1 (0°)  | Mic2 (180°) |
| 1 | 45°  | Mic3 (45°) | Mic4 (225°) |
| 2 | 90°  | Mic5 (90°) | Mic6 (270°) |
| 3 | 135° | Mic7 (135°)| Mic8 (315°) |

Góc baseline `φ_k` lấy theo slot chẵn của cặp:

```
φ_k = {0°, 45°, 90°, 135°}   (k = 0..3)
```

Đây là dữ liệu dựng nên bảng `g_doa_table` trong code. (Lỗi nối dây phần cứng được
hấp thụ hoàn toàn bởi `MIC_REMAP`, **không** lẫn vào bảng độ trễ.)

### 2.1.3. Độ trễ cực đại theo số mẫu

Độ trễ lớn nhất xảy ra khi nguồn nằm đúng trên trục baseline (cos θ = 1). Với cặp
đối tâm `d = 2R`:

```
lag_max = (Fs / C) · 2R
        = (16000 / 343) · (2 · 0.040)
        = (16000 / 343) · 0.080
        = 3.731778  mẫu   (≈ 4 mẫu)
```

Ý nghĩa: mọi độ trễ đo được phải nằm trong khoảng `[−3.73 ; +3.73]` mẫu. Con số
này (a) **giới hạn phạm vi tìm đỉnh** của GCC-PHAT và (b) là **hệ số tỉ lệ** để
dựng bảng mẫu độ trễ ở mục 2.1.7, đồng thời (c) dùng để **chuẩn hóa sai số khớp**
(mục 2.1.9). Vì độ trễ cực đại chỉ ~3,7 mẫu, độ phân giải mẫu nguyên là quá thô,
nên bắt buộc phải nội suy dưới mẫu (sub-sample) — xem mục 2.1.6.

### 2.1.4. Biến đổi Fourier nhanh FFT 1024 điểm

Mỗi block thu được `N = 1024` mẫu/kênh (đúng bằng kích thước FFT). Trước khi FFT,
tín hiệu được nhân với **cửa sổ Hann** để giảm rò phổ (spectral leakage):

```
w[n] = 0.5 · (1 − cos(2π·n / (N − 1))),   n = 0 .. N−1
```

(trong code: `hann_window[i] = 0.5f*(1.0f - cosf(2*PI*i/(N-1)))`, tính sẵn 1 lần
ở `FFT_Init()`). Sau đó dùng FFT thực `arm_rfft_fast_f32` của CMSIS-DSP cho cả 8
kênh (`FFT_ProcessAll`). Phân giải tần số:

```
Δf = Fs / N = 16000 / 1024 = 15.625 Hz/bin
```

cho `N/2 = 512` bin biên độ. FFT là bước trung gian: nó đưa tín hiệu sang miền tần
số để tính tương quan chéo bằng phép nhân (nhanh hơn nhiều so với chập miền thời
gian) và để áp được trọng số pha PHAT.

### 2.1.5. Ước lượng TDOA bằng tương quan chéo tổng quát GCC-PHAT

GCC-PHAT (Generalized Cross-Correlation with Phase Transform) ước lượng độ trễ
giữa hai kênh `a[n]`, `b[n]` cùng nguồn. Các bước (hàm `GCC_PHAT(a, b)`):

**(1) FFT hai kênh:**
```
X_a = FFT(a),   X_b = FFT(b)
```

**(2) Phổ chéo (cross-spectrum)** `R = conj(X_a)·X_b`. Với mỗi bin
`X_a = a_r + j·a_i`, `X_b = b_r + j·b_i`:
```
re =  a_r·b_r + a_i·b_i
im =  a_r·b_i − a_i·b_r
```
Pha của R(f) chính bằng `pha(X_b) − pha(X_a) = −2π·f·D` — một độ dốc tuyến tính
chứa toàn bộ thông tin độ trễ D.

**(3) Chuẩn hóa PHAT (làm trắng phổ):** chia mỗi bin cho biên độ của nó để chỉ
giữ lại **pha**, bỏ biên độ:
```
R_phat(f) = R(f) / |R(f)|,    |R(f)| ← max(|R(f)|, 1e−9)   (chống chia 0)
```
Việc bỏ biên độ làm mọi tần số đóng góp như nhau ⇒ đỉnh tương quan **nhọn** và
**bền với phổ nguồn lẫn tiếng vang** — ưu điểm cốt lõi của PHAT so với tương quan
chéo thường.

**(4) IFFT về miền thời gian** thu hàm tương quan, rồi tìm đỉnh:
```
r[n] = IFFT( R_phat ),    lag = argmax_n r[n]
```
Chỉ số `n > N/2` được quy về độ trễ âm (mảng tuần hoàn). `lag` dương nghĩa là tín
hiệu tới micro **a trước** micro b.

**(5) Nội suy parabol (sub-sample)** — xem mục 2.1.6.

> Hai thành phần thực thuần (DC ở bin 0 và Nyquist ở bin 1 trong định dạng packed
> của CMSIS) được rút gọn: `conj(X_a)·X_b` chỉ còn tích thực, PHAT → dấu ±1.

### 2.1.6. Nội suy parabol cho lag phân số

Vì `lag_max ≈ 3,7 mẫu`, đỉnh nguyên quá thô. Fit một parabol qua 3 điểm quanh
đỉnh `(y₋₁, y₀, y₊₁)` để lấy phần lẻ δ:

```
δ = 0.5 · (y₋₁ − y₊₁) / (y₋₁ − 2·y₀ + y₊₁),     kẹp δ ∈ [−1, 1]
lag_phân_số = lag + δ
```

(các hàng xóm lấy vòng quanh vì r[n] tuần hoàn). Giá trị `lag_phân_số`
(`g_last_frac` trong code) mới là đầu vào cho bước khớp DOA.

### 2.1.7. Xây dựng bảng mẫu độ trễ (Delay Map)

Giả sử nguồn ở 1 trong **16 hướng rời rạc** `az = {0°, 22.5°, …, 337.5°}`. Độ trễ
**lý thuyết** của cặp k cho hướng az:

```
lag(az, k) = (Fs/C)·2R · cos(az − φ_k) = 3.731778 · cos(az − φ_k)   [mẫu]
```

với `φ_k = {0°, 45°, 90°, 135°}`. Bảng `g_doa_table[16][4]` được tính sẵn (hard-
code) gồm 16 hàng × 4 cột. Ví dụ kiểm chứng vài ô:

| Tính tay | Giá trị | Ô trong bảng |
|---|---|---|
| az=0, k=0: `3.731778·cos(0°)` | **3.731778** | `g_doa_table[0][0]` ✓ |
| az=0, k=1: `3.731778·cos(0−45°)` | **2.638766** | `g_doa_table[0][1]` ✓ |
| az=0, k=2: `3.731778·cos(0−90°)` | **0.000000** | `g_doa_table[0][2]` ✓ |
| az=0, k=3: `3.731778·cos(0−135°)` | **−2.638766** | `g_doa_table[0][3]` ✓ |
| az=22.5, k=0: `3.731778·cos(22.5°)` | **3.447714** | `g_doa_table[1][0]` ✓ |

(Các giá trị đặc trưng: `3.731778·cos(22.5°)=3.447714`,
`·cos(45°)=2.638766`, `·cos(67.5°)=1.428090`.)

### 2.1.8. Tính bốn giá trị độ trễ giữa các cặp microphone

Mỗi block, hàm `GCC_ProcessPairs()` áp GCC-PHAT cho **cả 4 cặp đối tâm**:

```
lag[k] = GCC_PHAT( ch[2k], ch[2k+1] ),   k = 0..3
```

thu được véc-tơ 4 độ trễ phân số `lag[0..3]` (lưu ở `g_tdoa_lag_f`). Đây là "vân
tay" hướng của block hiện tại, sẽ đem so khớp với 16 hàng của Delay Map.

### 2.1.9. Xác định hướng đến DOA bằng so khớp mẫu

Hàm `DOA_Compute(lag, &az, &resid)` duyệt 16 hướng, chọn hàng có **tổng bình
phương sai số (SSE) nhỏ nhất**:

```
e(a) = Σ_{k=0..3} ( lag[k] − g_doa_table[a][k] )²
best_a = argmin_a e(a)
az = g_doa_angles[best_a]
```

Sai số được **chuẩn hóa** để dùng làm thước đo chất lượng khớp (0 = khớp hoàn hảo):

```
resid = e(best_a) / ( N_pairs · lag_max² )
      = e(best_a) / ( 4 · 3.731778² )
      = e(best_a) / 55.70
```

`resid` nhỏ ⇒ khớp tốt; nó vừa làm **trọng số phiếu bầu**, vừa làm ngưỡng loại
frame nhiễu (`resid ≥ g_doa_resid_max = 0.7` thì bỏ).

### 2.1.10. Phát hiện sự kiện âm (clap gate) và ước lượng nền nhiễu

Trong phòng ồn, nhiễu nền đến từ mọi hướng và sẽ làm "nhòe" DOA. Hệ thống chỉ bỏ
phiếu cho các **frame có tiếng vỗ tay (clap)** — sự kiện xung, năng lượng bật vọt
trên nền nhiễu.

**Mức năng lượng frame** lấy từ kênh ch0, lọc thông cao 500 Hz rồi cộng bình
phương (loại nhiễu tần thấp của phòng, làm clap — phổ rộng 500–2 kHz — nổi bật):

```
HPF Butterworth bậc 2, Fs=16 kHz (thiết kế design_clap_hpf.m):
  B = [ 0.87033078,  −1.74066156,  0.87033078 ]
  A = [ 1.00000000,  −1.72377617,  0.75754694 ]
level = Σ_n y[n]²        (y = HPF(ch0), biquad transposed-DF-II, giữ state qua frame)
```

**Cổng clap** (`is_clap`): mức phải vọt cả tương đối lẫn tuyệt đối:
```
is_clap = ( level > ratio · bg )  AND  ( level > abs )
ratio = g_clap_ratio = 1.8   ;   abs = g_clap_abs = 0.0005
```

**Nền nhiễu `bg`** cập nhật bằng trung bình trượt mũ (EMA) chỉ ở frame KHÔNG phải
clap:
```
bg ← bg + α · (level − bg),   α = CLAP_BG_ALPHA = 0.10
```

Cả 3 ngưỡng `ratio / abs / resid_max` chỉnh được lúc chạy qua USB CDC
(`SET ratio/abs/resid <giá trị>`).

### 2.1.11. Kết hợp đa block bằng bỏ phiếu theo cửa sổ thời gian

Một quyết định hướng dựa trên nhiều block trong **cửa sổ 1 giây** cho ổn định.
Số block/giây:

```
block_rate = Fs / N = 16000 / 1024 = 15.625 ≈ 16 block/s   → DOA_WIN_BLOCKS = 16
```

Mỗi frame clap hợp lệ bỏ phiếu cho hướng của nó, trọng số theo chất lượng khớp:
```
nếu is_clap và resid < resid_max:   vote[ idx(az) ] += (1 − resid);  n_acc++
```

Hết cửa sổ (`seq − win_start ≥ 16`):
- Nếu `n_acc > 0`: chọn hướng nhiều phiếu nhất `g_doa_az = argmax_a vote[a]`, rồi
  `Servo_PointToAzimuth(g_doa_az)` xoay camera.
- Nếu không có clap: chỉ in hướng best-fit "live" (chưa xác nhận).
- Xóa `vote[]`, reset cửa sổ.

### 2.1.12. Đánh giá ưu — nhược điểm phương pháp TDOA

**Ưu điểm:** PHAT cho đỉnh nhọn, bền nhiễu và tiếng vang; chi phí tính toán thấp
(FFT + nhân phổ), chạy thời gian thực trên STM32; dùng cặp đối tâm cho khẩu độ tối
đa; bỏ phiếu theo cửa sổ + clap gate khử nhiễu nền tốt.

**Nhược điểm:** độ phân giải góc rời rạc 22.5° (16 hướng); độ trễ cực đại chỉ ~3,7
mẫu nên rất nhạy với sai số sub-sample (cần nội suy parabol); PHAT cần năng lượng
phổ rộng (kém với tone đơn); mảng phẳng chỉ phân biệt được phương vị (azimuth),
không phân biệt được nguồn trước/sau gây nhập nhằng nửa mặt cầu.

---

## 2.2. Ánh xạ azimuth → góc servo và điều khiển PWM
*(nội dung cho Chương Thiết kế/Thực nghiệm — đặt ở đây để tham chiếu)*

Camera quét 180°, **neutral 90° = az 180° (Mic2, chính diện)** — đo trên rig thật.
Quy đổi:

```
r     = wrap( az − SERVO_AZ_CENTER )  ∈ (−180°, 180°]      (SERVO_AZ_CENTER = 180)
servo = clamp( 90 + SERVO_DIR · r , 0 , 180 )              (SERVO_DIR = −1)
```

Góc servo → độ rộng xung (PWM 50 Hz trên PB6 = TIM4_CH1):
```
us = SERVO_MIN_US + (SERVO_MAX_US − SERVO_MIN_US) · servo/180
   = 600 + (2400 − 600) · servo/180
   = 600 + 10 · servo      [µs]
```

Timer: `PSC = 63` ⇒ 64 MHz/64 = 1 MHz (1 µs/tick); `ARR = 19999` ⇒ 20 ms = 50 Hz.

| Nguồn | az | r | servo | xung |
|---|---|---|---|---|
| Chính diện (Mic2) | 180° | 0°   | 90°  | 1500 µs |
| Mic6              | 270° | 90°  | 0°   | 600 µs  |
| Mic5              | 90°  | −90° | 180° | 2400 µs |

> Nguồn ở nửa sau (r ngoài [−90°,90°] sau ánh xạ) bị `Servo_SetAngle` kẹp về biên
> 0° hoặc 180° — hệ quả của giới hạn 180° của servo.

---

### Bảng tra hằng số ↔ vị trí trong code

| Đại lượng | Giá trị | Nơi trong `Src/main.c` |
|---|---|---|
| `Fs`, `N` | 16 kHz, 1024 | dòng 67, 48/65 |
| `R`, `C` | 0.040 m, 343 m/s | dòng 90, 89 |
| `lag_max` | 3.731778 mẫu | dòng 1329, 1376 |
| Cửa sổ Hann | 0.5(1−cos(2πi/(N−1))) | dòng 1092 |
| GCC-PHAT | re/im, /|R|, IFFT, parabol | dòng 1206–1254 |
| Delay Map | 3.731778·cos(az−φ_k) | dòng 1331–1348 |
| `DOA_Compute` SSE + resid | e=Σd², /(4·lag_max²) | dòng 1359–1378 |
| Clap HPF + level | Butterworth bậc 2, Σy² | dòng 1570–1582 |
| Cổng clap + EMA | ratio 1.8 / abs 5e−4 / α 0.10 | dòng 1711, 1714 |
| Cửa sổ bỏ phiếu | 16 block ≈ 1 s | dòng 1676, 1732 |
| Servo us | 600 + 10·servo | dòng 391, 296–297 |