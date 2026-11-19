# -*- coding: utf-8 -*-
"""Exhaustively verify the Stage-4A 4-bits/cycle unsigned divide-by-5 recurrence.

This is a software recurrence check, not a Verilog/XSim simulation.
Covers every possible 18-bit absolute gradient input (262144 values).
Requires numpy (already installed for Stage-0.2).
"""
import numpy as np

absgrad = np.arange(1 << 18, dtype=np.uint32)
numerator = absgrad * np.uint32(64)
dividend = numerator.copy()
quotient = np.zeros_like(dividend)
remainder = np.zeros_like(dividend)

for cycle in range(6):
    nibble = np.zeros_like(dividend)
    for j in range(4):
        trial = (remainder << 1) | ((dividend >> np.uint32(23 - j)) & 1)
        take = (trial >= 5).astype(np.uint32)
        remainder = trial - 5 * take
        nibble = (nibble << 1) | take
    quotient = (quotient << 4) | nibble
    dividend = (dividend << 4) & np.uint32(0xFFFFFF)

expect_quotient = numerator // 5
expect_remainder = numerator % 5

assert np.array_equal(quotient, expect_quotient), "Quotient mismatch"
assert np.array_equal(remainder, expect_remainder), "Remainder mismatch"

print("[PASS] 262144/262144 18-bit magnitudes: radix-16 /5 = integer floor(/5)")
print("[PASS] exact quotient and remainder; 6 cycles replaces 24 cycles")
print("[INFO] This does NOT replace Vivado RTL functional simulation.")
