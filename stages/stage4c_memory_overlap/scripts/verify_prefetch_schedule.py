# -*- coding: utf-8 -*-
"""Checks Stage-4C prefetch schedule + signed Q5.11 U/F output formula.
This validates a Python schedule model, NOT Verilog/XSim or FPGA timing.
"""
import numpy as np
N=4096
rng=np.random.default_rng(20261112)

def s16(x):
    return ((int(x)+32768)&65535)-32768

def direct(f,px,py):
    out=[]
    for i in range(N):
        row,col=divmod(i,64)
        prev_x=int(px[i-64]) if row else 0
        prev_y=int(py[i-1]) if col else 0
        d=int(px[i])+int(py[i])-prev_x-prev_y
        out.append(s16(int(f[i])+((d*20)>>11)))
    return out

def staged(f,px,py):
    # read-cur first pixel; after each write prefetch next pixel
    f_dout,px_dout,py_dout = int(f[0]),int(px[0]),int(py[0])
    out=[]
    for i in range(N):
        # S_{U,F}_READ_PREV: capture prefetched current; issue prev reads
        f_hold, px_cur, py_cur=f_dout,px_dout,py_dout
        row,col=divmod(i,64)
        px_dout=int(px[i-64]) if row else int(px[i])
        py_dout=int(py[i-1]) if col else int(py[i])
        # S_{U,F}_CAPTURE_PREV: compute 18-bit signed divergence
        d=px_cur+py_cur-(px_dout if row else 0)-(py_dout if col else 0)
        # S_{U,F}_WRITE: compute 32-bit weighted term & write result,
        # while f/px/py BRAMs fetch next index
        out.append(s16(f_hold+((d*20)>>11)))
        if i != N-1:
            f_dout,px_dout,py_dout=int(f[i+1]),int(px[i+1]),int(py[i+1])
    return out

for case in range(8):
    f=rng.integers(-32768,32768,N,endpoint=False,dtype=np.int32)
    px=rng.integers(-2048,2049,N,endpoint=False,dtype=np.int32)
    py=rng.integers(-2048,2049,N,endpoint=False,dtype=np.int32)
    assert staged(f,px,py)==direct(f,px,py),f"Mismatch case {case}"
print("[PASS] 8 x 4096 deterministic randomized Q5.11 U/F outputs identical")
print("[PASS] first/last row, first/last column addressed by each full 64x64 pass")
print("[INFO] RTL A/B testbench in Vivado is still required")
