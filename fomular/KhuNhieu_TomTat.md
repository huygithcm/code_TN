# Tóm tắt các phương pháp khử nhiễu — Mic Array

Tài liệu tóm gọn các **hàm** và **công thức** khử nhiễu trong dự án. Chia làm 2 nhóm:
**khử nhiễu không gian** (spatial – dùng 8 mic) và **khử nhiễu đơn kênh** (single-channel – theo phổ).

Ký hiệu chung:
- `d` : steering vector (vector hướng), kích thước `m×1` (m = 8 mic)
- `R` : ma trận coherence/hiệp phương sai của nhiễu, `m×m` theo từng bin tần số
- `γ` (gammak): SNR **hậu nghiệm** (a posteriori) — `|Y|²/λ_noise`
- `ξ` (ksi): SNR **tiên nghiệm** (a priori)
- `λ_noise` : mật độ phổ công suất (PSD) của nhiễu

---

## 1. Khử nhiễu KHÔNG GIAN (spatial)

File: `Window/Verify_For_C/BF/BeamForming.py`

### 1.1. Super-directive Beamforming (MVDR + diagonal loading)
Hàm: **`BeamFormingSD_Init`** (dòng ~60–129)

Trọng số tối ưu MVDR (Minimum Variance Distortionless Response):

```
        (εI + R)⁻¹ · d
w  =  ────────────────────────
      dᴴ · (εI + R)⁻¹ · d
```

- `R` = ma trận coherence của nhiễu khuếch tán (diffuse noise).
- `εI` = **diagonal loading** (regularization): tăng ε ⇒ tăng độ ổn định (White Noise Gain), giảm ε ⇒ tăng tính định hướng.
- ε được **dò bằng tìm nhị phân** sao cho White Noise Gain đạt ngưỡng `gamma`:
  điều kiện dừng `gain < gamma + i·5/(N/2)` (dòng 86).
- Tần số cao (`i ≥ F_SWT`): chuyển sang Delay-and-Sum `w = (1/8)·d` (dòng 106).

Ràng buộc không méo tín hiệu hướng chính: `wᴴ · d = 1`.

### 1.2. Ma trận coherence nhiễu
Hàm: **`CoheCalc`** (dòng ~143–178), **`WeightUpd` / `ListenBGNoise`** (dòng ~406–439)

Hai chế độ:
- **Nạp mô hình dựng sẵn**: file `diffuse_8_8_1025_sqrt_maya.mat` (mô hình nhiễu khuếch tán lý thuyết).
- **Ước lượng tại chỗ**: gom ~200 frame nhiễu nền, tính coherence:

```
              |S_ij(f)|²
Cxy(f)  =  ─────────────────
           S_ii(f) · S_jj(f)
```

  (`scipy.signal.coherence`, dòng 416) → cập nhật lại `R` → tính lại trọng số beamformer.

### 1.3. Delay-and-Sum Beamforming
Hàm: **`BeamFormingDS`** (dòng ~362–376)

Bù trễ rồi cộng đồng pha các kênh (miền FFT):

```
Y(f)  =  (2/m)·D₀(f)·X₀(f)  +  Σ_{i=1}^{m-1} (1/m)·Dᵢ(f)·Xᵢ(f)
```

với `Dᵢ(f) = exp(j·2π·f·τᵢ)` là hệ số bù trễ. Nhiễu không tương quan bị suy giảm ~`1/m`.

### 1.4. Post-filtering không gian (back-lobe suppression)
Hàm: **`BF_PostFiltering`** (dòng ~287–355)

Chạy song song 2 beamformer: hướng **chính** `W` và hướng **ngược 180°** `W_PF`.
Với mỗi bin tần số `k`, nếu năng lượng hướng chính không vượt trội hướng ngược thì coi là
nhiễu khuếch tán và **suy giảm mạnh**:

```
nếu |Y_main(k)| < 1.1 · |Y_back(k)|   ⇒   Y_main(k) ← 0.2 · Y_main(k)
```

(dòng 336–340). Tái tạo tín hiệu bằng overlap-add.

---

## 2. Khử nhiễu ĐƠN KÊNH (single-channel spectral)

### 2.1. log-MMSE (Ephraim–Malah)
File: `Window/src/logMMSE.c` — Hàm: **`logMMSE_denosie`**, **`noise_estimate`**

Ước lượng biên độ phổ tối ưu theo tiêu chí log-MMSE.

**Bước 1 — SNR hậu nghiệm** (dòng 125):
```
γ_k  =  min( |Y_k|² / λ_noise(k) , 40 )
```

**Bước 2 — SNR tiên nghiệm** (decision-directed, aa = 0.98) (dòng 129–134):
```
ξ_k  =  aa · (X̂_{k,prev} / λ_noise)  +  (1 − aa) · max(γ_k − 1, 0)
ξ_k  =  max(ξ_k , ξ_min)          , ξ_min = 10^(−2.5)
```

**Bước 3 — Hệ số khuếch đại log-MMSE** (dòng 157–162):
```
A_k   =  ξ_k / (1 + ξ_k)
v_k   =  A_k · γ_k
G_k   =  A_k · exp( ½ · E₁(v_k) )        (E₁ = hàm tích phân mũ, hàm expp())
X̂_k  =  G_k · Y_k
```

**Bước 4 — VAD & cập nhật nhiễu** dựa trên likelihood (mu = 0.98, eta = 0.15) (dòng 149–153):
```
Λ = (1/N) Σ_k [ γ_k·ξ_k/(1+ξ_k) − log(1+ξ_k) ]
nếu Λ < eta:   λ_noise(k) ← mu·λ_noise(k) + (1−mu)·|Y_k|²
```

Tái tạo bằng overlap-add (dòng 171–176). `noise_estimate()` khởi tạo `λ_noise` từ 6 frame đầu.

### 2.2. Two-stage Wiener Filter (chuẩn ETSI Advanced Front-End)
File: `Window/src/noise_reduction.c` — Hàm chính: **`DoNoiseSup`**

Bộ khử nhiễu 2 tầng nối tiếp (tầng 2 lọc lại đầu ra tầng 1). Các hàm con:

| Hàm | Vai trò |
|---|---|
| `DoSigWindowing` | Cửa sổ hoá + zero-padding trước FFT |
| `FFTtoPSD` | FFT → phổ công suất (PSD) |
| `PSDMean` | Làm mượt PSD theo thời gian |
| `VAD` | Voice Activity Detection theo năng lượng + hangover |
| `FilterCalc` | Ước lượng nhiễu + tính bộ lọc Wiener |
| `DoMelFB` / `DoMelIDCT` | Warping bộ lọc sang thang Mel và ngược lại |
| `DoGainFact` | Hệ số gain thích nghi theo SNR trung bình |
| `DoFilterWindowing` | Cửa sổ hoá đáp ứng xung bộ lọc (Hanning) |
| `ApplyWF` | Convolution bộ lọc vào tín hiệu (miền thời gian) |
| `DCOffsetFil` | Lọc DC offset đầu ra |

**Ước lượng nhiễu:**
- Tầng 1 (dùng VAD, dòng 300–307): khi không có tiếng nói (`flagVAD = 0`):
```
noiseSE(i) = λ_NSE · noiseSE(i) + (1 − λ_NSE) · PSD(i)
```
- Tầng 2 (không VAD, cập nhật kiểu MCRA, dòng 265–271):
```
noiseSE(i) *= 0.9 + 0.1·(P/(P+N))·(1 + 1/(1 + 0.1·P/N))
```

**Bộ lọc Wiener** (decision-directed, dòng 313–322):
```
SNR_post = PSD(i)/noiseSE(i) − 1
SNR_prio = β·(denSig(i)/noiseSE(i)) + (1−β)·max(0, SNR_post)
W(i)     = SNR_prio / (1 + SNR_prio)

# lặp tinh chỉnh với sàn RSB_MIN:
SNR_prio = max( W(i)·PSD(i)/noiseSE(i) , RSB_MIN )
W(i)     = SNR_prio / (1 + SNR_prio)
```

**Hệ số gain thích nghi** `DoGainFact` (dòng 353–413):
```
W(i) = αGF · W(i) + (1 − αGF) · 1.0
```
với `αGF ∈ [0.1, 0.8]` điều chỉnh theo SNR trung bình (SNR thấp ⇒ giữ nhiều nhiễu hơn để tránh méo).

**Lọc DC offset** (IIR bậc 1, dòng 453):
```
y[n] = x[n] − x[n−1] + 0.9990234375 · y[n−1]
```

---

## 3. Tiền xử lý phụ trợ (hỗ trợ khử nhiễu / DOA)

File: `Window/Verify_For_C/BF/DOA.py`

- **Lọc thông thấp Butterworth** bậc 4, cắt 6 kHz, trước cross-correlation (dòng 41–42).
- **Cổng năng lượng thích nghi** (dynamic power gate) — VAD thô trước khi ước lượng hướng
  (dòng 56–114): chỉ tính DOA khi `power_channel1 > power + offset`.

---

## 4. Bảng tổng hợp

| # | Phương pháp | Loại | Hàm | File |
|---|---|---|---|---|
| 1.1 | Super-directive MVDR + diagonal loading | Spatial | `BeamFormingSD_Init` | BeamForming.py |
| 1.2 | Coherence-matrix noise model | Spatial | `CoheCalc`, `WeightUpd` | BeamForming.py |
| 1.3 | Delay-and-Sum | Spatial | `BeamFormingDS` | BeamForming.py |
| 1.4 | Back-lobe post-filter | Spatial | `BF_PostFiltering` | BeamForming.py |
| 2.1 | log-MMSE (Ephraim–Malah) | Single-channel | `logMMSE_denosie` | logMMSE.c |
| 2.2 | Two-stage Wiener (ETSI AFE) | Single-channel | `DoNoiseSup` | noise_reduction.c |
| 3 | LPF Butterworth + power-gate VAD | Tiền xử lý | — | DOA.py |

> **Lưu ý luồng chạy chính** (`WAV2DOA.py`): hiện chỉ gọi **super-directive beamforming**
> (`BFCalc(..., Post_Filtering=False)`). Các bộ **log-MMSE** và **two-stage Wiener** nằm ở
> nhánh firmware C (Raspi3 / Window `src/`), chưa nối vào đường Python demo.
