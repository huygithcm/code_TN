#!/usr/bin/env python3
"""
plot_doa.py - Ve huong DOA + buoc so sanh TDOA voi bang mau, thoi gian thuc.

Cua so co 2 panel:
  TRAI  - Hinh mang mic UCA (R=40mm) + mui ten chi huong nguon am. Goc `az` doc tu
          firmware qua ST-Link VCP (USART3/COM1, 115200):
              DOA seq=1234 az=45 (cam target, 3 clap frames)
  PHAI  - Buoc "so sanh TDOA voi bang" (tinh trong Python tu luong CDC RAW1):
          4 TDOA cap doi tam (band-limited GCC-PHAT + phase-slope, khop firmware),
          residual moi trong 16 huong so voi g_doa_table, va huong thang. Sao vang
          = goc firmware (VCP) de doi chieu firmware vs phan tich.

Quy uoc goc: 0 deg = +x (Mic1), nguoc chieu kim (CCW) la duong. Khop Src/main.c:
tat ca mic cung loai, doc 24-bit, KHONG dao pha, dung CA 4 cap, KHONG hieu chinh 180.

Cai dat:  pip install pyserial matplotlib numpy

Chay:
    python tools/plot_doa.py                 # tu do VCP + CDC
    python tools/plot_doa.py --port COM5 --cdc-port COM7
    python tools/plot_doa.py --no-tdoa       # chi ve mui ten (nhu ban cu)
    python tools/plot_doa.py --demo          # khong can board
"""
import argparse
import collections
import re
import sys
import threading
import time

import numpy as np
import matplotlib.pyplot as plt

MAX_DETECTIONS = 500   # gioi han lich su nguon am de khong phinh bo nho

# ---------------------------------------------------------------- cau hinh mang
MIC_RADIUS_MM = 40.0                       # MIC_ARRAY_RADIUS_M = 0.040 m trong main.c
# 8 mic UCA. Nhan mic theo quy uoc CHUAN (nhu hinh thiet ke):
#   Mic1=0  Mic2=180 | Mic3=45 Mic4=225 | Mic5=90 Mic6=270 | Mic7=135 Mic8=315 (deg)
# Cap doi tam: (Mic1,Mic2)(Mic3,Mic4)(Mic5,Mic6)(Mic7,Mic8) -> phi_k={0,45,90,135}.
# Phan cung noi nham nen kenh thu DMA khong dung thu tu nhan; firmware sua bang
# MIC_REMAP={0,1,3,2,5,4,7,6} luc deinterleave (xem Src/main.c). Cot 'ch' duoi la
# kenh thu VAT LY dang o goc do (khong doi boi remap).
# Moi mic: (goc dat deg, so mic theo hinh, kenh thu firmware ch).
MICS = [
    (0,   1, 0),   # Mic1 @ ch0
    (45,  3, 3),   # Mic3 @ ch3
    (90,  5, 5),   # Mic5 @ ch5
    (135, 7, 7),   # Mic7 @ ch7
    (180, 2, 1),   # Mic2 @ ch1
    (225, 4, 2),   # Mic4 @ ch2
    (270, 6, 4),   # Mic6 @ ch4
    (315, 8, 6),   # Mic8 @ ch6
]

# Quy uoc VE (giong anh thiet ke): az=0 (Mic1) o TREN DINH, goc tang theo CHIEU
# KIM DONG HO. Chi anh huong cach VE, KHONG dong cham quy uoc az/servo cua firmware.
#   x = r*sin(az),  y = r*cos(az)   -> az0=top, az90=phai, az180=duoi, az270=trai
def az_to_xy(az_deg, r):
    a = np.radians(az_deg)
    return r * np.sin(a), r * np.cos(a)

# =========================================================================
# DIRECTION STANDARD  (PHAI khop y het Src/main.c)
# -------------------------------------------------------------------------
# Azimuth `az` in [0,360): 0 deg = mic 1 (ch0), tang theo nguoc chieu kim (CCW).
# Servo in [0,180]:  servo = clamp(90 + SERVO_DIR * wrap(az - SERVO_AZ_CENTER))
# Do tren rig that:  servo 0 -> Mic6(az270),  90 -> Mic2(az180),  180 -> Mic5(az90).
#   SERVO_AZ_CENTER = 180 -> Mic2 (az 180) la FRONT camera = servo 90 (neutral)
#   SERVO_DIR       = -1  -> Mic6 (az 270) = servo 0 ,  Mic5 (az 90) = servo 180
# Servo 180 deg chi phu nua vong; nguon o nua kia (quanh az 0) kep ve bien.
# Hai hang nay PHAI bang SERVO_AZ_CENTER / SERVO_DIR trong main.c.
# =========================================================================
SERVO_AZ_CENTER = 180.0
SERVO_DIR       = -1.0


def az_to_servo(az_deg):
    """Tinh goc servo (0..180) tu azimuth - GIONG HET firmware de doi chieu.
    Wrap phai trung khop C: r in (-180,180] (180 -> +180, KHONG phai -180)."""
    r = (az_deg - SERVO_AZ_CENTER) % 360.0      # [0,360)
    if r > 180.0:
        r -= 360.0                              # -> (-180,180]
    servo = 90.0 + SERVO_DIR * r
    return max(0.0, min(180.0, servo))


DOA_RE = re.compile(r"az\s*=\s*(-?\d+(?:\.\d+)?)")

# =========================================================================
# TDOA <-> bang mau (khop Src/main.c: DOA_Compute + GCC_PHAT)
# =========================================================================
_HDR = 12; _NCH = 8; _NSAMP = 1024
_PAYLOAD = _NCH * _NSAMP * 4; _FRAME = _HDR + _PAYLOAD
_MAGIC = b"RAW1"
_FS = 16000
_K = 3.731778                                   # (Fs/C)*2R, khop g_doa_table
_PHI = [0, 45, 90, 135]
AZ_TAB = np.arange(0, 360, 22.5)                # 16 huong ung voi g_doa_angles
# g_doa_table[a][k] = K*cos(az_a - phi_k)
DOA_TABLE = np.array([[_K * np.cos(np.deg2rad(a - p)) for p in _PHI] for a in AZ_TAB])
PAIRS = [(0, 1), (2, 3), (4, 5), (6, 7)]        # slot doi tam; phi=0/45/90/135
_BAND = (250, 3500)                             # GCC_BIN_LO..HI trong firmware
WIN_FRAMES = 16                                 # ~1s: median lag moi cua so (nhu firmware)


def gcc_lag(a, b):
    """band-limited GCC-PHAT + phase-slope sub-sample (khop GCC_PHAT firmware)."""
    n = 1
    while n < 2 * len(a):
        n *= 2
    A = np.fft.rfft(a - a.mean(), n)
    B = np.fft.rfft(b - b.mean(), n)
    R = np.conj(A) * B          # conj(Xa)*Xb - KHOP DAU voi GCC_PHAT firmware
    f = np.fft.rfftfreq(n, 1 / _FS)
    band = (f >= _BAND[0]) & (f <= _BAND[1])
    Rw = np.where(band, R / (np.abs(R) + 1e-9), 0.0)
    cc = np.fft.irfft(Rw, n)
    m = 6
    seg = np.concatenate((cc[-m:], cc[:m + 1]))
    lags = np.arange(-m, m + 1)
    L = int(lags[np.argmax(seg)])
    kk = np.arange(n // 2 + 1)[band]
    phi = np.angle(Rw[band])
    psi = phi + 2 * np.pi * kk * L / n
    psi = (psi + np.pi) % (2 * np.pi) - np.pi
    d = -(np.sum(kk * psi) / (np.sum(kk * kk) + 1e-9)) / (2 * np.pi / n)
    d = max(-1, min(1, d))
    return L + d


def match_table(lags):
    """So 4 lag do voi g_doa_table -> (best_idx, resid[16]). Dung CA 4 cap, KHONG
    hieu chinh 180 (khop firmware moi)."""
    resid = ((DOA_TABLE - lags) ** 2).sum(axis=1)
    return int(np.argmin(resid)), resid


# --------------------------------------------------------------- doc serial VCP
def find_vcp_port():
    """Tu dong tim cong ST-Link Virtual COM Port (VID 0483, KHONG phai CDC PID 5740)."""
    try:
        from serial.tools import list_ports
    except ImportError:
        return None
    for p in list_ports.comports():
        # ST-Link VCP = VID 0483, PID khac 5740 (5740 la cong CDC stream mic).
        if p.vid == 0x0483 and p.pid != 0x5740:
            return p.device
    for p in list_ports.comports():
        desc = f"{p.description} {p.manufacturer or ''}".lower()
        if ("stlink" in desc or "st-link" in desc) and "5740" not in (p.hwid or ""):
            return p.device
    return None


def find_cdc_port():
    """Tu dong tim cong CDC stream mic (VID 0483 PID 5740)."""
    try:
        from serial.tools import list_ports
    except ImportError:
        return None
    for p in list_ports.comports():
        if p.vid == 0x0483 and p.pid == 0x5740:
            return p.device
    return None


class DoaReader(threading.Thread):
    """Doc VCP trong thread rieng, cap nhat self.az khi gap dong DOA."""
    def __init__(self, port, baud=115200):
        super().__init__(daemon=True)
        self.port = port
        self.baud = baud
        self.az = None            # goc moi nhat (deg) hoac None
        self.seq = None
        self.last_update = 0.0
        self.hb_seq = None        # seq cua dong "no clap" gan nhat (heartbeat)
        self.last_hb = 0.0
        self.is_live = False      # True: goc tuong doi (chua clap); False: clap xac nhan
        self.detections = []      # lich su goc cac nguon am da tinh (deg)
        self.running = True

    def run(self):
        import serial
        try:
            sp = serial.Serial(self.port, self.baud, timeout=1)
        except Exception as e:
            print(f"[LOI] Khong mo duoc {self.port}: {e}", file=sys.stderr)
            self.running = False
            return
        print(f"[OK] Dang doc DOA tu {self.port} @ {self.baud}")
        with sp:
            while self.running:
                try:
                    line = sp.readline().decode("ascii", "ignore").strip()
                except Exception:
                    continue
                if not line or "DOA" not in line:
                    continue
                sm = re.search(r"seq\s*=\s*(\d+)", line)
                m = DOA_RE.search(line)
                # Chi nhan huong da XAC NHAN (dong "cam target" = tieng noi/clap).
                if m and ("live" not in line):
                    self.az = float(m.group(1)) % 360.0
                    self.seq = int(sm.group(1)) if sm else None
                    self.last_update = time.time()
                    self.is_live = False
                    self.detections.append(self.az)      # luu thanh nguon am (cham)
                    del self.detections[:-MAX_DETECTIONS]
                    print(f"  -> az={self.az:.0f} VOICE", flush=True)
                else:
                    self.hb_seq = int(sm.group(1)) if sm else None
                    self.last_hb = time.time()

    def stop(self):
        self.running = False


class TdoaReader(threading.Thread):
    """Doc luong CDC RAW1, tinh 4 TDOA cap doi tam va khop bang moi ~1s.
    Cung thuat toan voi firmware -> az/lag khop de doi chieu."""
    def __init__(self, port, baud=115200):
        super().__init__(daemon=True)
        self.port = port
        self.baud = baud
        self.lags = None          # 4 lag do (median cua so gan nhat)
        self.resid = None         # residual 16 huong
        self.best = None          # index huong thang
        self.best_az = None       # goc thang (deg)
        self.last_update = 0.0
        self.ok = True
        self.err = None
        self.running = True

    def _read_frame(self, ser, buf):
        while True:
            while len(buf) < 2 * _FRAME:
                c = ser.read(_FRAME)
                if not c:
                    return None
                buf.extend(c)
            i = buf.find(_MAGIC)
            if i < 0 or i + 2 * _FRAME > len(buf):
                if i > 0:
                    del buf[:i]
                c = ser.read(_FRAME)
                if c:
                    buf.extend(c)
                continue
            if bytes(buf[i + _FRAME:i + _FRAME + 4]) != _MAGIC:
                del buf[:i + 1]
                continue
            pl = bytes(buf[i + _HDR:i + _FRAME])
            del buf[:i + _FRAME]
            return pl

    def run(self):
        import serial
        try:
            ser = serial.Serial(self.port, self.baud, timeout=1)
            try:
                ser.set_buffer_size(rx_size=4 * 1024 * 1024)
            except Exception:
                pass
        except Exception as e:
            self.ok = False
            self.err = str(e)
            print(f"[TDOA] Khong mo duoc CDC {self.port}: {e}", file=sys.stderr)
            return
        print(f"[OK] Dang tinh TDOA tu CDC {self.port}")
        buf = bytearray()
        win = []
        with ser:
            while self.running:
                pl = self._read_frame(ser, buf)
                if pl is None:
                    continue
                x = np.frombuffer(pl, dtype="<i4").astype(np.float64).reshape(_NCH, _NSAMP)
                if np.mean(x[4] ** 2) < 1e4:        # bo khung qua nho
                    continue
                win.append([gcc_lag(x[a], x[b]) for a, b in PAIRS])
                if len(win) < WIN_FRAMES:
                    continue
                med = np.median(np.array(win), axis=0)
                win = []
                best, resid = match_table(med)
                self.lags = med
                self.resid = resid
                self.best = best
                self.best_az = float(AZ_TAB[best])
                self.last_update = time.time()

    def stop(self):
        self.running = False


class DemoReader:
    """Gia lap: mui ten xoay 22.5 deg moi giay (khong can phan cung)."""
    def __init__(self):
        self.az = 0.0
        self.seq = 0
        self.last_update = time.time()
        self.detections = []
        self.running = True

    def step(self):
        self.az = (self.az + 22.5) % 360.0
        self.seq += 16
        self.last_update = time.time()
        self.detections.append(self.az)
        del self.detections[:-MAX_DETECTIONS]


# ------------------------------------------------------------------- ve do thi
def build_plot(with_tdoa=True):
    if with_tdoa:
        fig, (ax, ax2) = plt.subplots(1, 2, figsize=(12.6, 6.4),
                                      gridspec_kw={"width_ratios": [1, 1.15]})
    else:
        fig, ax = plt.subplots(figsize=(6.4, 6.4))
        ax2 = None
    R = MIC_RADIUS_MM
    lim = R * 1.6
    ax.set_xlim(-lim, lim)
    ax.set_ylim(-lim, lim)
    ax.set_aspect("equal")
    ax.set_title("Sound Source Localization - UCA 8 mic (R=40mm)")
    ax.set_xlabel("az=0 (Mic1) o tren dinh, tang theo chieu kim dong ho")
    ax.grid(True, ls=":", alpha=0.3)

    th = np.linspace(0, 2 * np.pi, 200)
    ax.plot(R * np.cos(th), R * np.sin(th), color="0.6", lw=1.2)

    for ang, board, ch in MICS:
        x, y = az_to_xy(ang, R)
        ax.plot(x, y, "o", color="#1f77b4", ms=14, zorder=3)
        ax.annotate(f"Mic{board}", (x, y), textcoords="offset points",
                    xytext=(0, 14), ha="center", fontsize=10,
                    color="#1f3b66", fontweight="bold", zorder=4)
        bx, by = az_to_xy(ang, R * 1.32)
        ax.annotate(f"{ang}", (bx, by), ha="center", va="center", fontsize=8.5,
                    color="crimson", zorder=4,
                    bbox=dict(boxstyle="square,pad=0.18", fc="white", ec="crimson", lw=1))
    ax.plot(0, 0, "+", color="0.4", ms=12)

    src = ax.scatter([], [], s=[], c="darkorange", alpha=0.55,
                     edgecolors="black", linewidths=0.5, zorder=2,
                     label="nguon am phat hien")
    ax.legend(loc="lower right", fontsize=8, framealpha=0.7)   # duoi de khong dam dong az

    arrow = ax.annotate("", xy=(0, 0), xytext=(0, 0),
                        arrowprops=dict(arrowstyle="-|>", color="crimson", lw=3))
    txt = ax.text(-lim * 0.95, lim * 0.88, "az: --", fontsize=13,
                  color="crimson", fontweight="bold")

    tdoa = None
    if with_tdoa:
        # Panel phai: "khop bang" = residmax - resid, chuan hoa [0,1] (1 = tot nhat).
        xs = np.arange(len(AZ_TAB))
        bars = ax2.bar(xs, np.zeros(len(AZ_TAB)), color="#4c72b0", width=0.8)
        ax2.set_ylim(0, 1.05)
        ax2.set_xticks(xs)
        ax2.set_xticklabels([f"{a:g}" for a in AZ_TAB], rotation=90, fontsize=7)
        ax2.set_xlabel("azimuth ung vien (deg)")
        ax2.set_ylabel("do khop (1 = residual nho nhat)")
        ax2.set_title("Buoc so sanh TDOA voi bang g_doa_table")
        ax2.grid(True, axis="y", ls=":", alpha=0.3)
        # sao vang = goc firmware (VCP) de doi chieu
        fw_marker, = ax2.plot([], [], marker="*", ms=18, color="gold",
                              mec="black", mew=0.6, ls="none", zorder=5,
                              label="goc firmware (VCP)")
        lag_txt = ax2.text(0.5, 1.14, "", transform=ax2.transAxes, ha="center",
                           va="top", fontsize=9, family="monospace")
        res_txt = ax2.text(0.5, -0.30, "Cho du lieu CDC...", transform=ax2.transAxes,
                           ha="center", va="top", fontsize=11, color="0.5",
                           fontweight="bold")
        ax2.legend(loc="upper right", fontsize=8, framealpha=0.7)
        fig.subplots_adjust(top=0.84, bottom=0.22, wspace=0.25)
        tdoa = dict(ax=ax2, bars=bars, fw_marker=fw_marker,
                    lag_txt=lag_txt, res_txt=res_txt)
    return fig, ax, arrow, txt, src, tdoa


def main():
    ap = argparse.ArgumentParser(description="Ve DOA + so sanh TDOA voi bang mau.")
    ap.add_argument("--port", help="Cong VCP (vd COM5). Mac dinh: tu dong do.")
    ap.add_argument("--cdc-port", help="Cong CDC RAW1 cho panel TDOA. Mac dinh: tu do.")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--no-tdoa", action="store_true", help="Chi ve mui ten, bo panel TDOA.")
    ap.add_argument("--demo", action="store_true", help="Chay gia lap, khong can board.")
    args = ap.parse_args()

    tdoa_reader = None
    if args.demo:
        reader = DemoReader()
        with_tdoa = False
    else:
        port = args.port or find_vcp_port()
        if not port:
            print("[LOI] Khong tim thay cong ST-Link VCP. Dung --port COMx hoac --demo.",
                  file=sys.stderr)
            sys.exit(1)
        reader = DoaReader(port, args.baud)
        reader.start()

        with_tdoa = not args.no_tdoa
        if with_tdoa:
            cdc = args.cdc_port or find_cdc_port()
            if not cdc:
                print("[TDOA] Khong thay cong CDC (PID 5740) -> bo panel TDOA. "
                      "Dung --cdc-port COMx neu can.", file=sys.stderr)
                with_tdoa = False
            else:
                tdoa_reader = TdoaReader(cdc, args.baud)
                tdoa_reader.start()

    fig, ax, arrow, txt, src, tdoa = build_plot(with_tdoa=with_tdoa)
    R = MIC_RADIUS_MM
    last_demo = time.time()

    def on_key(ev):
        if ev.key in ("c", "C"):
            reader.detections.clear()
    fig.canvas.mpl_connect("key_press_event", on_key)

    def update(_frame):
        if isinstance(reader, DemoReader):
            if time.time() - last_demo_ref[0] >= 1.0:
                reader.step()
                last_demo_ref[0] = time.time()
        az = reader.az
        if az is not None:
            tip = az_to_xy(az, R * 1.15)
            arrow.xy = tip
            arrow.set_position((0, 0))
            stale = (time.time() - reader.last_update) > 3.0
            color = "0.6" if stale else "crimson"
            arrow.arrow_patch.set_color(color)
            arrow.arrow_patch.set_visible(True)
            seq = f" (seq={reader.seq})" if reader.seq is not None else ""
            servo = az_to_servo(az)
            txt.set_text(f"az: {az:.0f} deg  ->  servo: {servo:.0f} deg [VOICE]{seq}"
                         + ("  [cu]" if stale else ""))
            txt.set_color(color)
        else:
            arrow.arrow_patch.set_visible(False)
            hb = getattr(reader, "hb_seq", None)
            alive = (time.time() - getattr(reader, "last_hb", 0.0)) < 3.0
            if hb is not None and alive:
                txt.set_text(f"Listening! (seq={hb})")
                txt.set_color("seagreen")
            else:
                txt.set_text("Cho du lieu VCP...")
                txt.set_color("0.6")

        dets = list(reader.detections)
        if dets:
            cnt = collections.Counter((round(a / 22.5) * 22.5) % 360 for a in dets)
            keys = list(cnt.keys())
            offs = np.array([az_to_xy(k, R * 1.5) for k in keys])
            sizes = [40 + 30 * cnt[k] for k in keys]
            src.set_offsets(offs)
            src.set_sizes(sizes)
        else:
            src.set_offsets(np.empty((0, 2)))
            src.set_sizes([])

        # ---- panel TDOA ----
        if tdoa is not None and tdoa_reader is not None and tdoa_reader.resid is not None:
            resid = tdoa_reader.resid
            rng = resid.max() - resid.min()
            score = (resid.max() - resid) / (rng + 1e-9)     # 1 = khop nhat
            best = tdoa_reader.best
            for i, b in enumerate(tdoa["bars"]):
                b.set_height(score[i])
                b.set_color("crimson" if i == best else "#4c72b0")
            med = tdoa_reader.lags
            exp = DOA_TABLE[best]
            tdoa["lag_txt"].set_text(
                "lag do :  " + "  ".join(f"{v:+5.2f}" for v in med) + "\n"
                "lag bang: " + "  ".join(f"{v:+5.2f}" for v in exp) + "   (pair0..3)")
            fresh = (time.time() - tdoa_reader.last_update) < 3.0
            tdoa["res_txt"].set_text(
                f"GOC TDOA: {tdoa_reader.best_az:.1f} deg   "
                f"resid={resid[best]:.2f}" + ("" if fresh else "   [cu]"))
            tdoa["res_txt"].set_color("crimson" if fresh else "0.6")
            # sao vang: goc firmware (VCP) tren cung truc
            if az is not None:
                fi = int(round((az % 360.0) / 22.5)) % len(AZ_TAB)
                tdoa["fw_marker"].set_data([fi], [score[fi]])
            else:
                tdoa["fw_marker"].set_data([], [])
        elif tdoa is not None and tdoa_reader is not None and not tdoa_reader.ok:
            tdoa["res_txt"].set_text(f"CDC loi: {tdoa_reader.err}")

        return arrow, txt, src

    last_demo_ref = [last_demo]
    from matplotlib.animation import FuncAnimation
    _anim = FuncAnimation(fig, update, interval=200, blit=False, cache_frame_data=False)
    fig._doa_anim = _anim

    try:
        plt.show()
    finally:
        if isinstance(reader, DoaReader):
            reader.stop()
        if tdoa_reader is not None:
            tdoa_reader.stop()


if __name__ == "__main__":
    main()
