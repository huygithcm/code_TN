#!/usr/bin/env python3
"""
servo_test.py - Test servo camera doc lap voi DOA.

Firmware nhan lenh "SERVO <do>" tren cong USB CDC (PA11/PA12, VID 0483 PID 5740)
va xoay servo PB6 toi goc do ngay (bo qua DOA). Dung script nay de kiem tra rieng
servo: di co dung goc khong, co giu yen khong, hay bi giat/run (nguon/PWM).

Cac che do:
    sweep   : quet muot 0 -> 180 -> 0, lap lai (mac dinh)
    steps   : nhay tung nac 0,45,90,135,180 roi ve, GIU moi goc vai giay
    hold    : giu MOT goc co dinh (--angle) - de soi servo co run khong
    manual  : go goc tu ban phim (Enter), 'q' de thoat

Cach doc ket qua:
    - Servo KHONG nhuc nhich o moi che do  -> day tin hieu/nguon/dat day PB6 sai.
    - Giu 1 goc ma servo van RUN/KEU        -> nguon yeu hoac thieu GND chung.
    - Di dung goc o 'steps'/'manual'        -> servo OK; "lung tung" la do DOA
                                               ban lenh (false clap) -> chinh SET.

Cai dat:
    pip install pyserial

Chay:
    python tools/servo_test.py                 # tu do cong CDC, che do sweep
    python tools/servo_test.py steps
    python tools/servo_test.py hold --angle 90
    python tools/servo_test.py manual
    python tools/servo_test.py --port COM7 sweep
"""
import argparse
import sys
import time


def find_cdc_port():
    """Tim cong USB CDC cua firmware (VID 0483, PID 5740) - KHONG phai ST-Link VCP."""
    try:
        from serial.tools import list_ports
    except ImportError:
        return None
    for p in list_ports.comports():
        if p.vid == 0x0483 and p.pid == 0x5740:
            return p.device
    # du phong: tim theo mo ta CDC
    for p in list_ports.comports():
        if "5740" in (p.hwid or "") or "CDC" in (p.description or "").upper():
            return p.device
    return None


def send_angle(sp, deg):
    """Gui lenh "SERVO <deg>" (firmware clamp ve 0..180)."""
    deg = max(0.0, min(180.0, float(deg)))
    sp.write(f"SERVO {deg:.0f}\n".encode("ascii"))
    sp.flush()
    print(f"  -> SERVO {deg:.0f}", flush=True)
    return deg


def run_sweep(sp, step=5, dwell=0.03):
    """Quet muot len/xuong, lap mai cho den khi Ctrl+C."""
    print("Che do SWEEP 0<->180 (Ctrl+C de dung)")
    seq = list(range(0, 181, step)) + list(range(180, -1, -step))
    while True:
        for a in seq:
            send_angle(sp, a)
            time.sleep(dwell)


def run_steps(sp, dwell=2.0):
    """Nhay tung nac va GIU - de mat nhin servo co dung goc + giu yen khong."""
    print("Che do STEPS (Ctrl+C de dung)")
    pts = [0, 45, 90, 135, 180, 90]
    while True:
        for a in pts:
            send_angle(sp, a)
            time.sleep(dwell)


def run_hold(sp, angle, dwell=1.0):
    """Giu MOT goc - quan sat servo co run/keu (jitter) khong."""
    print(f"Che do HOLD tai {angle:.0f} deg (Ctrl+C de dung)")
    send_angle(sp, angle)
    while True:
        # gui lai dinh ky de bu truong hop firmware bi DOA ghi de
        send_angle(sp, angle)
        time.sleep(dwell)


def run_manual(sp):
    """Go goc tu ban phim."""
    print("Che do MANUAL - nhap goc 0..180 roi Enter, 'q' de thoat")
    while True:
        try:
            s = input("goc> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if s.lower() in ("q", "quit", "exit"):
            break
        if not s:
            continue
        try:
            send_angle(sp, float(s))
        except ValueError:
            print("  (nhap so 0..180)")


def main():
    ap = argparse.ArgumentParser(description="Test servo camera qua USB CDC.")
    ap.add_argument("mode", nargs="?", default="sweep",
                    choices=["sweep", "steps", "hold", "manual"])
    ap.add_argument("--port", help="Cong CDC (vd COM7). Mac dinh: tu dong do.")
    ap.add_argument("--baud", type=int, default=115200, help="CDC bo qua baud, de mac dinh.")
    ap.add_argument("--angle", type=float, default=90.0, help="Goc cho che do hold.")
    ap.add_argument("--step", type=int, default=5, help="Buoc goc cho sweep.")
    args = ap.parse_args()

    import serial

    port = args.port or find_cdc_port()
    if not port:
        print("[LOI] Khong tim thay cong USB CDC (VID 0483 PID 5740).\n"
              "      Cam cap USB user (PA11/PA12) hoac chi dinh --port COMx.",
              file=sys.stderr)
        sys.exit(1)

    try:
        sp = serial.Serial(port, args.baud, timeout=1)
    except Exception as e:
        print(f"[LOI] Khong mo duoc {port}: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"[OK] Mo {port} - dieu khien servo bang lenh SERVO")
    try:
        with sp:
            if args.mode == "sweep":
                run_sweep(sp, step=args.step)
            elif args.mode == "steps":
                run_steps(sp)
            elif args.mode == "hold":
                run_hold(sp, args.angle)
            elif args.mode == "manual":
                run_manual(sp)
    except KeyboardInterrupt:
        pass
    finally:
        print("\nDung. Dua servo ve 90 deg.")
        try:
            sp2 = serial.Serial(port, args.baud, timeout=1)
            with sp2:
                send_angle(sp2, 90)
        except Exception:
            pass


if __name__ == "__main__":
    main()
