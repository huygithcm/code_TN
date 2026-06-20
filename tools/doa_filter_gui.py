#!/usr/bin/env python3
"""
doa_filter_gui.py - Chinh clap-gate DOA + TEST SERVO bang NUT NHAN / THANH TRUOT.

Gui toi board qua cong USB CDC (VID 0483 PID 5740):
  - "SET ratio/abs/resid <v>" : chinh nguong clap-gate (firmware bao "CFG ..." VCP).
  - "SERVO <deg>"             : xoay servo camera truc tiep (test, doc lap DOA).
Muc "Servo camera": keo thanh truot / bam nut goc nhanh / "Quet test" sweep 0<->180
de kiem tra servo co di dung goc & giu yen khong (xem servo_test.py cho ban CLI).

Cai dat:  pip install pyserial      (tkinter co san trong Python)

Chay:     python tools/doa_filter_gui.py
"""
import sys
import tkinter as tk
from tkinter import ttk, messagebox


def find_cdc_port():
    from serial.tools import list_ports
    for p in list_ports.comports():
        if p.vid == 0x0483 and p.pid == 0x5740:
            return p.device
    return None


# (ten tham so, nhan, min, max, buoc, mac dinh)
PARAMS = [
    ("ratio", "ratio  (clap > ratio x nen nhieu)", 1.0, 6.0, 0.1, 1.8),
    ("abs",   "abs    (nguong tuyet doi)",         0.0, 0.005, 0.0001, 0.0005),
    ("resid", "resid  (nguong khop toi da)",       0.1, 1.0, 0.05, 0.7),
]

PRESETS = {
    "De bat (easy)": {"ratio": 1.5, "abs": 0.0002, "resid": 0.9},
    "Mac dinh":      {"ratio": 1.8, "abs": 0.0005, "resid": 0.7},
    "Nghiem (it nhieu)": {"ratio": 3.0, "abs": 0.001, "resid": 0.5},
}


class App:
    def __init__(self, root):
        self.root = root
        self.sp = None
        root.title("DOA clap-gate - chinh bang nut nhan")
        root.resizable(False, False)

        frm = ttk.Frame(root, padding=12)
        frm.grid(sticky="nsew")

        # --- hang cong ket noi ---
        top = ttk.Frame(frm)
        top.grid(row=0, column=0, columnspan=3, sticky="we", pady=(0, 8))
        ttk.Label(top, text="Cong CDC:").pack(side="left")
        self.port_var = tk.StringVar(value=find_cdc_port() or "(khong thay)")
        ttk.Entry(top, textvariable=self.port_var, width=14).pack(side="left", padx=4)
        ttk.Button(top, text="Ket noi", command=self.connect).pack(side="left")
        ttk.Button(top, text="Do lai", command=self.rescan).pack(side="left", padx=4)

        # --- thanh truot tung tham so ---
        self.vars = {}
        self.val_lbls = {}
        for i, (key, label, lo, hi, step, default) in enumerate(PARAMS, start=1):
            ttk.Label(frm, text=label).grid(row=i, column=0, sticky="w", pady=4)
            var = tk.DoubleVar(value=default)
            self.vars[key] = var
            scale = tk.Scale(frm, from_=lo, to=hi, resolution=step, orient="horizontal",
                             length=240, variable=var, showvalue=False,
                             command=lambda _v, k=key: self._refresh_label(k))
            scale.grid(row=i, column=1, padx=6)
            lbl = ttk.Label(frm, text=self._fmt(key, default), width=8)
            lbl.grid(row=i, column=2, sticky="e")
            self.val_lbls[key] = lbl
            ttk.Button(frm, text="Gui", width=5,
                       command=lambda k=key: self.send_one(k)).grid(row=i, column=3, padx=4)

        # --- nut gui tat ca + preset ---
        br = ttk.Frame(frm)
        br.grid(row=len(PARAMS) + 1, column=0, columnspan=4, sticky="we", pady=(10, 4))
        ttk.Button(br, text="GUI TAT CA", command=self.send_all).pack(side="left")
        for name in PRESETS:
            ttk.Button(br, text=name,
                       command=lambda n=name: self.apply_preset(n)).pack(side="left", padx=3)

        # --- muc test servo (lenh "SERVO <deg>", doc lap DOA) ---
        ttk.Separator(frm, orient="horizontal").grid(
            row=len(PARAMS) + 2, column=0, columnspan=4, sticky="we", pady=8)
        ttk.Label(frm, text="Servo camera (deg)").grid(
            row=len(PARAMS) + 3, column=0, sticky="w")
        self.servo_var = tk.DoubleVar(value=90.0)
        self.sweeping = False
        self._sweep_dir = 1
        tk.Scale(frm, from_=0, to=180, resolution=1, orient="horizontal", length=240,
                 variable=self.servo_var, showvalue=False,
                 command=lambda _v: self._on_servo_slide()).grid(
                     row=len(PARAMS) + 3, column=1, padx=6)
        self.servo_lbl = ttk.Label(frm, text="90", width=8)
        self.servo_lbl.grid(row=len(PARAMS) + 3, column=2, sticky="e")
        ttk.Button(frm, text="Gui", width=5, command=self.send_servo).grid(
            row=len(PARAMS) + 3, column=3, padx=4)

        sb = ttk.Frame(frm)
        sb.grid(row=len(PARAMS) + 4, column=0, columnspan=4, sticky="we", pady=(6, 0))
        for a in (0, 45, 90, 135, 180):
            ttk.Button(sb, text=f"{a}", width=4,
                       command=lambda x=a: self.goto_servo(x)).pack(side="left", padx=2)
        self.sweep_btn = ttk.Button(sb, text="Quet test", command=self.toggle_sweep)
        self.sweep_btn.pack(side="left", padx=(12, 0))

        # cong tac: servo tu xoay theo nguon am (AUTO) hay chi dieu khien tay
        self.auto_var = tk.BooleanVar(value=True)
        ttk.Checkbutton(frm, text="Xoay theo nguon am (AUTO)", variable=self.auto_var,
                        command=self.send_auto).grid(
                            row=len(PARAMS) + 5, column=0, columnspan=4, sticky="w", pady=(8, 0))

        self.status = tk.StringVar(value="Chua ket noi.")
        ttk.Label(frm, textvariable=self.status, foreground="gray").grid(
            row=len(PARAMS) + 6, column=0, columnspan=4, sticky="w", pady=(6, 0))

        self.connect()

    # ---- tien ich ----
    def _fmt(self, key, v):
        return f"{v:.4f}" if key == "abs" else f"{v:.2f}"

    def _refresh_label(self, key):
        self.val_lbls[key].config(text=self._fmt(key, self.vars[key].get()))

    def rescan(self):
        self.port_var.set(find_cdc_port() or "(khong thay)")

    def connect(self):
        import serial
        if self.sp:
            try: self.sp.close()
            except Exception: pass
            self.sp = None
        port = self.port_var.get().strip()
        if not port or port.startswith("("):
            self.status.set("Khong tim thay cong CDC. Cam board / bam 'Do lai'.")
            return
        try:
            self.sp = serial.Serial(port, 115200, timeout=1)
            self.status.set(f"Da ket noi {port}. Keo thanh truot roi bam 'Gui'.")
            self._drain()   # bat dau xa stream nhi phan de cong khong nghen
        except Exception as e:
            self.sp = None
            self.status.set(f"Loi mo {port}: {e}")

    def _drain(self):
        """Cong CDC xoi du lieu mic (RAW1...) lien tuc; neu khong doc, buffer day se
        chan lenh gui. Dinh ky vut bo input de giu cong thong."""
        if self.sp:
            try:
                self.sp.reset_input_buffer()
            except Exception:
                pass
            self.root.after(200, self._drain)

    def _write(self, cmds):
        if not self.sp:
            self.connect()
        if not self.sp:
            messagebox.showwarning("Chua ket noi", "Khong mo duoc cong CDC.")
            return False
        try:
            for c in cmds:
                self.sp.write((c + "\n").encode("ascii"))
            self.sp.flush()
            self.status.set("Da gui: " + " | ".join(cmds))
            return True
        except Exception as e:
            self.status.set(f"Loi gui: {e}")
            self.sp = None
            return False

    # ---- hanh dong ----
    def send_one(self, key):
        v = self.vars[key].get()
        self._write([f"SET {key} {v:g}"])

    def send_all(self):
        self._write([f"SET {k} {self.vars[k].get():g}" for k in self.vars])

    def apply_preset(self, name):
        for k, v in PRESETS[name].items():
            self.vars[k].set(v)
            self._refresh_label(k)
        self.send_all()

    # ---- servo ----
    def _on_servo_slide(self):
        self.servo_lbl.config(text=f"{self.servo_var.get():.0f}")

    def send_auto(self):
        self._write([f"AUTO {1 if self.auto_var.get() else 0}"])

    def send_servo(self):
        # dieu khien tay -> firmware tu tat AUTO; dong bo lai checkbox
        self.auto_var.set(False)
        self._write([f"SERVO {self.servo_var.get():.0f}"])

    def goto_servo(self, deg):
        self.servo_var.set(deg)
        self._on_servo_slide()
        self.send_servo()

    def toggle_sweep(self):
        self.sweeping = not self.sweeping
        if self.sweeping:
            self.sweep_btn.config(text="Dung")
            self._sweep_tick()
        else:
            self.sweep_btn.config(text="Quet test")

    def _sweep_tick(self):
        if not self.sweeping:
            return
        v = self.servo_var.get() + self._sweep_dir * 5
        if v >= 180:
            v, self._sweep_dir = 180, -1
        elif v <= 0:
            v, self._sweep_dir = 0, 1
        self.servo_var.set(v)
        self._on_servo_slide()
        self.send_servo()
        self.root.after(40, self._sweep_tick)   # ~quet muot, khong block GUI


def main():
    try:
        import serial  # noqa: F401
    except ImportError:
        print("Can pyserial: pip install pyserial", file=sys.stderr)
        sys.exit(1)
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
