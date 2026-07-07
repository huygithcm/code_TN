
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
spectrum_live.py - Hien thi pho tan so (FFT) cua ca 8 mic theo thoi gian thuc.

Doc luong USB CDC raw (RAW1 frames, PID_5740). Moi mic ve 1 subplot pho bien do
(dB) tu 0..Fs/2. Dung de soi nhieu nen: hum tan thap (40-55Hz), tong cô dinh
(398/406Hz), v.v.

CACH DUNG:
    python tools/spectrum_live.py                 # tu dong tim cong CDC
    python tools/spectrum_live.py COM12           # chi dinh cong
    python tools/spectrum_live.py --fmax 2000     # gioi han truc tan
    python tools/spectrum_live.py --avg 8         # trung binh 8 khung cho muot
    python tools/spectrum_live.py --linear        # truc bien do tuyen tinh

Phim: q hoac dong cua so de thoat.
Phu thuoc: pyserial, numpy, matplotlib  ->  pip install pyserial numpy matplotlib
"""

import sys
import struct
import argparse
import numpy as np

try:
    import serial
    import serial.tools.list_ports as list_ports
except ImportError:
    sys.exit("Thieu pyserial:  pip install pyserial numpy matplotlib")

import matplotlib
import matplotlib.pyplot as plt

# ----- dinh dang frame (khop Src/main.c) -----
MAGIC      = b"RAW1"
HDR_BYTES  = 12
NCH        = 8
NSAMP      = 1024
PAYLOAD    = NCH * NSAMP * 4          # int32 channel-major
FRAME_LEN  = HDR_BYTES + PAYLOAD

# nhan mic theo logical slot (luong = mic_raw[slot]); khop test_mic_order.py
LABELS = ["Mic1 0deg", "Mic2 180deg", "Mic3 45deg", "Mic4 225deg",
          "Mic5 90deg", "Mic6 270deg", "Mic7 135deg", "Mic8 315deg"]


def find_port(explicit=None):
    if explicit:
        return explicit
    for p in list_ports.comports():
        hwid = (p.hwid or "").upper()
        if "5740" in hwid and "0483" in hwid:      # ST OTG CDC (raw stream)
            return p.device
    for p in list_ports.comports():
        if "STM" in (p.description or "").upper():
            return p.device
    return None


def read_frame(ser, buf):
    """Doc 1 frame hop le; double-magic anchor tranh 'RAW1' gia trong payload."""
    while True:
        while len(buf) < 2 * FRAME_LEN:
            chunk = ser.read(FRAME_LEN)
            if not chunk:
                return None
            buf.extend(chunk)
        i = buf.find(MAGIC)
        if i < 0 or i + 2 * FRAME_LEN > len(buf):
            if i > 0:
                del buf[:i]
            chunk = ser.read(FRAME_LEN)
            if chunk:
                buf.extend(chunk)
            continue
        if bytes(buf[i + FRAME_LEN: i + FRAME_LEN + 4]) != MAGIC:
            del buf[:i + 1]
            continue
        payload = bytes(buf[i + HDR_BYTES: i + FRAME_LEN])
        del buf[:i + FRAME_LEN]
        return payload


def main():
    ap = argparse.ArgumentParser(description="Pho tan so live 8 mic (CDC).")
    ap.add_argument("port", nargs="?", default=None, help="Cong CDC (vd COM12).")
    ap.add_argument("--fs", type=int, default=16000, help="Sample rate (Hz).")
    ap.add_argument("--fmax", type=float, default=None, help="Gioi han truc tan (Hz).")
    ap.add_argument("--avg", type=int, default=4, help="So khung trung binh (EMA).")
    ap.add_argument("--linear", action="store_true", help="Bien do tuyen tinh thay vi dB.")
    args = ap.parse_args()

    port = find_port(args.port)
    if not port:
        sys.exit("Khong tim thay cong CDC (PID_5740). Truyen ten cong: "
                 "python tools/spectrum_live.py COM12")
    print(f"Mo {port} @ 115200 ... (dong cua so de thoat)")

    ser = serial.Serial(port, 115200, timeout=1)
    try:
        ser.set_buffer_size(rx_size=4 * 1024 * 1024)
    except Exception:
        pass

    win = np.hanning(NSAMP)
    freqs = np.fft.rfftfreq(NSAMP, 1.0 / args.fs)
    fmax = args.fmax if args.fmax else args.fs / 2.0
    fsel = freqs <= fmax
    alpha = 1.0 / max(args.avg, 1)
    ema = [None] * NCH

    plt.ion()
    fig, axes = plt.subplots(4, 2, figsize=(11, 8), sharex=True)
    fig.suptitle(f"Pho tan so live 8 mic - {port}  (Fs={args.fs}Hz)")
    axes = axes.ravel()
    lines = []
    for k in range(NCH):
        ax = axes[k]
        (ln,) = ax.plot(freqs[fsel], np.zeros(fsel.sum()), lw=0.8)
        ax.set_title(LABELS[k], fontsize=9)
        ax.set_xlim(0, fmax)
        ax.grid(True, alpha=0.3)
        ax.set_ylabel("dB" if not args.linear else "mag", fontsize=8)
        lines.append(ln)
    for k in (6, 7):
        axes[k].set_xlabel("Hz", fontsize=8)
    fig.tight_layout(rect=[0, 0, 1, 0.96])

    buf = bytearray()
    alive = [True]
    fig.canvas.mpl_connect("close_event", lambda e: alive.__setitem__(0, False))

    try:
        frame_i = 0
        while alive[0]:
            payload = read_frame(ser, buf)
            if payload is None:
                continue
            x = np.frombuffer(payload, dtype="<i4").astype(np.float64).reshape(NCH, NSAMP)
            for k in range(NCH):
                seg = (x[k] - x[k].mean()) * win
                mag = np.abs(np.fft.rfft(seg))
                ema[k] = mag if ema[k] is None else (alpha * mag + (1 - alpha) * ema[k])
            frame_i += 1
            # ve moi vai khung cho do giat
            if frame_i % 2 == 0:
                for k in range(NCH):
                    m = ema[k][fsel]
                    y = 20 * np.log10(m + 1e-6) if not args.linear else m
                    lines[k].set_ydata(y)
                    axes[k].relim(); axes[k].autoscale_view(scaley=True)
                fig.canvas.draw_idle()
                fig.canvas.flush_events()
    except KeyboardInterrupt:
        pass
    finally:
        ser.close()
        print("\nThoat.")


if __name__ == "__main__":
    main()
