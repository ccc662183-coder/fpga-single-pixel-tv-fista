#!/usr/bin/env python3
"""Check the Stage-3 memory vectors and source-derived summary values."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"

def signed_hex(path: Path, width: int):
    values = []
    for line in path.read_text(encoding="ascii").splitlines():
        line = line.strip()
        if not line:
            continue
        value = int(line, 16)
        if value & (1 << (width - 1)):
            value -= 1 << width
        values.append(value)
    return values

summary = json.loads((DATA / "golden_summary.json").read_text(encoding="utf-8"))
mask = [int(x, 16) for x in (DATA / "mask_4096_rowmajor.mem").read_text().splitlines()]
beta = [int(x, 16) for x in (DATA / "fista_beta_q15.hex").read_text().splitlines()]
measurements = signed_hex(DATA / "cat64_measurements_q11_s32.mem", 32)
direct = signed_hex(DATA / "cat64_expected_initial_direct_q11_s16.mem", 16)
projected = signed_hex(DATA / "cat64_expected_iter1_projected_q11_s16.mem", 16)
iter1 = signed_hex(DATA / "cat64_expected_iter1_q11_s16.mem", 16)
final = signed_hex(DATA / "cat64_expected_final_q11_s16.mem", 16)

assert len(mask) == 4096 and sum(mask) == 1024
assert len(beta) == 40 and beta == summary["beta_q15"]
assert len(measurements) == 1024
assert len(direct) == len(projected) == len(iter1) == len(final) == 4096
assert (min(direct), max(direct), sum(direct)) == (76, 1565, 3928507)
assert (min(projected), max(projected), sum(projected)) == (77, 1565, 3932630)
assert (min(iter1), max(iter1), sum(iter1)) == (108, 1530, 3930561)
assert beta[0] == 0
assert (min(final), max(final), sum(final)) == (81, 1526, 3930589)

for image in ("moon", "rocket", "text"):
    assert len(signed_hex(DATA / f"{image}_measurements_q11_s32.mem", 32)) == 1024
    assert len(signed_hex(DATA / f"{image}_expected_final_q11_s16.mem", 16)) == 4096

print("PASS: fixed mask 1024/4096")
print("PASS: beta ROM 40/40 exact")
print("PASS: cat64 initialization, iteration-1, and final vectors: all lengths and checksums match")
print("PASS: moon/rocket/text measurement and final vectors: 1024/4096 each")
print("ALL TESTS PASSED: Stage-3 reference vector package")
