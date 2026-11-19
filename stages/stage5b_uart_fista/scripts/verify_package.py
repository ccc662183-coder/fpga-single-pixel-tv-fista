#!/usr/bin/env python3
"""Stage-5B source freeze and dataset format self-check (not RTL verification)."""
from pathlib import Path
import hashlib, sys, re
ROOT=Path(__file__).resolve().parent.parent
REF=ROOT/'reference/FROZEN_STAGE4C_SHA256.txt'
entries=[line.split('  ',1) for line in REF.read_text().splitlines()]
for digest, filename in entries:
    observed=hashlib.sha256((ROOT/'rtl'/filename).read_bytes()).hexdigest()
    assert observed == digest, filename
assert len(entries)==8
print('PASS: Stage-4C 8 source modules SHA-256 match the frozen original')
# Check recorded board pin mapping and protocol constraints.
xdc=(ROOT/'constraints/stage5b_ax7020_50m_uart.xdc').read_text()
for pin in ('U18','N15','W19','W18'):
    assert re.search(r'PACKAGE_PIN\s+'+pin+r'\b',xdc),pin
print('PASS: verified AX7020 U18/N15/W19/W18 constraints copied')
from stage5b_reconstruct import self_test
self_test()
print('INFO: Verilog/XSim/synthesis/board execution must be performed in Vivado 2019.2')
