#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tdoa_micarray.py - Thu thuat toan TDOA cua Mic_Array (Phan Le Son) tren phan cung
code_TN, va SO SANH truc tiep voi GCC-PHAT hien tai.

Thuat toan Mic_Array (port tu C_DOA_BF/.../DelayEstimation.c + DOA.c):
  1. (tuy chon) RESAMPLE x4 tung kenh chan bang zero-pad mien tan so (Resampling)
     -> do phan giai tre 1/4 mau.
  2. Cross-correlation MIEN THOI GIAN (KHONG PHAT whitening), tim dinh trong
     +-PAR_RES (CrssCor / CrssCorResample).
  3. Khop bang min-SSE (DOACalc) -> huong.

Chinh cho hinh hoc code_TN: R=40mm (Ø80), Fs=16kHz, 4 cap doi tam (0,1)(2,3)(4,5)(6,7),
16 huong 22.5deg. Luong CDC RAW1 da co MIC_REMAP + 24-bit + khong dao pha tu firmware,
nen slot 2k/2k+1 la cap doi tam sach; dau tre dinh nghia khop GCC_PHAT(chan, le) firmware.

Dung:
  python tools/tdoa_micarray.py                 # live CDC, in moi ~1s, so voi GCC-PHAT
  python tools/tdoa_micarray.py --npy debug/rec_real.npy   # chay tren ban ghi
  python tools/tdoa_micarray.py --no-resample   # dung CrssCor tho (khong x4)
Phu thuoc: pyserial, numpy
"""
import sys, struct, argparse
import numpy as np

# ---- hinh hoc code_TN ----------------------------------------------------
FS = 16000.0
C  = 343.0
R  = 0.040
SCALE = (FS / C) * 2 * R            # 3.731778 mau (tre cuc dai duong kinh)
PHI = [0, 45, 90, 135]
AZ  = np.arange(0, 360, 22.5)       # 16 huong (khop g_doa_angles)
PAIRS = [(0, 1), (2, 3), (4, 5), (6, 7)]

# frame RAW1
MAGIC=b"RAW1"; HDR=12; NCH=8; NSAMP=1024; PAY=NCH*NSAMP*4; FRAME=HDR+PAY

# Mic_Array resample factor + search window (PAR_RES). Tre cuc dai x4 = ~14.9 -> +-16.
COEF = 4
PAR_RES_X4 = 16      # quarter-sample search
PAR_RES_1  = 6       # integer-sample search (khong resample)

# bang tre: DON VI = mau (float). Khi resample, nhan COEF de ve quarter-sample.
TABLE_SAMPLE = np.array([[SCALE * np.cos(np.deg2rad(a - p)) for p in PHI] for a in AZ])


def resample_x4_fft(x):
    """RESAMPLE x4 bang zero-pad mien tan so (khop Resampling() trong DelayEstimation.c).
    x: N mau thuc -> tra ve 4N mau thuc (noi suy sinc)."""
    N = len(x)
    X = np.fft.fft(x)
    Y = np.zeros(COEF * N, dtype=complex)
    h = N // 2
    Y[:h]       = X[:h]            # tan so duong
    Y[h]        = X[h] / 2.0       # Nyquist chia doi (cho real)
    Y[COEF*N-h] = X[h] / 2.0
    Y[COEF*N-h+1:] = X[h+1:]       # tan so am ve cuoi buffer
    y = np.fft.ifft(Y) * COEF      # scale bien do
    return np.real(y)


def crosscorr_lag(a, b, par_res):
    """CrssCor: cross-correlation mien thoi gian, dinh trong +-par_res.
    r(i)=sum a[j+i]*b[j] chuan hoa /(len-|i|); argmax -> lag (a truoc b khi lag>0)."""
    n = len(a)
    best = -1e30; bi = 0
    for i in range(-par_res, par_res + 1):
        if i >= 0:
            s = np.dot(a[i:n], b[:n-i]); dn = n - i
        else:
            s = np.dot(a[:n+i], b[-i:n]); dn = n + i
        s /= dn
        if s > best:
            best = s; bi = i
    return bi


def crosscorr_resample_lag(a_up, b, par_res):
    """CrssCorResample: a_up da resample x4, b khong resample (N mau).
    r(i)=sum_{j=128}^{N-128} a_up[j*COEF + i]*b[j]; argmax -> lag (don vi quarter-sample)."""
    N = len(b)
    lo, hi = 128, N - 128
    j = np.arange(lo, hi)
    best = -1e30; bi = 0
    for i in range(-par_res, par_res + 1):
        idx = j * COEF + i
        idx = np.clip(idx, 0, len(a_up) - 1)
        s = np.dot(a_up[idx], b[lo:hi]) / (hi - lo)
        if s > best:
            best = s; bi = i
    return bi


def compute_delays_micarray(x, resample=True):
    """4 tre cap doi tam theo Mic_Array (don vi mau).
    DAU: cross-correlation r(i)=sum a[j+i]*b[j] cho dinh o i=-D khi b tre hon a D mau,
    tuc NGUOC dau voi conj(Xa)*Xb cua firmware (dinh +D). Nen NEGATE de cung quy uoc
    voi g_doa_table / GCC-PHAT (neu khong se lech 180 deg khi khop bang)."""
    d = np.zeros(4)
    for k, (e, o) in enumerate(PAIRS):
        if resample:
            a_up = resample_x4_fft(x[e])
            q = crosscorr_resample_lag(a_up, x[o], PAR_RES_X4)   # quarter-sample
            d[k] = -(q / COEF)                                   # ve mau + khop dau firmware
        else:
            d[k] = -crosscorr_lag(x[e], x[o], PAR_RES_1)
    return d


def gcc_phat_lag(a, b, lo=16, hi=224):
    """GCC-PHAT band-limited + phase-slope (khop firmware code_TN) - de SO SANH."""
    n = 1024
    A = np.fft.rfft(a - a.mean(), n); B = np.fft.rfft(b - b.mean(), n)
    Rr = np.conj(A) * B
    mag = np.abs(Rr); mag[mag < 1e-9] = 1e-9
    Rw = Rr / mag
    k = np.arange(n // 2 + 1); band = (k >= lo) & (k <= hi)
    Rw = np.where(band, Rw, 0.0)
    cc = np.fft.irfft(Rw, n)
    m = 5; seg = np.concatenate((cc[-m:], cc[:m+1])); lags = np.arange(-m, m+1)
    L = int(lags[np.argmax(seg)])
    kk = k[band]; psi = np.angle(Rw[band]) + 2*np.pi*kk*L/n
    psi = (psi + np.pi) % (2*np.pi) - np.pi
    dd = -(np.sum(kk*psi)/(np.sum(kk*kk)+1e-9))/(2*np.pi/n)
    return L + max(-1, min(1, dd))


def match_table(delays):
    resid = ((TABLE_SAMPLE - delays) ** 2).sum(axis=1)
    b = int(np.argmin(resid))
    return AZ[b], resid[b], np.sort(resid)[1]


def gcc_delays(x):
    return np.array([gcc_phat_lag(x[e], x[o]) for e, o in PAIRS])


# ---------------------------------------------------------- I/O
def find_cdc():
    import serial.tools.list_ports as lp
    for p in lp.comports():
        if "5740" in (p.hwid or "").upper(): return p.device
    return None


def run_npy(path, resample):
    data = np.load(path).astype(np.float64)   # (8, N)
    N = data.shape[1]; W = NSAMP; hop = W // 2
    nwin = (N - W) // hop + 1
    dm_all, dg_all = [], []
    for w in range(nwin):
        x = data[:, w*hop: w*hop + W].copy()
        x -= x.mean(axis=1, keepdims=True)
        if np.mean(x[4]**2) < 1e4:   # bo khung qua nho
            continue
        dm_all.append(compute_delays_micarray(x, resample))
        dg_all.append(gcc_delays(x))
    if not dm_all:
        print("Khong co khung du nang luong."); return
    dm = np.median(np.array(dm_all), axis=0)
    dg = np.median(np.array(dg_all), axis=0)
    az_m, r_m, r2_m = match_table(dm)
    az_g, r_g, r2_g = match_table(dg)
    print(f"\nBan ghi: {path}  ({N} mau, {len(dm_all)} khung dung)\n")
    print(f"{'':16}{'pair0':>8}{'pair1':>8}{'pair2':>8}{'pair3':>8}   -> goc (resid, 2nd)")
    print(f"{'Mic_Array x'+('4' if resample else '1'):16}"
          + "".join(f"{v:>8.2f}" for v in dm)
          + f"   -> {az_m:5.1f}  (r={r_m:.2f}, 2nd={r2_m:.2f})")
    print(f"{'GCC-PHAT':16}"
          + "".join(f"{v:>8.2f}" for v in dg)
          + f"   -> {az_g:5.1f}  (r={r_g:.2f}, 2nd={r2_g:.2f})")
    print(f"\nLech goc giua 2 phuong phap: {abs((az_m-az_g+180)%360-180):.1f} deg")


def run_live(port, resample):
    import serial
    ser = serial.Serial(port, 115200, timeout=1)
    try: ser.set_buffer_size(rx_size=4*1024*1024)
    except Exception: pass
    buf = bytearray()
    def rd():
        while True:
            while len(buf) < 2*FRAME:
                c = ser.read(FRAME)
                if not c: return None
                buf.extend(c)
            i = buf.find(MAGIC)
            if i < 0 or i+2*FRAME > len(buf):
                if i > 0: del buf[:i]
                c = ser.read(FRAME)
                if c: buf.extend(c)
                continue
            if bytes(buf[i+FRAME:i+FRAME+4]) != MAGIC:
                del buf[:i+1]; continue
            pl = bytes(buf[i+HDR:i+FRAME]); del buf[:i+FRAME]
            return pl
    print(f"Doc {port} (Mic_Array x{COEF if resample else 1} vs GCC-PHAT). Ctrl+C thoat.\n")
    win_m, win_g = [], []
    try:
        while True:
            pl = rd()
            if pl is None: continue
            x = np.frombuffer(pl, dtype="<i4").astype(np.float64).reshape(NCH, NSAMP)
            x -= x.mean(axis=1, keepdims=True)
            if np.mean(x[4]**2) < 1e4: continue
            win_m.append(compute_delays_micarray(x, resample))
            win_g.append(gcc_delays(x))
            if len(win_m) < 16: continue
            dm = np.median(np.array(win_m), axis=0); win_m = []
            dg = np.median(np.array(win_g), axis=0); win_g = []
            az_m, r_m, _ = match_table(dm)
            az_g, r_g, _ = match_table(dg)
            flag = "" if abs((az_m-az_g+180)%360-180) < 1 else "  <-- LECH"
            print(f"Mic_Array: az={az_m:5.1f} (r={r_m:5.2f}) d=[{dm[0]:+.2f} {dm[1]:+.2f} {dm[2]:+.2f} {dm[3]:+.2f}]"
                  f"   |  GCC-PHAT: az={az_g:5.1f} (r={r_g:5.2f}){flag}")
    except KeyboardInterrupt:
        print("\nThoat.")
    finally:
        ser.close()


def main():
    ap = argparse.ArgumentParser(description="TDOA Mic_Array (Phan Le Son) tren phan cung code_TN")
    ap.add_argument("--npy", help="Chay tren file .npy (8xN) thay vi CDC live")
    ap.add_argument("--port", help="Cong CDC (mac dinh: tu do PID_5740)")
    ap.add_argument("--no-resample", action="store_true", help="Dung CrssCor tho, khong x4")
    args = ap.parse_args()
    resample = not args.no_resample
    if args.npy:
        run_npy(args.npy, resample)
    else:
        port = args.port or find_cdc()
        if not port: sys.exit("Khong tim thay cong CDC PID_5740")
        run_live(port, resample)


if __name__ == "__main__":
    main()
