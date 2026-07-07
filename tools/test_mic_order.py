#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_mic_order.py  -  Kiem tra thu tu mic hien tai da dung chua.

Doc luong USB CDC raw (RAW1 frames) tu firmware. Sau khi remap, kenh thu k trong
luong = slot mic_data[k] = Mic(k+1) theo nhan chuan:

    slot0 = Mic1 (0 deg)    slot4 = Mic5 (90 deg)
    slot1 = Mic2 (180 deg)  slot5 = Mic6 (270 deg)
    slot2 = Mic3 (45 deg)   slot6 = Mic7 (135 deg)
    slot3 = Mic4 (225 deg)  slot7 = Mic8 (315 deg)

CACH DUNG:
    1. Nap firmware, doi USB CDC (PID_5740) enumerate.
    2. python tools/test_mic_order.py        (tu dong tim cong COM dung)
       hoac: python tools/test_mic_order.py COM12
    3. Go nhe / noi sat TUNG mic. Cot RMS cua mic do phai nhay len cao nhat
       (danh dau '<<< LOUDEST'). Neu mic ban go la Mic5 ma cot Mic3 nhay ->
       thu tu/wiring sai, chinh MIC_REMAP trong Src/main.c.

Phu thuoc: pyserial, numpy   ->  pip install pyserial numpy
"""

import sys
import struct
import numpy as np

try:
    import serial
    import serial.tools.list_ports as list_ports
except ImportError:
    sys.exit("Thieu pyserial:  pip install pyserial numpy")

# ----- dinh dang frame (khop Src/main.c) -----
MAGIC      = b"RAW1"
HDR_BYTES  = 12
NCH        = 8
NSAMP      = 1024
PAYLOAD    = NCH * NSAMP * 4          # int32 channel-major
FRAME_LEN  = HDR_BYTES + PAYLOAD      # 32780

# slot -> (ten mic, goc dat). Khop bang trong CLAUDE doc + MIC_REMAP.
SLOT_LABEL = [
    ("Mic1", 0),   ("Mic2", 180), ("Mic3", 45),  ("Mic4", 225),
    ("Mic5", 90),  ("Mic6", 270), ("Mic7", 135), ("Mic8", 315),
]


def find_port(explicit=None):
    if explicit:
        return explicit
    for p in list_ports.comports():
        hwid = (p.hwid or "").upper()
        if "5740" in hwid and "0483" in hwid:      # ST OTG CDC (raw stream)
            return p.device
    # fallback: bat ky cong nao co tu 'STMicro'
    for p in list_ports.comports():
        if "STM" in (p.description or "").upper():
            return p.device
    return None


def read_frame(ser, buf):
    """Doc tiep tu serial, tra ve (payload_bytes, seq) cua 1 frame hop le.
    Dung 'double-magic anchor': xac nhan MAGIC o i VA o i+FRAME_LEN de tranh
    'RAW1' gia nam trong payload (xem ghi chu trong memory du an)."""
    while True:
        # can du it nhat 2 frame de kiem tra anchor doi
        while len(buf) < 2 * FRAME_LEN:
            chunk = ser.read(FRAME_LEN)
            if not chunk:
                return None, None
            buf.extend(chunk)
        i = buf.find(MAGIC)
        if i < 0 or i + 2 * FRAME_LEN > len(buf):
            # chua thay magic / chua du -> doc them
            if i > 0:
                del buf[:i]
            chunk = ser.read(FRAME_LEN)
            if chunk:
                buf.extend(chunk)
            continue
        if bytes(buf[i + FRAME_LEN: i + FRAME_LEN + 4]) != MAGIC:
            # anchor doi khong khop -> truot 1 byte
            del buf[:i + 1]
            continue
        seq = struct.unpack_from("<I", buf, i + 4)[0]
        payload = bytes(buf[i + HDR_BYTES: i + FRAME_LEN])
        del buf[:i + FRAME_LEN]
        return payload, seq


def main():
    port = find_port(sys.argv[1] if len(sys.argv) > 1 else None)
    if not port:
        sys.exit("Khong tim thay cong CDC (PID_5740). Truyen ten cong: "
                 "python tools/test_mic_order.py COM12")
    print(f"Mo {port} @ 115200 ... (Ctrl+C de thoat)\n")

    ser = serial.Serial(port, 115200, timeout=1)
    try:
        ser.set_buffer_size(rx_size=4 * 1024 * 1024)   # frame ~32KB, mac dinh 4KB qua nho
    except Exception:
        pass

    buf = bytearray()
    rms_ema = np.zeros(NCH)          # lam muot de cot do on dinh
    ALPHA = 0.4

    try:
        while True:
            payload, seq = read_frame(ser, buf)
            if payload is None:
                print("(khong co du lieu - dang stream chua? co flash dung firmware?)")
                continue
            x = np.frombuffer(payload, dtype="<i4").astype(np.float64)
            x = x.reshape(NCH, NSAMP)                 # channel-major
            rms = np.sqrt(np.mean(x * x, axis=1))
            rms_ema = ALPHA * rms + (1 - ALPHA) * rms_ema

            peak = int(np.argmax(rms_ema))
            scale = max(rms_ema.max(), 1.0)

            # ve lai man hinh
            lines = [f"seq={seq}   (go sat tung mic -> cot do phai cao nhat)\n"]
            for k in range(NCH):
                name, ang = SLOT_LABEL[k]
                barlen = int(40 * rms_ema[k] / scale)
                bar = "#" * barlen
                mark = "  <<< LOUDEST" if k == peak else ""
                lines.append(
                    f"slot{k} {name:>4} {ang:>3}deg | {bar:<40} {rms_ema[k]:9.1f}{mark}")
            # \033[2J\033[H = clear + home (ANSI). Tren Windows terminal moi deu OK.
            sys.stdout.write("\033[2J\033[H" + "\n".join(lines) + "\n")
            sys.stdout.flush()
    except KeyboardInterrupt:
        print("\nThoat.")
    finally:
        ser.close()


if __name__ == "__main__":
    main()