#!/usr/bin/env python3
"""Stage 5A integer golden test vectors. Needs numpy + pillow only."""
from pathlib import Path
import numpy as np
from PIL import Image
BASE = Path(__file__).resolve().parent.parent
D = BASE / 'data'
D.mkdir(parents=True, exist_ok=True)
P = Image.open(D/'cat64.png').convert('L').resize((16,16), Image.Resampling.LANCZOS)
a = np.asarray(P, dtype=np.int64)
P.save(D/'tv16_input.png')
H,W=a.shape
# Forward differences; Neumann boundary convention (zero at image outer edges).
g_x = np.zeros((H,W), np.int64)
g_y = np.zeros((H,W), np.int64)
g_x[:,:-1] = a[:,1:] - a[:,:-1]
g_y[:-1,:] = a[1:,:] - a[:-1,:]
# Deterministic independent TV dual field with both signs, 16-bit safe.
# This is a constructed test vector, NOT an output of a TV-FISTA iteration.
p_x = (g_x*20).astype(np.int64)
p_y = (g_y*20).astype(np.int64)
assert np.max(abs(p_x)) < 2048 and np.max(abs(p_y)) < 2048
# Negative adjoint divergence: px(c)-px(c-1)+py(r)-py(r-1)
div = p_x + p_y
div[:,1:] -= p_x[:,:-1]
div[1:,:] -= p_y[:-1,:]
assert np.all(p_x[:,-1]==0) and np.all(p_y[-1,:]==0)
dot_gp = int(np.sum(g_x*p_x + g_y*p_y))
dot_xdiv = int(np.sum(a*div))
assert dot_gp+dot_xdiv == 0

def put(name,arr,bits):
    values = arr.reshape(-1).tolist()
    assert all(-(1<<(bits-1)) <= int(v) < (1<<(bits-1)) for v in values) if name!='tv16_pixels' else all(0 <= v<=255 for v in values)
    width = (bits+3)//4
    with (D/(name+'.mem')).open('w',encoding='ascii') as f:
        for v in values: f.write(f'{int(v) & ((1<<bits)-1):0{width}x}\n')
    # Decode the emitted HEX bytes as a signed representation: exact round-trip.
    read = [int(q.strip(),16) for q in (D/(name+'.mem')).read_text().splitlines()]
    if name != 'tv16_pixels':
        read = [v-(1<<bits) if v&(1<<(bits-1)) else v for v in read]
    assert read == values
    assert len(values)==256
put('tv16_pixels',a,8)
put('tv16_px',p_x,12)
put('tv16_py',p_y,12)
put('tv16_expected_gx',g_x,10)
put('tv16_expected_gy',g_y,10)
put('tv16_expected_div',div,16)
report = f'''Stage 5A | TV gradient/divergence integer reference
Image: included cat64.png resized to 16x16 grayscale
Domain: 8-bit pixels; signed 12-bit constructed dual field
Vector count: {H*W}; width={W}; height={H}
Definitions:
  gx(r,c) = x(r,c+1)-x(r,c), last col zero
  gy(r,c) = x(r+1,c)-x(r,c), last row zero
  div(p) = px(r,c)-px(r,c-1)+py(r,c)-py(r-1), boundary terms zero
  div = negative adjoint of the forward gradient
  p=(gx,gy)*20 solely for numeric testing; this is not actual FISTA p
  <Gx,p>  = {dot_gp}
  <x,div> = {dot_xdiv}
  identity sum = {dot_gp+dot_xdiv}
  max |gx| = {np.max(abs(g_x))}; max |gy| = {np.max(abs(g_y))}; max |div| = {np.max(abs(div))}
Validation: arithmetic and six memory files checked in Python.
No RTL simulation or FPGA synthesis performed by this script.
TV proximal operator, projection, FISTA momentum and memory supply are NOT implemented.
'''
(D/'tv16_reference_report.txt').write_text(report,encoding='utf-8')
print(report)
