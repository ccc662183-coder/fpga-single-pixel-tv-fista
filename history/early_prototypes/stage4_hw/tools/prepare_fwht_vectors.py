#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stage-4 integer FWHT verification vectors. Simulated photographic image, not optical acquisition."""
from pathlib import Path
from PIL import Image
import numpy as np
import hashlib

ROOT = Path(__file__).resolve().parents[1]
IMG = ROOT / 'data' / 'cat64.png'
OUT = ROOT / 'data'
SIDE=64
N=SIDE*SIDE

def fwht_inplace_i64(x):
    a=np.asarray(x,dtype=np.int64).reshape(-1).copy()
    h=1
    while h < a.size:
        b=a.reshape(-1,2,h)
        lo=b[:,0,:].copy()
        hi=b[:,1,:].copy()
        b[:,0,:]=lo+hi
        b[:,1,:]=lo-hi
        h*=2
    return a

def save_mem(path,array):
    vals=np.asarray(array,dtype=np.int64).reshape(-1)
    assert vals.size==N and vals.min() >= -(2**31) and vals.max() < 2**31
    with path.open('w',encoding='ascii',newline='\n') as f:
        for v in vals:
            f.write(f'{(int(v)&0xFFFFFFFF):08X}\n')
    return hashlib.sha256(path.read_bytes()).hexdigest()

im = Image.open(IMG).convert('L')
if im.size != (SIDE,SIDE):
    raise ValueError('cat64.png must be exactly 64x64')
raw=np.asarray(im,dtype=np.uint8).astype(np.int64).reshape(-1)
coeff=fwht_inplace_i64(raw)
back=fwht_inplace_i64(coeff)
assert np.array_equal(back,raw*N)
assert np.array_equal((back//N),raw)
# independent reference: test 2-D two-axis butterflies on 64x64 matrix
def axis_transform(x,axis):
    a=np.swapaxes(x,axis,-1).copy()
    step=1
    while step<64:
        b=a.reshape(*a.shape[:-1],64//(2*step),2,step)
        low=b[...,0,:].copy();high=b[...,1,:].copy()
        b[...,0,:]=low+high;b[...,1,:]=low-high
        step*=2
    return np.swapaxes(a,axis,-1)
coeff_2d=axis_transform(axis_transform(raw.reshape(64,64),1),0).reshape(-1)
assert np.array_equal(coeff,coeff_2d), '1-D flat transform does not match 2-D!'
h1=save_mem(OUT/'fwht64_input.mem',raw)
h2=save_mem(OUT/'fwht64_expected.mem',coeff)
text=(
    'STAGE 4: INTEGER FWHT SOFTWARE REFERENCE ONLY (NOT FPGA SIMULATION)\n'
    'Source image: cat64.png; 64x64 8-bit gray, derived from held-out cat photo\n'
    'Measurement: synthetic / mathematical Hadamard transform; NOT optical data\n'
    'Vector length: 4096 (64x64); output: 32-bit signed two-complement hex\n'
    'Transform: unnormalized Sylvester FWHT on row-major flattened image\n'
    'Equivalence: 1-D 4096 FWHT == separable 2-D 64x64 FWHT, verified independently\n'
    'Round trip: FWHT(FWHT(image)) = 4096 * image (exact integer)\n'
    f'Input range: {raw.min()}..{raw.max()}; coefficient range: {coeff.min()}..{coeff.max()}\n'
    f'Input data SHA256: {h1}\nExpected data SHA256: {h2}\n'
    'Expected simulation testbench output: PASS forward 4096 / 4096; PASS roundtrip 4096 / 4096\n'
    'This preparer does not run RTL; run the supplied testbench in Vivado to verify hardware logic.\n'
)
(OUT/'fwht64_reference_report.txt').write_text(text,encoding='utf-8')
print(text)
