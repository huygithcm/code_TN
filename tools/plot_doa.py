#!/usr/bin/env python3
"""
plot_doa.py - Ve huong DOA (direction of arrival) tren hinh mang mic thoi gian thuc.

Firmware STM32H7A3 in dong DOA ra ST-Link VCP (USART3/COM1, 115200 8N1):
    DOA seq=1234 az=45 (cam target, 3 clap frames)
    DOA seq=1250 no clap this second

Script doc cong VCP, bat goc `az=<do>` va ve:
  - Vong tron mang mic UCA ban kinh 40 mm
  - 8 mic (M1..M8) tai cac goc 0/45/90/.../315 deg
  - Mui ten tu tam chi ve huong nguon am vua phat hien
Quy uoc goc: 0 deg = +x (huong M1), nguoc chieu kim dong ho (CCW) la duong.

Cai dat:
    pip install pyserial matplotlib numpy

Chay:
    python tools/plot_doa.py                 # tu do cong ST-Link VCP
    python tools/plot_doa.py --port COM7
    python tools/plot_doa.py --demo          # khong can board, xoay thu mui ten
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
# 8 mic UCA. Goc dat mic la co d
# inh theo phan cung SAI (firmware):
#   ch0=0  ch1=180 | ch2=45 ch3=225 | ch4=90 ch5=270 | ch6=135 ch7=315
# So in TREN BOARD THUC doc CUNG chieu kim dong ho (CW) tu 0 deg la:
#   1, 7, 5, 3, 2, 8, 6, 4
# Moi mic: (goc dat deg, so tren board, kenh firmware ch). Mic n = ch n-1.
MICS = [
    (0,   1, 0),   # ch0
    (45,  4, 3),   # ch3
    (90,  6, 5),   # ch5
    (135, 8, 7),   # ch7
    (180, 2, 1),   # ch1
    (225, 3, 2),   # ch2
    (270, 5, 4),   # ch4
    (315, 7, 6),   # ch6
]

# Offset xoay CHI DUNG KHI VE cac mic (khong dong cham mapping goc DOA cua
# firmware: mui ten az van theo 0 deg = +x). -90 deg keo mic 1 (firmware 0 deg)
# xuong day vong tron, tuc huong ve phia nguoi dung ngoi truoc man hinh.
MIC_DRAW_ROT_DEG = -90.0

# ------------------------------------------------------- mapping az -> goc servo
# PHAI khop 1:1 voi firmware (main.c Servo_PointToAzimuth):
#   r = wrap(az - SERVO_AZ_CENTER) in (-180,180];  servo = clamp(90 + DIR*r, 0,180)
# neutral(90)=mic1(az0); DIR chon phia camera quay. Tren rig nay +1 quay dung
# huong nguon am that. PHAI bang SERVO_DIR trong main.c.
SERVO_AZ_CENTER = 0.0      # azimuth ung voi servo 90 deg (chinh dien)
SERVO_DIR       = -1.0     # +1 / -1 = chieu pan (doi neu bi nguoc)


def az_to_servo(az_deg):
    """Tinh goc servo (0..180) tu azimuth - GIONG HET firmware de doi chieu.
    Wrap phai trung khop C: r in (-180,180] (180 -> +180, KHONG phai -180)."""
    r = (az_deg - SERVO_AZ_CENTER) % 360.0      # [0,360)
    if r > 180.0:
        r -= 360.0                              # -> (-180,180]
    servo = 90.0 + SERVO_DIR * r
    return max(0.0, min(180.0, servo))


DOA_RE = re.compile(r"az\s*=\s*(-?\d+(?:\.\d+)?)")

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
    # du phong: doi chieu theo mo ta
    for p in list_ports.comports():
        desc = f"{p.description} {p.manufacturer or ''}".lower()
        if ("stlink" in desc or "st-link" in desc) and "5740" not in (p.hwid or ""):
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
                if m:
                    self.az = float(m.group(1)) % 360.0
                    self.seq = int(sm.group(1)) if sm else None
                    self.last_update = time.time()
                    self.is_live = ("live" in line)   # goc tuong doi, chua clap
                    if not self.is_live:
                        # clap xac nhan -> luu thanh nguon am (cham)
                        self.detections.append(self.az)
                        del self.detections[:-MAX_DETECTIONS]
                    print(f"  -> az={self.az:.0f}{' live' if self.is_live else ' CLAP'}", flush=True)
                else:
                    self.hb_seq = int(sm.group(1)) if sm else None
                    self.last_hb = time.time()

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
def build_plot():
    fig, ax = plt.subplots(figsize=(6.4, 6.4))
    R = MIC_RADIUS_MM
    lim = R * 1.6
    ax.set_xlim(-lim, lim)
    ax.set_ylim(-lim, lim)
    ax.set_aspect("equal")
    ax.set_title("DOA - huong nguon am tren mang mic (UCA 8 mic, R=40mm)")
    ax.set_xlabel("x (mm)   |   az=0 (mic 1) huong xuong, ve phia nguoi dung")
    ax.set_ylabel("y (mm)")
    ax.grid(True, ls=":", alpha=0.4)

    # vong tron mang
    th = np.linspace(0, 2 * np.pi, 200)
    ax.plot(R * np.cos(th), R * np.sin(th), color="0.7", lw=1)

    # cac mic (nhan = so in tren board thuc). Chi xoay vi tri VE bang
    # MIC_DRAW_ROT_DEG de mic 1 huong ve nguoi dung; goc DOA giu nguyen.
    for ang, board, ch in MICS:
        a = np.radians(ang + MIC_DRAW_ROT_DEG)
        x, y = R * np.cos(a), R * np.sin(a)
        ax.plot(x, y, "o", color="#1f77b4", ms=12, zorder=3)
        ax.annotate(str(board), (x, y), ha="center", va="center",
                    fontsize=9, color="white", fontweight="bold", zorder=4)
        ax.annotate(f"ch{ch}", (x, y), textcoords="offset points", xytext=(0, 11),
                    ha="center", fontsize=7.5, color="0.45")
    ax.plot(0, 0, "+", color="0.4", ms=12)

    # cac nguon am da tinh toan (cham, to dan theo so lan trung huong)
    src = ax.scatter([], [], s=[], c="darkorange", alpha=0.55,
                     edgecolors="black", linewidths=0.5, zorder=2,
                     label="nguon am phat hien")
    ax.legend(loc="upper right", fontsize=8, framealpha=0.7)

    # mui ten DOA (cap nhat sau)
    arrow = ax.annotate("", xy=(0, 0), xytext=(0, 0),
                        arrowprops=dict(arrowstyle="-|>", color="crimson", lw=3))
    txt = ax.text(-lim * 0.95, lim * 0.88, "az: --", fontsize=13,
                  color="crimson", fontweight="bold")
    return fig, ax, arrow, txt, src


def main():
    ap = argparse.ArgumentParser(description="Ve DOA tren hinh mang mic.")
    ap.add_argument("--port", help="Cong VCP (vd COM7). Mac dinh: tu dong do.")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--demo", action="store_true", help="Chay gia lap, khong can board.")
    args = ap.parse_args()

    if args.demo:
        reader = DemoReader()
    else:
        port = args.port or find_vcp_port()
        if not port:
            print("[LOI] Khong tim thay cong ST-Link VCP. Dung --port COMx hoac --demo.",
                  file=sys.stderr)
            sys.exit(1)
        reader = DoaReader(port, args.baud)
        reader.start()

    fig, ax, arrow, txt, src = build_plot()
    R = MIC_RADIUS_MM
    last_demo = time.time()

    # phim 'c' de xoa lich su cham nguon am
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
            # Ap cung MIC_DRAW_ROT_DEG nhu khi ve mic, de mui ten chi dung
            # huong nguon am THUC TE tren hinh (mic 1 huong ve nguoi dung).
            a = np.radians(az + MIC_DRAW_ROT_DEG)
            tip = (R * 1.25 * np.cos(a), R * 1.25 * np.sin(a))
            arrow.xy = tip
            arrow.set_position((0, 0))
            stale = (time.time() - reader.last_update) > 3.0
            live = getattr(reader, "is_live", False)
            # mau: xam=cu, xanh=goc live (chua clap), do=clap xac nhan
            color = "0.6" if stale else ("royalblue" if live else "crimson")
            arrow.arrow_patch.set_color(color)
            seq = f" (seq={reader.seq})" if reader.seq is not None else ""
            kind = "live" if live else "CLAP"
            servo = az_to_servo(az)        # cung cong thuc firmware -> doi chieu
            txt.set_text(f"az: {az:.0f} deg  ->  servo: {servo:.0f} deg [{kind}]{seq}"
                         + ("  [cu]" if stale else ""))
            txt.set_color(color)
        else:
            # chua co clap nao -> hien nhip song de biet dang ket noi
            hb = getattr(reader, "hb_seq", None)
            alive = (time.time() - getattr(reader, "last_hb", 0.0)) < 3.0
            if hb is not None and alive:
                txt.set_text(f"Listening! (seq={hb})")
                txt.set_color("seagreen")
            else:
                txt.set_text("Cho du lieu VCP...")
                txt.set_color("0.6")

        # cac nguon am da tinh: gom theo huong (22.5 deg), cham to dan theo so lan
        dets = list(reader.detections)
        if dets:
            cnt = collections.Counter((round(a / 22.5) * 22.5) % 360 for a in dets)
            angs = np.radians(np.array(list(cnt.keys())) + MIC_DRAW_ROT_DEG)
            rr = R * 1.45
            offs = np.column_stack((rr * np.cos(angs), rr * np.sin(angs)))
            sizes = [40 + 30 * cnt[k] for k in cnt]
            src.set_offsets(offs)
            src.set_sizes(sizes)
        else:
            src.set_offsets(np.empty((0, 2)))
            src.set_sizes([])
        return arrow, txt, src

    last_demo_ref = [last_demo]
    # giu tham chieu de timer khong bi GC
    from matplotlib.animation import FuncAnimation
    _anim = FuncAnimation(fig, update, interval=200, blit=False, cache_frame_data=False)
    fig._doa_anim = _anim

    try:
        plt.show()
    finally:
        if isinstance(reader, DoaReader):
            reader.stop()


if __name__ == "__main__":
    main()
