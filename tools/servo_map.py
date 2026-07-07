#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
servo_map.py  -  Xoay servo 0..180 do de mapping goc camera vs goc lenh.

Gui lenh "SERVO <deg>" qua cong USB CDC (OTG, PID_5740) toi firmware. Lenh nay
DAT servo truc tiep va TAT che do DOA (g_servo_auto=0). Go "AUTO" de bat lai DOA.

  us = 600 + 10*deg   (deg 0 -> 600us, 90 -> 1500us, 180 -> 2400us)

CACH DUNG:
  python tools/servo_map.py                 # che do tuong tac (go so de xoay)
  python tools/servo_map.py --sweep         # quet tu dong 0->180->0, lap lai
  python tools/servo_map.py --sweep --step 15 --delay 1.0
  python tools/servo_map.py COM12           # chi dinh cong

Che do tuong tac:
  <so 0..180>  -> xoay servo den goc do, in ra de ban ghi lai goc camera thuc
  s            -> quet 0..180 mot luot (buoc 15 do)
  a            -> AUTO (bat lai DOA tu dong)
  q            -> thoat

Phu thuoc: pyserial   ->  pip install pyserial
"""

import sys
import time
import argparse

try:
    import serial
    import serial.tools.list_ports as list_ports
except ImportError:
    sys.exit("Thieu pyserial:  pip install pyserial")


def find_port(explicit=None):
    if explicit:
        return explicit
    for p in list_ports.comports():
        hwid = (p.hwid or "").upper()
        if "5740" in hwid and "0483" in hwid:      # ST OTG CDC (nhan lenh SERVO)
            return p.device
    return None


def send(ser, line):
    ser.write((line + "\n").encode("ascii"))
    ser.flush()


def servo_us(deg):
    return 600 + 10 * deg          # khop SERVO_MIN_US=600, MAX_US=2400 trong main.c


def sweep(ser, step, delay):
    print(f"Quet 0 -> 180 -> 0, buoc {step} do, nghi {delay}s. Ctrl+C de dung.")
    seq = list(range(0, 181, step)) + list(range(180, -1, -step))
    try:
        while True:
            for d in seq:
                send(ser, f"SERVO {d}")
                print(f"  SERVO {d:3d} deg  (~{servo_us(d)} us)")
                time.sleep(delay)
    except KeyboardInterrupt:
        print("\nDung quet.")


def interactive(ser):
    print("Go so 0..180 de xoay servo. Lenh: s=quet  a=AUTO(DOA)  q=thoat\n")
    while True:
        try:
            cmd = input("servo> ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            break
        if cmd in ("q", "quit", "exit"):
            break
        if cmd == "a":
            send(ser, "AUTO 1")
            print("  -> AUTO 1 (bat lai DOA tu dong)")
            continue
        if cmd == "s":
            sweep(ser, 15, 0.8)
            continue
        try:
            d = float(cmd)
        except ValueError:
            print("  ? nhap so 0..180, hoac s/a/q")
            continue
        d = max(0.0, min(180.0, d))
        send(ser, f"SERVO {d:g}")
        print(f"  -> SERVO {d:g} deg  (~{servo_us(d):.0f} us). Ghi lai goc camera thuc.")


def main():
    ap = argparse.ArgumentParser(description="Mapping goc servo qua USB CDC.")
    ap.add_argument("port", nargs="?", help="Cong CDC (vd COM12). Mac dinh: tu do PID_5740.")
    ap.add_argument("--sweep", action="store_true", help="Quet tu dong 0..180..0.")
    ap.add_argument("--step", type=int, default=15, help="Buoc quet (do).")
    ap.add_argument("--delay", type=float, default=1.0, help="Nghi giua moi buoc (s).")
    args = ap.parse_args()

    port = find_port(args.port)
    if not port:
        sys.exit("Khong tim thay cong CDC (PID_5740). Truyen ten cong: "
                 "python tools/servo_map.py COM12")
    print(f"Mo {port} @ 115200 ...\n")
    ser = serial.Serial(port, 115200, timeout=1)
    try:
        if args.sweep:
            sweep(ser, args.step, args.delay)
        else:
            interactive(ser)
    finally:
        ser.close()
        print("Da dong cong.")


if __name__ == "__main__":
    main()