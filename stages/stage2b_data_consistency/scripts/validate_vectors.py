#!/usr/bin/env python3
"""Standalone check of supplied Stage-2B integer golden vectors (numpy only)."""
from pathlib import Path
import numpy as np
root=Path(__file__).resolve().parents[1]
data=root/'data'

def rd(name,bits):
    a=np.array([int(s,16) for s in (data/name).read_text().splitlines() if s.strip()],dtype=np.int64)
    a[a >= (1<<(bits-1))]-=1<<bits
    return a

def fwht(x):
    a=x.astype(np.int64).copy(); step=1
    while step < len(a):
        b=a.reshape(-1,2,step)
        low=b[:,0,:].copy(); high=b[:,1,:].copy()
        b[:,0,:]=low+high; b[:,1,:]=low-high
        step*=2
    return a
mask=rd('mask_4096_rowmajor.mem',4).astype(bool)
y=rd('measurements_1024_q11_s32.mem',32)
assert len(mask)==4096 and int(mask.sum())==1024 and len(y)==1024
full=np.zeros(4096,dtype=np.int64); full[mask]=y
for name in ['direct','original','perturbed','zero']:
    z=rd(f'input_{name}_q11_s16.mem',16)
    expected=rd(f'expected_{name}_q11_s16.mem',16)
    c=fwht(z)>>6
    residual=np.where(mask,c-full,0)
    adj=fwht(residual)>>6
    actual=z-adj
    assert np.array_equal(actual,expected), f'{name}: golden reference mismatch'
    assert np.max(np.abs(fwht(z)))<2**31
    assert np.max(np.abs(fwht(residual)))<2**31
    assert np.all((-32768<=actual)&(actual<=32767))
    print(f'[PASS] {name}: 4096/4096; sum={int(actual.sum())}; residual_nnz={int(np.count_nonzero(residual))}')
print('[PASS] Stage-2B Python golden vector checks; 4 cases / 16384 pixels')
