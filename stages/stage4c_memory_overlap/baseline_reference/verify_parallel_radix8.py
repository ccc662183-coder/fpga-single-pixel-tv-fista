# -*- coding: utf-8 -*-
"""Stage-4B verify the exact 27-bit serial vs 3-bit parallel divider.

This checks integer recurrence in software, NOT Verilog / XSim.
100,000 random norm/abs pairs + boundary cases, two independent axes.
"""
import numpy as np
rng=np.random.default_rng(20261112)
K=100_000
norm = rng.integers(2048,46342,size=K,dtype=np.uint32)
a_x = rng.integers(0,32769,size=K,dtype=np.uint32)
a_y = rng.integers(0,32769,size=K,dtype=np.uint32)
norm[:20]=np.array([2048,2049,2050,4096,8192,16384,32768,46340]*2+[2048,46340,2048,46340],dtype=np.uint32)[:20]
a_x[:20]=np.array([0,1,2047,2048,2049,32767,32768,32768]*2+[1,32768,32768,1],dtype=np.uint32)[:20]
a_y[:20]=np.array([32768,32767,2049,2048,2047,1,0,32768]*2+[32768,1,1,32768],dtype=np.uint32)[:20]

def divide(n,d,step):
    # All intermediate values fit within uint32 for this test.
    dividend = n.copy()
    rem=np.zeros_like(dividend)
    quo=np.zeros_like(dividend)
    for i in range(27//step):
        bits=np.zeros_like(dividend)
        for j in range(step):
            trial=(rem<<np.uint32(1)) | ((dividend >> np.uint32(26-j)) & 1)
            take=(trial>=d).astype(np.uint32)
            rem=trial-take*d
            bits=(bits<<np.uint32(1))|take
        dividend=(dividend << np.uint32(step)) & np.uint32((1<<27)-1)
        quo=(quo << np.uint32(step)) | bits
    return quo,rem

for name,abs_value in [('X',a_x),('Y',a_y)]:
    numerator=(abs_value<<np.uint32(11))+(norm>>np.uint32(1))
    q1,r1=divide(numerator,norm,1)
    q3,r3=divide(numerator,norm,3)
    assert np.array_equal(q1,q3),f'{name}: quotient mismatches'
    assert np.array_equal(r1,r3),f'{name}: remainder mismatches'
    assert np.array_equal(q3,numerator//norm),f'{name}: mathematical quotient mismatches'
    assert np.array_equal(r3,numerator%norm),f'{name}: remainder mismatches'
    assert np.array_equal(np.minimum(q1,2048),np.minimum(q3,2048)),f'{name}: clamp mismatch'
    print(f'[PASS] {name}: {K}/{K} radix-8 exact quotient, remainder, saturation')
print('[PASS] Both axes; 27 serial bits = nine groups of 3 bits.')
print('[INFO] Software recurrence only. Run Vivado 2048-vector A/B regression next.')
