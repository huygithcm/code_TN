#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
doa_match_live.py - Xem REALTIME buoc "so sanh bang de ra goc" cua DOA.

Doc luong USB CDC raw (RAW1, PID_5740). Moi ~1s:
  1. Tinh 4 TDOA cap doi tam (band-limited GCC-PHAT + phase-slope, khop firmware).
  2. So voi bang g_doa_table (16 huong 22.5deg): residual moi huong.
  3. Hien bang residual + huong THANG (drop-worst 1 cap nhu firmware).

Luong = mic_raw[slot] da co san polarity + doc 24-bit tu firmware, nen lag khop.

CACH DUNG:  python tools/doa_match_live.py         (tu dong tim cong)
            python tools/doa_match_live.py COM12
Phu thuoc: pyserial, numpy
"""
import sys, numpy as np
try:
    import serial, serial.tools.list_ports as list_ports
except ImportError:
    sys.exit("Thieu pyserial:  pip install pyserial numpy")

MAGIC=b"RAW1"; HDR=12; NCH=8; NSAMP=1024
PAYLOAD=NCH*NSAMP*4; FRAME=HDR+PAYLOAD
FS=16000; K=3.731778
PHI=[0,45,90,135]; AZ=np.arange(0,360,22.5)
BAND=(250,3500)
TABLE=np.array([[K*np.cos(np.deg2rad(a-p)) for p in PHI] for a in AZ])
PAIRS=[(0,1),(2,3),(4,5),(6,7)]   # slot doi tam; phi=0/45/90/135

def find_port(e=None):
    if e: return e
    for p in list_ports.comports():
        if "5740" in (p.hwid or "").upper(): return p.device
    return None

def read_frame(ser,buf):
    while True:
        while len(buf)<2*FRAME:
            c=ser.read(FRAME)
            if not c: return None
            buf.extend(c)
        i=buf.find(MAGIC)
        if i<0 or i+2*FRAME>len(buf):
            if i>0: del buf[:i]
            c=ser.read(FRAME);
            if c: buf.extend(c)
            continue
        if bytes(buf[i+FRAME:i+FRAME+4])!=MAGIC:
            del buf[:i+1]; continue
        pl=bytes(buf[i+HDR:i+FRAME]); del buf[:i+FRAME]
        return pl

def gcc_lag(a,b):
    """band-limited GCC-PHAT + phase-slope sub-sample (khop firmware)."""
    n=1
    while n<2*len(a): n*=2
    A=np.fft.rfft(a-a.mean(),n); B=np.fft.rfft(b-b.mean(),n)
    R=A*np.conj(B); f=np.fft.rfftfreq(n,1/FS)
    band=(f>=BAND[0])&(f<=BAND[1])
    Rw=np.where(band, R/(np.abs(R)+1e-9), 0.0)
    cc=np.fft.irfft(Rw,n); m=6
    seg=np.concatenate((cc[-m:],cc[:m+1])); lags=np.arange(-m,m+1)
    L=int(lags[np.argmax(seg)])
    # phase-slope refine
    kk=np.arange(n//2+1)[band]; phi=np.angle(Rw[band])
    psi=phi + 2*np.pi*kk*L/n
    psi=(psi+np.pi)%(2*np.pi)-np.pi
    d=-(np.sum(kk*psi)/ (np.sum(kk*kk)+1e-9))/(2*np.pi/n)
    d=max(-1,min(1,d))
    return L+d

def main():
    port=find_port(sys.argv[1] if len(sys.argv)>1 else None)
    if not port: sys.exit("Khong tim thay cong CDC PID_5740")
    ser=serial.Serial(port,115200,timeout=1)
    try: ser.set_buffer_size(rx_size=4*1024*1024)
    except: pass
    print(f"Doc {port} ... Ctrl+C de thoat")
    buf=bytearray(); win=[]
    try:
        while True:
            pl=read_frame(ser,buf)
            if pl is None: continue
            x=np.frombuffer(pl,dtype="<i4").astype(np.float64).reshape(NCH,NSAMP)
            if np.mean(x[4]**2)<1e4:  # bo khung qua nho
                continue
            lags=np.array([gcc_lag(x[a],x[b]) for a,b in PAIRS])
            win.append(lags)
            if len(win)<16: continue
            med=np.median(np.array(win),axis=0); win=[]
            # residual moi huong - dung ca 4 cap (mic dong nhat, khop firmware moi)
            d2=(TABLE-med)**2
            resid=d2.sum(1)
            best=int(np.argmin(resid))

            # ve bang
            lines=[]
            lines.append(f"Lag do (phase-slope): pair0={med[0]:+.2f} pair1={med[1]:+.2f} pair2={med[2]:+.2f} pair3={med[3]:+.2f}")
            lines.append("")
            lines.append(f"{'az':>6} | {'lag ky vong (bang)':^30} | resid")
            lines.append("-"*62)
            for a in range(16):
                exp=" ".join(f"{TABLE[a,k]:+5.2f}" for k in range(4))
                mark=" <== THANG" if a==best else ""
                bar="#"*int(20*max(0,1-resid[a]/(resid.max()+1e-9)))
                lines.append(f"{AZ[a]:6.1f} | {exp} | {resid[a]:6.2f} {bar}{mark}")
            lines.append("")
            lines.append(f"=> GOC RA: {AZ[best]:.1f} deg  (resid={resid[best]:.2f})")
            sys.stdout.write("\033[2J\033[H"+"\n".join(lines)+"\n")
            sys.stdout.flush()
    except KeyboardInterrupt:
        print("\nThoat.")
    finally:
        ser.close()

if __name__=="__main__":
    main()
