#!/usr/bin/env python3
"""
set_doa_filter.py - Chinh nguong "clap gate" cua DOA tu PC luc dang chay.

Firmware nhan lenh qua cong USB CDC (VID 0483 PID 5740 - cung cong stream mic).
3 tham so chinh duoc:
    ratio  - clap khi muc nang luong > ratio x nen nhieu   (mac dinh 3.0)
    abs    - nguong tuyet doi de im lang khong kich         (mac dinh 0.15)
    resid  - bo khung co do khop te hon nguong nay          (mac dinh 0.7)
Giam ratio/abs -> de bat hon (nhung nhieu hon). Tang resid -> nhan nhieu khung hon.

Firmware xac nhan bang dong "CFG ratio=.. abs=.. resid=.. (x1000)" tren cong
ST-Link VCP (xem bang plot_doa.py hoac doc COM VCP), KHONG tren cong CDC nay.

Cai dat:  pip install pyserial

Vi du:
    python tools/set_doa_filter.py --ratio 2.5 --abs 0.1
    python tools/set_doa_filter.py --resid 0.8
    python tools/set_doa_filter.py --easy        # bo set rat nhay
    python tools/set_doa_filter.py --port COM9 --ratio 3
"""
import argparse
import sys
import time


def find_cdc_port():
    """Tim cong USB CDC cua board (VID 0483 PID 5740)."""
    try:
        from serial.tools import list_ports
    except ImportError:
        return None
    for p in list_ports.comports():
        if p.vid == 0x0483 and p.pid == 0x5740:
            return p.device
    return None


def main():
    ap = argparse.ArgumentParser(description="Set DOA clap-gate filter qua USB CDC.")
    ap.add_argument("--port", help="Cong CDC (vd COM9). Mac dinh: tu dong do.")
    ap.add_argument("--ratio", type=float, help="clap nguong = ratio x nen nhieu")
    ap.add_argument("--abs", type=float, dest="abs_", help="nguong muc tuyet doi")
    ap.add_argument("--resid", type=float, help="nguong residual toi da")
    ap.add_argument("--easy", action="store_true",
                    help="bo set de bat: ratio=2.0 abs=0.08 resid=0.85")
    args = ap.parse_args()

    if args.easy:
        if args.ratio is None: args.ratio = 2.0
        if args.abs_ is None:  args.abs_ = 0.08
        if args.resid is None: args.resid = 0.85

    cmds = []
    if args.ratio is not None: cmds.append(f"SET ratio {args.ratio}")
    if args.abs_ is not None:  cmds.append(f"SET abs {args.abs_}")
    if args.resid is not None: cmds.append(f"SET resid {args.resid}")
    if not cmds:
        ap.error("Chua chon tham so nao. Dung --ratio/--abs/--resid hoac --easy.")

    port = args.port or find_cdc_port()
    if not port:
        print("[LOI] Khong tim thay cong CDC (PID 5740). Dung --port COMx.",
              file=sys.stderr)
        sys.exit(1)

    import serial
    try:
        sp = serial.Serial(port, 115200, timeout=1)
    except Exception as e:
        print(f"[LOI] Khong mo duoc {port}: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"[OK] Gui lenh toi {port}:")
    with sp:
        for c in cmds:
            sp.write((c + "\n").encode("ascii"))
            sp.flush()
            print("   " + c)
            time.sleep(0.05)
    print("Da gui. Xem dong 'CFG ratio=.. abs=.. resid=..' tren cong VCP de xac nhan.")


if __name__ == "__main__":
    main()
