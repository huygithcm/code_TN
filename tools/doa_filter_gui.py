#!/usr/bin/env python3
"""
doa_filter_gui.py - Chinh nguong clap-gate cua DOA bang NUT NHAN / THANH TRUOT.

Thay cho set_doa_filter.py (CLI). Gui lenh "SET ratio/abs/resid <v>" toi board
qua cong USB CDC (VID 0483 PID 5740). Firmware xac nhan bang dong "CFG ..." tren
cong VCP (xem plot_doa.py).

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

        self.status = tk.StringVar(value="Chua ket noi.")
        ttk.Label(frm, textvariable=self.status, foreground="gray").grid(
            row=len(PARAMS) + 2, column=0, columnspan=4, sticky="w", pady=(6, 0))

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
        except Exception as e:
            self.sp = None
            self.status.set(f"Loi mo {port}: {e}")

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
