#!/usr/bin/env python3
"""
servo_aim_mics.py - Xoay servo lan luot ve huong CAC MIC chi dinh (de dinh huong).

Dung de kiem tra/can chinh: ra lenh cho camera chi thang ve phia tung mic tren
mang (vd mic 1, 4, 7), roi mat nhin xem servo co huong dung mic do khong.

- Goc dat moi mic lay tu bang MICS trong plot_doa.py.
- Goc servo tinh bang az_to_servo() (GIONG HET firmware) -> gui lenh "SERVO <deg>".
- Tu tat AUTO truoc khi test (de DOA khong gianh servo), bat lai khi thoat.

Mac dinh xoay theo dung thu tu VAT LY chieu kim dong ho (CW) tren board, bat dau
mic 1: 1 -> 7 -> 5 -> 3 -> 2 -> 8 -> 6 -> 4. Mapping (SERVO_AZ_CENTER=0, DIR=-1):
    mic 1 -> az   0 -> servo  90   (chinh dien)
    mic 7 -> az 315 -> servo 135
    mic 5 -> az 270 -> servo 180   (bien phai)
    mic 3 -> az 225 -> servo 180*  (sau lung -> kep bien)
    mic 2 -> az 180 -> servo   0*  (sau lung -> kep bien)
    mic 8 -> az 135 -> servo   0*  (sau lung -> kep bien)
    mic 6 -> az  90 -> servo   0   (bien trai)
    mic 4 -> az  45 -> servo  45
  (* servo 180 deg chi phu nua vong truoc; mic sau lung kep ve bien gan nhat)

Cai dat:  pip install pyserial
Chay:
    python tools/servo_aim_mics.py                 # CW 1 7 5 3 2 8 6 4, lap lai
    python tools/servo_aim_mics.py 1 7 5           # chi nua vong truoc voi toi
    python tools/servo_aim_mics.py --once          # chay 1 luot roi dung
    python tools/servo_aim_mics.py --port COM7 --dwell 2.0
"""
import argparse
import importlib.util
import os
import sys
import time

# --- nap plot_doa.py (cung thu muc) de dung MICS + az_to_servo, giu DONG BO ---
_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("plot_doa", os.path.join(_HERE, "plot_doa.py"))
plot_doa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(plot_doa)

# board so mic -> goc dat (deg).  MICS phan tu = (goc, so_board, kenh_fw)
MIC_AZ = {board: ang for (ang, board, ch) in plot_doa.MICS}


def find_cdc_port():
    """Cong USB CDC cua firmware (VID 0483 PID 5740) - de gui lenh SERVO."""
    from serial.tools import list_ports
    for p in list_ports.comports():
        if p.vid == 0x0483 and p.pid == 0x5740:
            return p.device
    return None


def main():
    ap = argparse.ArgumentParser(description="Xoay servo ve huong cac mic.")
    # Mac dinh: di theo dung thu tu VAT LY chieu kim dong ho tren board, bat dau
    # mic 1: 1 -> 7 -> 5 -> 3 -> 2 -> 8 -> 6 -> 4 (xem bang MICS / chu thich CW).
    # Servo chi phu nua vong truoc nen cac mic sau lung (3,2,8) se kep ve bien.
    ap.add_argument("mics", nargs="*", type=int, default=[1, 7, 5, 3, 2, 8, 6, 4],
                    help="Danh sach so mic (mac dinh: thu tu CW 1 7 5 3 2 8 6 4)")
    ap.add_argument("--port", help="Cong CDC (vd COM7). Mac dinh: tu dong do.")
    ap.add_argument("--dwell", type=float, default=2.0, help="Giay giu moi mic.")
    ap.add_argument("--once", action="store_true", help="Chay 1 luot roi dung.")
    args = ap.parse_args()

    # kiem tra mic hop le + tinh san goc servo
    plan = []
    for m in args.mics:
        if m not in MIC_AZ:
            print(f"[LOI] Mic {m} khong co trong bang (chi 1..8).", file=sys.stderr)
            sys.exit(1)
        az = MIC_AZ[m]
        servo = plot_doa.az_to_servo(az)
        plan.append((m, az, servo))

    print("Ke hoach xoay (mic -> az -> servo):")
    for m, az, servo in plan:
        print(f"   mic {m}:  az {az:>3}  ->  servo {servo:.0f}")

    import serial
    port = args.port or find_cdc_port()
    if not port:
        print("[LOI] Khong thay cong CDC (VID 0483 PID 5740). Dung --port COMx.",
              file=sys.stderr)
        sys.exit(1)
    try:
        sp = serial.Serial(port, 115200, timeout=1)
    except Exception as e:
        print(f"[LOI] Khong mo duoc {port}: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"[OK] Mo {port}. Tat AUTO, bat dau xoay (Ctrl+C de dung).")
    try:
        with sp:
            sp.write(b"AUTO 0\n"); sp.flush(); time.sleep(0.3)
            while True:
                for m, az, servo in plan:
                    sp.write(f"SERVO {servo:.0f}\n".encode()); sp.flush()
                    print(f"  -> mic {m}: servo {servo:.0f} deg", flush=True)
                    time.sleep(args.dwell)
                if args.once:
                    break
    except KeyboardInterrupt:
        pass
    finally:
        # ve giua + bat lai AUTO
        try:
            with serial.Serial(port, 115200, timeout=1) as sp2:
                sp2.write(b"SERVO 90\nAUTO 1\n"); sp2.flush()
        except Exception:
            pass
        print("\nDung. Da ve 90 deg va bat lai AUTO.")


if __name__ == "__main__":
    main()
