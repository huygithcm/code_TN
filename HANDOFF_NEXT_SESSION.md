# Handoff — phiên 2026-06-11 (tạm dừng)

Trạng thái công việc đang dở để phiên sau tiếp tục.

## Đã hoàn thành & ĐÃ commit

- `19ce8c6` — Sửa đảo cực tính mic **ch3** (SAI1-B slot1, PE3) và **ch6** (SAI2-B slot0, PA0)
  bằng nhân −1 trong `Deinterleave_Pair` (`Src/main.c`). Đã flash + xác nhận trên phần cứng:
  cả 8 kênh tương quan dương 0.72–0.91. (ch6 trước đó lỗi tiếp xúc, user đã hàn lại,
  sau hàn bị ngược cực → bù firmware.)
  Kèm 2 tool chẩn đoán mới:
  - `scripts/diag_mic_channels.ps1` — DC/RMS/peak + ma trận tương quan zero-lag 8 kênh từ COM12.
  - `scripts/mic_tap_test.ps1` — bar mức live từng kênh để định vị mic vật lý (gõ mic → bar nhảy).
- `48761e6` — README.md, `matlab/delay_table_16k_52mm.csv`, refresh report cũ.

## Đã hoàn thành nhưng CHƯA commit

1. **Lọc DOA trong firmware** (`Src/main.c`, `StartTask04`/DOA_Task — modified, chưa commit):
   - Loại fix có `el <= 0.5°` (nghiệm kẹp biên = lật gương front-back, az lệch ~180°).
   - Median trượt cửa sổ 7 fix: az dùng **median vòng tròn** (phần tử có tổng khoảng cách
     góc wrap-around nhỏ nhất), el median thường. `g_doa_az/el` + dòng in `DOA` là giá trị đã lọc.
   - **Đã flash + verify trên phần cứng**: với nguồn âm cố định, az khóa 317.6–320.4° (±1.5°),
     không còn frame lật 180° nào trong 25 s. (User xác nhận đúng hướng nguồn.)
   - Firmware đang chạy trên board CHÍNH LÀ bản này.

2. **`matlab/doa_live_plot.m`** (untracked) — plot polar live hướng DOA từ COM3:
   kim đỏ = az, độ dài kim = el (90° tâm → 0° vành), vệt 20 fix gần nhất. Đã viết xong, chưa test với MATLAB GUI.

## ĐANG DỞ — beamforming nhiều nguồn (việc chính cho phiên sau)

**File:** `matlab/srp_beamform_multi.m` (untracked) + test `matlab/test_srp_sim.m` (untracked).

SRP-PHAT băng rộng (300–4000 Hz, Hann, PHAT whitening), lưới az 0:2:358 × el 0:10:60,
hình học UCA R=40 mm khớp `mic_pos[]` firmware (ch0=0°, ch1=180°, ch2=45°, ch3=225°,
ch4=90°, ch5=270°, ch6=135°, ch7=315°). Nhiều nguồn bằng **successive cancellation**:
tìm đỉnh → chiếu bỏ `X ← X − a(aᴴX)/M` từng bin → quét lại.

Đã sửa 2 bug quan trọng (đừng làm lại):
- **Dấu steering**: phải là `expArg = +2i*pi*fUse` (khử trễ truyền). Dấu − cho góc sai hệ thống.
- Peak-picking thuần (đã bỏ) bắt nhầm búp phụ — khẩu độ 80 mm búp chính rất rộng (±12° ≈ 93% công suất).

**Trạng thái test:**
- `test_srp_sim.m` (one-shot, headless): **PASS** — 2 nguồn sim (chirp az=60°, noise az=250°)
  tìm đúng cả hai, sai số 0°.
- `srp_beamform_multi('sim', 2, 3)`: **CHỈ tìm thấy S1 (250°), KHÔNG ra S2 (60°)** —
  trong khi test PASS với cùng thuật toán. ĐÂY LÀ BUG ĐANG DEBUG DỞ.

**Dấu vết debug hiện tại:**
- Đã thêm `fprintf("S%d: az=... power=%.2f (x P1)\n", ...)` TẠM ở ~dòng 109 của
  `srp_beamform_multi.m` (sau check `PEAK_REL`) — chạy sim chỉ in S1, tức vòng s=2
  bị `break` vì `v < PEAK_REL*P1` (0.25) hoặc thoát sớm. Cần in cả ratio khi break để biết giá trị thật.
- Khác biệt nghi ngờ giữa hàm chính và test: hàm chính trừ DC trong `read_frame` nhưng
  sim-mode KHÔNG qua `read_frame` (gọi `sim_frame` trực tiếp, không trừ DC, không sao —
  test cũng vậy mà PASS). Soát kỹ: `rng` (test cố định seed 7, sim_frame không seed →
  mỗi frame noise khác), và **thứ tự then chốt**: kiểm tra xem hàm chính có dùng đúng
  `Xw` sau cancellation và `PEAK_REL` so với test (test KHÔNG có ngưỡng). Khả năng cao
  chỉ là ratio thật ~0.1–0.2 < 0.25 do frame sim khác (test dùng rng(7) cho kết quả đẹp).
  → Hướng xử lý: in ratio thực tế vài frame sim; nếu ~0.1–0.2 thì hạ `PEAK_REL` (~0.08–0.1)
  hoặc đổi tiêu chí dừng (ví dụ so với noise floor của map thay vì đỉnh P1).
- Nhớ XÓA dòng fprintf debug khi xong.

**Plot mới (đã làm theo yêu cầu "dễ nhìn hơn"):** 1 hình radar nhìn từ trên xuống —
vòng tròn + nhãn độ 0–315°, chấm đen = mảng mic ở tâm, mũi tên màu (đỏ/xanh/lục) =
hướng từng nguồn kèm nhãn "Nguon N: az° (cao el°)", viền xanh quanh vòng = năng lượng
theo hướng. Render kiểm tra bằng:
`matlab -batch "...; srp_beamform_multi('sim',2,3); print(gcf, '...png','-dpng','-r100')"`
(lưu ý: `exportgraphics` cho ảnh TRẮNG trong batch mode — dùng `print` thay thế).
Hàm có tham số thứ 3 `maxFrames` để chạy N frame rồi dừng (phục vụ test headless).

## Việc cho phiên sau (theo thứ tự)

1. Debug nốt vì sao `srp_beamform_multi('sim')` không ra nguồn 2 (xem dấu vết trên).
2. Xóa fprintf debug, render sim ra PNG xác nhận 2 mũi tên ở 60° & 250°.
3. Chạy thật với COM12 + 2 nguồn âm vật lý.
4. Commit phần lọc DOA firmware + 3 file MATLAB mới (chưa commit, xem mục trên).

## Môi trường / lệnh nhanh

- Build: prepend PATH make+gcc của CubeIDE (xem memory `cli-build-and-flash-setup`),
  `Push-Location STM32CubeIDE\Debug; make all`.
- Flash: `STM32_Programmer_CLI -c port=SWD mode=UR -d ...elf -rst`, PHẢI thấy `File download complete`.
- COM3 = VCP ST-Link (log DOA/MON ~1 Hz), COM12 = OTG CDC stream RAW1 (8ch × 1024 × int32).
- MATLAB R2024a: `C:\Program Files\MATLAB\R2024a\bin\matlab.exe -batch "..."`.
- Cảnh báo "Function sim has the same name..." khi chạy batch là vô hại (file `sim`-related
  trong matlab/ hoặc tên arg), bỏ qua.
