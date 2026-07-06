#!/usr/bin/env python3
"""
record_channels.py - Ghi song am 8 kenh tu board (USB CDC) de chuan doan.

Firmware stream cac khung RAW1 qua cong CDC (VID 0483 PID 5740):
    header 12 byte: 'RAW1' | seq(u32 LE) | nch(u8) | nsamp(u16 LE) | fmt(u8=0:int32 LE)
    payload        : nch*nsamp int32, channel-major (ch0 het mau, roi ch1, ...)
nch=8, nsamp=1024 -> 1 khung = 64 ms @ 16 kHz.

Kenh -> so mic tren board:  board = ch + 1  (mic n = ch n-1).

Tac dung: thay tung kenh co tin hiu khong, muc RMS/peak, co bat duoc tieng vo tay
khong -> chuan doan vi sao DOA khong kich.

Cai dat:  pip install pyserial numpy matplotlib

Vi du:
    python tools/record_channels.py --seconds 3
    python tools/record_channels.py --seconds 2 --out debug/clap   # vo tay khi ghi
"""
import argparse
import os
import sys
import time
import wave

import numpy as np

HDR = 12
MAGIC = b"RAW1"


def find_cdc_port():
    from serial.tools import list_ports
    for p in list_ports.comports():
        if p.vid == 0x0483 and p.pid == 0x5740:
            return p.device
    return None


def read_frames(port, seconds):
    import serial
    sp = serial.Serial(port, 115200, timeout=1)
    sp.reset_input_buffer()
    buf = bytearray()
    frames = []
    nch = nsamp = frame_len = None
    deadline = time.time() + seconds
    try:
        while time.time() < deadline:
            chunk = sp.read(16384)
            if chunk:
                buf += chunk
            # parse cac khung day du trong buffer
            while True:
                i = buf.find(MAGIC)
                if i < 0:
                    if len(buf) > 1 << 20:
                        del buf[:-4]
                    break
                if i > 0:
                    del buf[:i]
                if len(buf) < HDR:
                    break
                if frame_len is None:
                    nch = buf[8]
                    nsamp = buf[9] | (buf[10] << 8)
                    frame_len = HDR + nch * nsamp * 4
                if len(buf) < frame_len:
                    break
                payload = bytes(buf[HDR:frame_len])
                arr = np.frombuffer(payload, dtype="<i4").reshape(nch, nsamp)
                frames.append(arr)
                del buf[:frame_len]
    finally:
        sp.close()
    if not frames:
        return None, None, None
    data = np.concatenate(frames, axis=1)   # (nch, total_samples)
    return data, nch, nsamp


def to_int16(data):
    """int32 -> int16 nghe duoc. Mic moi la loai 24-bit (dinh ~1M), vuot xa dai
    16-bit; neu clip cung se keo bien toan bo -> WAV vo dung. Khi dinh vuot 16-bit,
    co gian TOAN BO cac kenh bang MOT he so chung (giu dung ti le muc giua cac mic)
    ve ~+-32000. Neu du lieu von nam trong dai 16-bit (mic cu) thi giu nguyen."""
    peak = float(np.max(np.abs(data))) if data.size else 0.0
    if peak > 32767.0:
        return np.round(data * (32000.0 / peak)).astype("<i2")
    return np.clip(data, -32768, 32767).astype("<i2")


def write_wavs(data, fs, out_prefix, per_channel=True):
    """Xuat WAV: 1 file da kenh + (tuy chon) tung kenh mono. Tra ve list path."""
    nch, N = data.shape
    i16 = to_int16(data)
    paths = []

    # 1 file da kenh (kenh xen ke): khung = (N, nch)
    multi = out_prefix + f"_{nch}ch.wav"
    with wave.open(multi, "wb") as w:
        w.setnchannels(nch)
        w.setsampwidth(2)
        w.setframerate(fs)
        w.writeframes(i16.T.copy().tobytes())   # (N, nch) interleaved
    paths.append(multi)

    # tung kenh mono (board1..boardN)
    if per_channel:
        d = os.path.dirname(out_prefix) or "."
        base = os.path.basename(out_prefix)
        wdir = os.path.join(d, base + "_wav")
        os.makedirs(wdir, exist_ok=True)
        for ch in range(nch):
            p = os.path.join(wdir, f"ch{ch}_board{ch+1}.wav")
            with wave.open(p, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(fs)
                w.writeframes(i16[ch].copy().tobytes())
            paths.append(p)
    return paths


def main():
    ap = argparse.ArgumentParser(description="Ghi song am 8 kenh tu board (CDC).")
    ap.add_argument("--port", help="Cong CDC (vd COM7). Mac dinh: tu dong do.")
    ap.add_argument("--seconds", type=float, default=2.0, help="Thoi gian ghi (s).")
    ap.add_argument("--out", default="debug/rec_channels",
                    help="Tien to file xuat (.npy + .png).")
    ap.add_argument("--fs", type=int, default=16000, help="Sample rate (Hz).")
    ap.add_argument("--no-wav", action="store_true", help="Khong xuat file WAV.")
    ap.add_argument("--no-png", action="store_true", help="Khong ve waveform PNG.")
    args = ap.parse_args()

    port = args.port or find_cdc_port()
    if not port:
        print("[LOI] Khong tim thay cong CDC (PID 5740). Dung --port COMx.", file=sys.stderr)
        sys.exit(1)

    print(f"[OK] Ghi {args.seconds:g}s tu {port} ... (vo tay neu can)")
    data, nch, nsamp = read_frames(port, args.seconds)
    if data is None:
        print("[LOI] Khong nhan duoc khung RAW1 nao. Board co dang stream khong?",
              file=sys.stderr)
        sys.exit(1)
    total = data.shape[1]
    print(f"[OK] Nhan {total} mau/kenh ({total/args.fs:.2f}s), {nch} kenh.\n")

    # thong ke tung kenh
    print(f"{'kenh':>5} {'board':>5} {'RMS':>12} {'peak':>12}")
    for ch in range(nch):
        x = data[ch].astype(np.float64)
        rms = np.sqrt(np.mean(x * x))
        pk = np.max(np.abs(x))
        print(f"  ch{ch:<2} {ch+1:>5} {rms:>12.0f} {pk:>12.0f}")

    # luu du lieu
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    npy = args.out + ".npy"
    np.save(npy, data)
    print(f"\n[OK] Luu du lieu: {npy}")

    # xuat WAV nghe duoc
    if not args.no_wav:
        wavs = write_wavs(data, args.fs, args.out)
        print(f"[OK] Luu {len(wavs)} file WAV:")
        print(f"     da kenh : {wavs[0]}")
        if len(wavs) > 1:
            print(f"     tung kenh: {os.path.dirname(wavs[1])}/ch*_board*.wav")

    if args.no_png:
        return

    # ve waveform 8 kenh
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    t = np.arange(total) / args.fs
    fig, axes = plt.subplots(nch, 1, figsize=(11, 1.5 * nch), sharex=True)
    ymax = max(1.0, float(np.max(np.abs(data))))
    for ch, ax in enumerate(axes):
        ax.plot(t, data[ch], lw=0.5, color="#1f77b4")
        ax.set_ylim(-ymax, ymax)
        ax.set_ylabel(f"ch{ch}\n(board {ch+1})", fontsize=8, rotation=0,
                      ha="right", va="center")
        ax.grid(True, ls=":", alpha=0.4)
        ax.tick_params(labelsize=7)
    axes[0].set_title(f"Song am 8 kenh - {total/args.fs:.2f}s @ {args.fs} Hz")
    axes[-1].set_xlabel("thoi gian (s)")
    fig.tight_layout()
    png = args.out + ".png"
    fig.savefig(png, dpi=110)
    print(f"[OK] Luu waveform: {png}")


if __name__ == "__main__":
    main()
