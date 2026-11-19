#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Stage 0.2: 64x64 fixed-point TV-FISTA golden model.

This model is intentionally aligned with the existing Stage-5B/5C RTL:
- signed Q5.11 primal image and TV dual variables
- lambda = 20/2048
- arithmetic right shift for lambda*divergence
- truncation toward zero for (64/5)*gradient
- integer-square-root and rounded Q11 projection
- 40 FISTA outer iterations with a UQ0.15 beta ROM
- 35 TV dual/Jacobi inner iterations

The Hadamard operator is H_4096 / 64. FWHT data remains signed 32-bit
with 11 fractional bits; normalization is an arithmetic shift right by 6.

This is a PC reference model, not FPGA execution.
"""
from __future__ import annotations
import csv
import math
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import stage0_reference_64 as float_ref

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "stage0_reference_64" / "data"
STAGE4 = ROOT / "legacy_vectors" / "stage4"
STAGE5B = ROOT / "legacy_vectors" / "stage5b"
STAGE5C = ROOT / "legacy_vectors" / "stage5c"
OUT = ROOT / "stage0_2_fixedpoint"
OUT_DATA = OUT / "data"
VECTORS = OUT / "vectors"

SIDE = 64
NPIX = SIDE * SIDE
MEASURE_COUNT = 1024
FRAC = 11
ONE = 1 << FRAC
LAM_Q11 = 20
OUTER_ITERS = 40
TV_INNER_ITERS = 35
BETA_FRAC = 15

def fwht_axis_int(values: np.ndarray, axis: int) -> np.ndarray:
    a = np.swapaxes(np.asarray(values, dtype=np.int64), axis, -1).copy()
    n = a.shape[-1]
    if n <= 0 or (n & (n - 1)):
        raise ValueError("FWHT length must be a power of two")
    step = 1
    while step < n:
        b = a.reshape(*a.shape[:-1], n // (2 * step), 2, step)
        lo = b[..., 0, :].copy()
        hi = b[..., 1, :].copy()
        b[..., 0, :] = lo + hi
        b[..., 1, :] = lo - hi
        step *= 2
    return np.swapaxes(a, axis, -1)

def fwht2_int(x: np.ndarray) -> np.ndarray:
    if np.asarray(x).shape != (SIDE, SIDE):
        raise ValueError("Expected 64x64 array")
    return fwht_axis_int(fwht_axis_int(np.asarray(x, dtype=np.int64), 1), 0)

def mask_low_sequency() -> np.ndarray:
    # Preserve Stage-0.1's exact mask construction.
    return float_ref.make_low_sequency_mask(SIDE, MEASURE_COUNT)

def wrap16(a: np.ndarray) -> np.ndarray:
    a = np.asarray(a, dtype=np.int64)
    u = np.bitwise_and(a, 0xFFFF)
    return np.where(u >= 0x8000, u - 0x10000, u).astype(np.int64)

def proj_q11_array(vx: np.ndarray, vy: np.ndarray):
    """Bit-accurate integer model of tv_dual_project_q11.v."""
    vx = np.asarray(vx, dtype=np.int64)
    vy = np.asarray(vy, dtype=np.int64)
    s = vx * vx + vy * vy
    ox = vx.copy()
    oy = vy.copy()
    outside = s > ONE * ONE
    if np.any(outside):
        so = s[outside]
        # sqrt is exact enough in float64 for these <= 2^31 operands;
        # correction enforces floor(sqrt(integer)) exactly.
        norm = np.floor(np.sqrt(so.astype(np.float64))).astype(np.int64)
        too_high = norm * norm > so
        norm[too_high] -= 1
        too_low = (norm + 1) * (norm + 1) <= so
        norm[too_low] += 1
        ax = np.abs(vx[outside])
        ay = np.abs(vy[outside])
        qx = np.minimum(ONE, ((ax << FRAC) + (norm >> 1)) // norm)
        qy = np.minimum(ONE, ((ay << FRAC) + (norm >> 1)) // norm)
        ox[outside] = np.where(vx[outside] < 0, -qx, qx)
        oy[outside] = np.where(vy[outside] < 0, -qy, qy)
    return ox, oy

def tv_prox_q11(f: np.ndarray, steps: int = TV_INNER_ITERS):
    """
    Q5.11 TV prox model matching Stage-5C arithmetic.
    Returns prox output, final dual p_x/p_y, and range/overflow telemetry.
    """
    f = np.asarray(f, dtype=np.int64)
    h, w = f.shape
    px = np.zeros((h, w), dtype=np.int64)
    py = np.zeros((h, w), dtype=np.int64)
    stats = {
        "div_abs_max": 0, "u_abs_max": 0, "grad_abs_max": 0,
        "delta_abs_max": 0, "candidate_abs_max": 0,
        "dual_abs_max": 0, "out_abs_max": 0,
        "u_overflow": 0, "candidate_overflow": 0, "out_overflow": 0,
        "div18_overflow": 0, "grad18_overflow": 0
    }
    for _ in range(steps):
        # div(p) = p_x(r,c)-p_x(r-1,c)+p_y(r,c)-p_y(r,c-1)
        div = px + py
        div = div.copy()
        div[1:, :] -= px[:-1, :]
        div[:, 1:] -= py[:, :-1]
        stats["div_abs_max"] = max(stats["div_abs_max"], int(np.max(np.abs(div))))
        stats["div18_overflow"] += int(np.count_nonzero((div < -131072) | (div > 131071)))
        if np.any((div < -131072) | (div > 131071)):
            raise OverflowError("TV divergence exceeds signed 18-bit range")

        # Stage-5C: new_u = f + ((div * 20) >>> 11)
        u = f + ((div * LAM_Q11) >> FRAC)
        stats["u_abs_max"] = max(stats["u_abs_max"], int(np.max(np.abs(u))))
        stats["u_overflow"] += int(np.count_nonzero((u < -32768) | (u > 32767)))
        if np.any((u < -32768) | (u > 32767)):
            raise OverflowError("TV u exceeds signed Q5.11")

        gx = np.zeros((h, w), dtype=np.int64)
        gy = np.zeros((h, w), dtype=np.int64)
        gx[:-1, :] = u[1:, :] - u[:-1, :]
        gy[:, :-1] = u[:, 1:] - u[:, :-1]
        stats["grad_abs_max"] = max(
            stats["grad_abs_max"],
            int(max(np.max(np.abs(gx)), np.max(np.abs(gy))))
        )
        stats["grad18_overflow"] += int(
            np.count_nonzero((gx < -131072) | (gx > 131071)) +
            np.count_nonzero((gy < -131072) | (gy > 131071))
        )
        if np.any((gx < -131072) | (gx > 131071)) or np.any((gy < -131072) | (gy > 131071)):
            raise OverflowError("TV gradient exceeds signed 18-bit range")

        # Stage-5C: truncation toward zero of gradient * 256 / 20 = gradient * 64 / 5.
        dx = (np.abs(gx) * 64) // 5
        dy = (np.abs(gy) * 64) // 5
        dx = np.where(gx < 0, -dx, dx)
        dy = np.where(gy < 0, -dy, dy)
        stats["delta_abs_max"] = max(
            stats["delta_abs_max"],
            int(max(np.max(np.abs(dx)), np.max(np.abs(dy))))
        )

        vx = px + dx
        vy = py + dy
        vx[-1, :] = 0  # p_x is zero on the last row
        vy[:, -1] = 0  # p_y is zero on the last column
        stats["candidate_abs_max"] = max(
            stats["candidate_abs_max"],
            int(max(np.max(np.abs(vx)), np.max(np.abs(vy))))
        )
        stats["candidate_overflow"] += int(
            np.count_nonzero((vx < -32768) | (vx > 32767)) +
            np.count_nonzero((vy < -32768) | (vy > 32767))
        )
        if np.any((vx < -32768) | (vx > 32767)) or np.any((vy < -32768) | (vy > 32767)):
            raise OverflowError("TV projection candidate exceeds signed Q5.11")

        # Jacobi update: all new duals are computed from the old p_x/p_y.
        px, py = proj_q11_array(vx, vy)
        stats["dual_abs_max"] = max(
            stats["dual_abs_max"],
            int(max(np.max(np.abs(px)), np.max(np.abs(py))))
        )

    div = px + py
    div = div.copy()
    div[1:, :] -= px[:-1, :]
    div[:, 1:] -= py[:, :-1]
    out = f + ((div * LAM_Q11) >> FRAC)
    stats["out_abs_max"] = int(np.max(np.abs(out)))
    stats["out_overflow"] = int(np.count_nonzero((out < -32768) | (out > 32767)))
    if stats["out_overflow"]:
        raise OverflowError("TV prox output exceeds signed Q5.11")
    return out, px, py, stats

def make_beta_q15(count: int = OUTER_ITERS) -> np.ndarray:
    """Precompute FISTA beta_k=(t_(k-1)-1)/t_k as unsigned Q0.15 ROM."""
    t = 1.0
    beta = []
    for _ in range(count):
        t_new = (1.0 + math.sqrt(1.0 + 4.0 * t * t)) / 2.0
        b = (t - 1.0) / t_new
        beta.append(int(math.floor(b * (1 << BETA_FRAC) + 0.5)))
        t = t_new
    return np.asarray(beta, dtype=np.int64)

def load_u8(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        return np.asarray(im.convert("L").resize((SIDE, SIDE), Image.Resampling.LANCZOS), dtype=np.int64)

def fista_q11(image_u8: np.ndarray, mask: np.ndarray):
    image_u8 = np.asarray(image_u8, dtype=np.int64)
    # Round-to-nearest conversion from uint8 [0,255] to Q5.11 [0,1].
    xq = (image_u8 * ONE + 127) // 255
    raw_coeff = fwht2_int(xq)
    raw_fwht_abs_max = int(np.max(np.abs(raw_coeff)))
    if raw_fwht_abs_max >= (1 << 31):
        raise OverflowError("Forward FWHT exceeds signed 32-bit range")

    # W=H_4096/64. Arithmetic >>>6 is floor for negative values.
    coeff_q11 = raw_coeff >> 6
    y = np.where(mask, coeff_q11, 0)
    direct_raw = fwht2_int(y)
    direct_fwht_abs_max = int(np.max(np.abs(direct_raw)))
    if direct_fwht_abs_max >= (1 << 31):
        raise OverflowError("Direct reconstruction FWHT exceeds signed 32-bit range")
    direct = direct_raw >> 6
    if np.any((direct < -32768) | (direct > 32767)):
        raise OverflowError("Direct initialization exceeds signed Q5.11")

    x = direct.copy()
    z = x.copy()
    beta_q15 = make_beta_q15(OUTER_ITERS)
    outer_stats = []
    tv_stats = []
    for k in range(OUTER_ITERS):
        fwht_raw = fwht2_int(z)
        fwht_abs = int(np.max(np.abs(fwht_raw)))
        if fwht_abs >= (1 << 31):
            raise OverflowError("Forward FWHT iteration exceeds signed 32-bit range")
        c = fwht_raw >> 6
        residual = np.where(mask, c - y, 0)
        residual_abs = int(np.max(np.abs(residual)))
        if residual_abs >= (1 << 31):
            raise OverflowError("Measurement residual exceeds signed 32-bit range")
        adj_raw = fwht2_int(residual)
        adj_abs = int(np.max(np.abs(adj_raw)))
        if adj_abs >= (1 << 31):
            raise OverflowError("Adjoint FWHT exceeds signed 32-bit range")
        grad = adj_raw >> 6
        projected = z - grad
        if np.any((projected < -32768) | (projected > 32767)):
            raise OverflowError("Gradient step exceeds signed Q5.11")
        x_new, px, py, tv_range = tv_prox_q11(projected, TV_INNER_ITERS)

        momentum_product = (x_new - x) * int(beta_q15[k])
        momentum_delta = momentum_product >> BETA_FRAC
        z_new = x_new + momentum_delta
        if np.any((z_new < -32768) | (z_new > 32767)):
            raise OverflowError("FISTA extrapolation exceeds signed Q5.11")

        outer_stats.append({
            "iteration": k + 1,
            "forward_fwht_raw_abs_max": fwht_abs,
            "residual_abs_max": residual_abs,
            "adjoint_fwht_raw_abs_max": adj_abs,
            "projected_min": int(projected.min()),
            "projected_max": int(projected.max()),
            "x_min": int(x_new.min()),
            "x_max": int(x_new.max()),
            "z_min": int(z_new.min()),
            "z_max": int(z_new.max()),
            "momentum_product_abs_max": int(np.max(np.abs(momentum_product))),
            "momentum_delta_abs_max": int(np.max(np.abs(momentum_delta))),
            "beta_q15": int(beta_q15[k])
        })
        tv_stats.append(tv_range)
        x, z = x_new, z_new

    final_q11 = np.clip(x, 0, ONE)
    direct_q11 = np.clip(direct, 0, ONE)
    return {
        "image_q11": xq,
        "raw_fwht_q11": raw_coeff,
        "coeff_q11_full": coeff_q11,
        "measurements_q11_full": y,
        "direct_q11": direct_q11,
        "reconstruction_q11": final_q11,
        "outer_stats": outer_stats,
        "tv_stats": tv_stats,
        "beta_q15": beta_q15,
        "raw_fwht_abs_max": raw_fwht_abs_max,
        "direct_fwht_abs_max": direct_fwht_abs_max
    }

def parse_signed_hex(path: Path, width: int):
    vals = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        v = int(line, 16)
        if v & (1 << (width - 1)):
            v -= 1 << width
        vals.append(v)
    return np.asarray(vals, dtype=np.int64)

def write_hex(path: Path, values, width: int):
    path.parent.mkdir(parents=True, exist_ok=True)
    digits = width // 4
    mask = (1 << width) - 1
    with path.open("w", encoding="ascii", newline="\n") as f:
        for value in np.asarray(values).reshape(-1):
            f.write(f"{int(value) & mask:0{digits}x}\n")

def psnr(reference: np.ndarray, test: np.ndarray) -> float:
    mse = float(np.mean((reference - test) ** 2))
    return float("inf") if mse == 0 else 10.0 * math.log10(1.0 / mse)

def make_comparison_panel(name: str, image_u8, direct_q11, fixed_q11, float_tv):
    # Four panels: original, direct Q11, fixed TV-FISTA, float TV-FISTA.
    panels = []
    panels.append(("Original", image_u8.astype(np.uint8)))
    panels.append(("Direct Q5.11", np.clip(direct_q11 / ONE * 255.0, 0, 255).astype(np.uint8)))
    panels.append(("Fixed TV-FISTA", np.clip(fixed_q11 / ONE * 255.0, 0, 255).astype(np.uint8)))
    panels.append(("Float TV-FISTA", np.clip(float_tv * 255.0, 0, 255).astype(np.uint8)))
    scale = 3
    tile_w = SIDE * scale
    label_h = 28
    margin = 12
    canvas = Image.new("RGB", (margin + 2 * (tile_w + margin), margin + 2 * (tile_w + label_h + margin)), "white")
    draw = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype("arial.ttf", 16)
    except OSError:
        font = ImageFont.load_default()
    for idx, (label, arr) in enumerate(panels):
        r, c = divmod(idx, 2)
        x0 = margin + c * (tile_w + margin)
        y0 = margin + r * (tile_w + label_h + margin)
        draw.text((x0, y0), label, fill="black", font=font)
        im = Image.fromarray(arr, mode="L").resize((tile_w, tile_w), Image.Resampling.NEAREST).convert("RGB")
        canvas.paste(im, (x0, y0 + label_h))
    path = OUT / f"{name}_fixedpoint_comparison.png"
    canvas.save(path)

def run_legacy_checks():
    # Stage-4: original 8-bit cat64 FWHT, exact 4096-coefficient cross-check.
    input_mem = parse_signed_hex(STAGE4 / "fwht64_input.mem", 32).reshape(64, 64)
    expected = parse_signed_hex(STAGE4 / "fwht64_expected.mem", 32).reshape(64, 64)
    actual = fwht2_int(input_mem)
    stage4_pass = bool(np.array_equal(actual, expected))

    # Stage-5B: 128 independent Q5.11 projection vectors.
    ix = parse_signed_hex(STAGE5B / "input_x.mem", 16)
    iy = parse_signed_hex(STAGE5B / "input_y.mem", 16)
    ex = parse_signed_hex(STAGE5B / "expected_x.mem", 16)
    ey = parse_signed_hex(STAGE5B / "expected_y.mem", 16)
    px, py = proj_q11_array(ix, iy)
    proj_pass = bool(np.array_equal(px, ex) and np.array_equal(py, ey))

    # Stage-5C: 8x8 / 3-step TV prox; exact 64-pixel comparison.
    i8 = parse_signed_hex(STAGE5C / "input_pixels.mem", 16).reshape(8, 8)
    e8 = parse_signed_hex(STAGE5C / "expected_prox.mem", 16).reshape(8, 8)
    o8, _, _, _ = tv_prox_q11(i8, steps=3)
    prox_pass = bool(np.array_equal(o8, e8))
    return {
        "stage4_pass": stage4_pass,
        "stage4_count": int(actual.size),
        "stage5b_pass": proj_pass,
        "stage5b_count": int(ix.size),
        "stage5c_pass": prox_pass,
        "stage5c_count": int(i8.size),
        "stage5c_sum": int(o8.sum()),
        "stage5c_min": int(o8.min()),
        "stage5c_max": int(o8.max())
    }

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    OUT_DATA.mkdir(parents=True, exist_ok=True)
    VECTORS.mkdir(parents=True, exist_ok=True)
    mask = mask_low_sequency()
    if int(mask.sum()) != MEASURE_COUNT:
        raise RuntimeError("Mask count is not 1024")
    indices = np.flatnonzero(mask.reshape(-1))
    (OUT_DATA / "mask_4096_rowmajor.mem").write_text(
        "".join("1\n" if b else "0\n" for b in mask.reshape(-1)), encoding="ascii"
    )
    (OUT_DATA / "measurement_indices_1024.txt").write_text(
        "\n".join(str(int(i)) for i in indices) + "\n", encoding="ascii"
    )
    beta_q15 = make_beta_q15()
    write_hex(OUT_DATA / "fista_beta_q15.hex", beta_q15, 16)
    (OUT_DATA / "numeric_contract.vh").write_text(
        "// Stage 0.2 proposed numeric contract; include only after review.\\n"
        "localparam integer PIXEL_W = 16;\\n"
        "localparam integer PIXEL_FRAC = 11; // signed Q5.11\\n"
        "localparam integer FWHT_W = 32;\\n"
        "localparam integer FWHT_FRAC = 11;\\n"
        "localparam integer FWHT_NORM_SHIFT = 6; // H_4096 / 64\\n"
        "localparam integer TV_DIV_W = 18;\\n"
        "localparam integer TV_LAMBDA_Q11 = 20; // 20/2048\\n"
        "localparam integer FISTA_BETA_FRAC = 15;\\n"
        "localparam integer FISTA_OUTER_ITERS = 40;\\n"
        "localparam integer TV_INNER_ITERS = 35;\\n",
        encoding="ascii"
    )

    legacy = run_legacy_checks()
    if not all([legacy["stage4_pass"], legacy["stage5b_pass"], legacy["stage5c_pass"]]):
        raise RuntimeError(f"Legacy cross-check failed: {legacy}")

    rows = []
    all_results = {}
    report_lines = [
        "STAGE 0.2 | 64x64 fixed-point TV-FISTA golden model",
        "====================================================",
        "Model status: PC fixed-point reference; NOT FPGA execution.",
        "Image: 64x64, 4096 pixels; row-major flattening.",
        "Measurements: 1024 / 4096 = 25%; Stage-0.1 low-sequency mask.",
        "Operator: W = H_4096 / 64; FWHT is unnormalized H, followed by arithmetic >>> 6.",
        "",
        "FIXED-POINT CONTRACT",
        "--------------------",
        "Primal image x, FISTA state x/z, TV dual p/q: signed 16-bit, 11 fractional bits (S16.F11 / Q5.11).",
        "Range of S16.F11: [-16, 15.99951171875]; 1.0 is integer 2048.",
        "FWHT work memory, normalized coefficients, measurements, residuals: signed 32-bit, 11 fractional bits (S32.F11).",
        "TV divergence / gradient intermediates: signed 18-bit or wider, 11 fractional bits; runtime range checks are enforced.",
        "TV lambda: integer 20 / 2048 = 0.009765625 (retains Stage-5C RTL convention; float baseline uses 0.01).",
        "TV u/f update: arithmetic right shift >>> 11 (floor for negative values).",
        "TV dual gradient scale: truncation toward zero of abs(grad)*64/5, then restore sign.",
        "TV projection: integer floor sqrt(vx^2+vy^2), rounded magnitude quotient, clamp vector norm to 1.0.",
        "TV dual update: Jacobi; p/q new arrays are computed from old p/q, then committed.",
        "FISTA beta: 16-bit unsigned coefficient with 15 fractional bits, beta_k=(t_(k-1)-1)/t_k; product uses arithmetic >>> 15.",
        "Input uint8 to Q5.11: round-to-nearest (pixel*2048+127)//255.",
        "Output: clip final Q5.11 image to [0, 2048], i.e. [0,1].",
        "",
        "LEGACY RTL CROSS-CHECKS",
        "-----------------------",
        f"Stage-4 FWHT: {'PASS' if legacy['stage4_pass'] else 'FAIL'} ({legacy['stage4_count']}/4096 exact coefficients).",
        f"Stage-5B projection: {'PASS' if legacy['stage5b_pass'] else 'FAIL'} ({legacy['stage5b_count']}/128 exact vectors).",
        f"Stage-5C TV prox: {'PASS' if legacy['stage5c_pass'] else 'FAIL'} ({legacy['stage5c_count']}/64 exact pixels; sum={legacy['stage5c_sum']}, min={legacy['stage5c_min']}, max={legacy['stage5c_max']}).",
        "",
        "64x64 IMAGE RESULTS",
        "-------------------"
    ]

    for name in ["cat64", "moon", "rocket", "text"]:
        image_u8 = load_u8(DATA / f"{name}.png")
        image_f = image_u8.astype(np.float64) / 255.0
        result = fista_q11(image_u8, mask)
        all_results[name] = result
        coeff_f = float_ref.fwht2(image_f)
        direct_f, tv_f = float_ref.tv_fista(coeff_f, mask)
        direct_q = result["direct_q11"].astype(np.float64) / ONE
        fixed_q = result["reconstruction_q11"].astype(np.float64) / ONE

        direct_psnr_float = psnr(image_f, direct_f)
        tv_psnr_float = psnr(image_f, tv_f)
        direct_psnr_fixed = psnr(image_f, direct_q)
        tv_psnr_fixed = psnr(image_f, fixed_q)
        max_err = float(np.max(np.abs(fixed_q - tv_f)))
        rmse_err = float(np.sqrt(np.mean((fixed_q - tv_f) ** 2)))
        overflow_total = sum(
            t["u_overflow"] + t["candidate_overflow"] + t["out_overflow"] +
            t["div18_overflow"] + t["grad18_overflow"]
            for t in result["tv_stats"]
        )
        if overflow_total != 0:
            raise RuntimeError(f"{name}: Q5.11 overflow detected")
        if max_err > 0.02:
            raise RuntimeError(f"{name}: fixed-vs-float error unexpectedly high: {max_err}")

        rows.append({
            "image": name,
            "direct_float_psnr_db": direct_psnr_float,
            "tv_float_psnr_db": tv_psnr_float,
            "direct_fixed_psnr_db": direct_psnr_fixed,
            "tv_fixed_psnr_db": tv_psnr_fixed,
            "fixed_gain_db": tv_psnr_fixed - direct_psnr_fixed,
            "fixed_vs_float_max_abs_error": max_err,
            "fixed_vs_float_rmse": rmse_err,
            "max_fwht_raw_abs": max(
                result["raw_fwht_abs_max"],
                max(r["forward_fwht_raw_abs_max"] for r in result["outer_stats"]),
                max(r["adjoint_fwht_raw_abs_max"] for r in result["outer_stats"])
            ),
            "max_tv_div_abs_q11": max(t["div_abs_max"] for t in result["tv_stats"]),
            "max_tv_u_abs_q11": max(t["u_abs_max"] for t in result["tv_stats"]),
            "max_tv_grad_abs_q11": max(t["grad_abs_max"] for t in result["tv_stats"]),
            "max_tv_delta_abs_q11": max(t["delta_abs_max"] for t in result["tv_stats"]),
            "max_tv_candidate_abs_q11": max(t["candidate_abs_max"] for t in result["tv_stats"]),
            "max_tv_dual_abs_q11": max(t["dual_abs_max"] for t in result["tv_stats"]),
            "max_momentum_product_abs": max(t["momentum_product_abs_max"] for t in result["outer_stats"]),
            "overflow_count": overflow_total
        })

        vdir = VECTORS / name
        vdir.mkdir(parents=True, exist_ok=True)
        write_hex(vdir / "input_image_q11_s16.hex", result["image_q11"], 16)
        write_hex(vdir / "measurements_q11_s32.hex",
                  result["measurements_q11_full"].reshape(-1)[indices], 32)
        write_hex(vdir / "direct_reconstruction_q11_s16.hex", result["direct_q11"], 16)
        write_hex(vdir / "tv_fista_reconstruction_q11_s16.hex", result["reconstruction_q11"], 16)
        np.savez_compressed(
            vdir / "golden_vectors.npz",
            image_u8=image_u8,
            image_q11=result["image_q11"],
            mask=mask,
            measurement_indices=indices,
            measurements_q11=result["measurements_q11_full"].reshape(-1)[indices],
            direct_q11=result["direct_q11"],
            reconstruction_q11=result["reconstruction_q11"],
            float_tv=tv_f
        )
        make_comparison_panel(name, image_u8, result["direct_q11"],
                              result["reconstruction_q11"], tv_f)

        report_lines.extend([
            f"{name}:",
            f"  float direct PSNR = {direct_psnr_float:.4f} dB; float TV-FISTA = {tv_psnr_float:.4f} dB.",
            f"  fixed direct PSNR = {direct_psnr_fixed:.4f} dB; fixed TV-FISTA = {tv_psnr_fixed:.4f} dB.",
            f"  fixed TV gain = {tv_psnr_fixed-direct_psnr_fixed:+.4f} dB.",
            f"  fixed-vs-float TV max abs error = {max_err:.6f}; RMSE = {rmse_err:.6f}.",
            f"  max |raw FWHT| = {rows[-1]['max_fwht_raw_abs']}; max |TV div|={rows[-1]['max_tv_div_abs_q11']} Q11 LSB.",
            f"  max |TV u|={rows[-1]['max_tv_u_abs_q11']}; max |TV grad|={rows[-1]['max_tv_grad_abs_q11']} Q11 LSB.",
            f"  max |TV delta|={rows[-1]['max_tv_delta_abs_q11']}; max |projection candidate|={rows[-1]['max_tv_candidate_abs_q11']} Q11 LSB.",
            f"  max |TV dual component|={rows[-1]['max_tv_dual_abs_q11']}; max |FISTA momentum product|={rows[-1]['max_momentum_product_abs']}.",
            f"  detected arithmetic overflow count = {overflow_total}.",
            ""
        ])

    with (OUT / "metrics_fixedpoint.csv").open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    # Primary cat64 top-level vectors for the first hardware bring-up.
    cat = all_results["cat64"]
    write_hex(OUT_DATA / "cat64_input_q11_s32.hex", cat["image_q11"], 32)
    write_hex(OUT_DATA / "cat64_fwht_raw_q11_s32.hex", cat["raw_fwht_q11"], 32)
    write_hex(OUT_DATA / "cat64_fwht_normalized_q11_s32.hex", cat["coeff_q11_full"], 32)
    write_hex(OUT_DATA / "cat64_measurements_q11_s32.hex",
              cat["measurements_q11_full"].reshape(-1)[indices], 32)
    write_hex(OUT_DATA / "cat64_direct_q11_s16.hex", cat["direct_q11"], 16)
    write_hex(OUT_DATA / "cat64_tv_fista_q11_s16.hex", cat["reconstruction_q11"], 16)
    write_hex(OUT_DATA / "fista_beta_q15.hex", cat["beta_q15"], 16)

    report_lines.extend([
        "GLOBAL RANGE / DESIGN NOTES",
        "---------------------------",
        "All four 64x64 test images completed 40 outer x 35 inner iterations.",
        "All tested 16-bit Q5.11 TV states and TV projection candidates remained in range; no wrap/saturation was required.",
        "The 32-bit FWHT path remained within signed 32-bit range for the tested image set.",
        "The legacy 8-bit Stage-4 vector is retained as a separate compatibility test; the new algorithm path feeds Q5.11 pixels to the same 32-bit FWHT engine.",
        "The 1024 measurement values in the generated vectors are signed 32-bit Q11 coefficients, ordered by ascending row-major flattened mask index.",
        "The 4096-bit mask and measurement index list are generated from Stage-0.1's exact low-sequency mask. The FPGA may store this mask/indices in ROM.",
        "The fixed-point model's lambda=20/2048 is a quantized approximation of the Stage-0.1 float lambda=0.01. The small observed quality difference is reported rather than hidden.",
        "This stage does not implement UART, BRAM RTL, the 64x64 TV Prox hardware, or full FPGA top-level integration.",
        "",
        "OVERALL: PASS"
    ])
    (OUT / "fixedpoint_report.txt").write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    print("[PASS] Stage-4 FWHT legacy vectors: 4096/4096")
    print("[PASS] Stage-5B Q5.11 projection vectors: 128/128")
    print("[PASS] Stage-5C 8x8 TV prox vectors: 64/64")
    for row in rows:
        print(
            f"[PASS] {row['image']}: fixed TV={row['tv_fixed_psnr_db']:.3f} dB, "
            f"float TV={row['tv_float_psnr_db']:.3f} dB, "
            f"max error={row['fixed_vs_float_max_abs_error']:.5f}, "
            f"overflow={row['overflow_count']}"
        )
    print("[PASS] 64x64 fixed-point range checks: no overflow detected")
    print(f"[OUTPUT] {OUT.resolve()}")

if __name__ == "__main__":
    main()
