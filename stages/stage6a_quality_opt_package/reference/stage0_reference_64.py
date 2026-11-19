#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""64x64 floating-point golden reference for the FPGA single-pixel imaging project.
Measurements are synthetic Hadamard measurements generated from known images.
This is a software reference only; it does not represent optical capture or FPGA execution.
"""
from __future__ import annotations
import csv, math, hashlib, json
from pathlib import Path
from time import perf_counter
import numpy as np
from PIL import Image
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent
DATA = ROOT / 'stage0_reference_64' / 'data'
STAGE4_CAT = DATA / 'cat64.png'
OUT = ROOT / 'stage0_reference_64'
SIDE = 64
NPIX = SIDE * SIDE
MEASURE_RATIO = 0.25
MEASURE_COUNT = int(NPIX * MEASURE_RATIO)
TV_LAMBDA = 0.01
OUTER_ITERATIONS = 40
TV_INNER_ITERATIONS = 35
MASK_SEED = 20261028


def fwht_axis(values: np.ndarray, axis: int) -> np.ndarray:
    a = np.swapaxes(np.asarray(values, dtype=np.float64), axis, -1).copy()
    n = a.shape[-1]
    if n <= 0 or n & (n - 1):
        raise ValueError('FWHT axis length must be a power of two')
    step = 1
    while step < n:
        b = a.reshape(*a.shape[:-1], n // (2 * step), 2, step)
        lo = b[..., 0, :].copy()
        hi = b[..., 1, :].copy()
        b[..., 0, :] = lo + hi
        b[..., 1, :] = lo - hi
        step *= 2
    return np.swapaxes(a, axis, -1)


def fwht2(x: np.ndarray) -> np.ndarray:
    if x.shape != (SIDE, SIDE):
        raise ValueError(f'Expected {SIDE}x{SIDE}, got {x.shape}')
    # W = H_4096 / 64; orthonormal, symmetric, and self-inverse.
    return fwht_axis(fwht_axis(x, 1), 0) / SIDE


def sequency_to_sylvester(n: int) -> np.ndarray:
    bits = n.bit_length() - 1
    seq = np.arange(n, dtype=np.int64)
    gray = seq ^ (seq >> 1)
    result = np.zeros(n, dtype=np.int64)
    for b in range(bits):
        result |= ((gray >> b) & 1) << (bits - 1 - b)
    return result


def make_low_sequency_mask(n: int, count: int) -> np.ndarray:
    perm = sequency_to_sylvester(n)
    coords = [(r, c) for r in range(n) for c in range(n)]
    coords.sort(key=lambda rc: (rc[0] + rc[1], max(rc), rc[0], rc[1]))
    mask = np.zeros((n, n), dtype=bool)
    for r, c in coords[:count]:
        mask[perm[r], perm[c]] = True
    return mask


def grad2(a: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    gr = np.zeros_like(a)
    gc = np.zeros_like(a)
    gr[:-1, :] = a[1:, :] - a[:-1, :]
    gc[:, :-1] = a[:, 1:] - a[:, :-1]
    return gr, gc


def div2(pr: np.ndarray, pc: np.ndarray) -> np.ndarray:
    # Negative adjoint of the forward-difference operator above.
    out = pr + pc
    out = out.copy()
    out[1:, :] -= pr[:-1, :]
    out[:, 1:] -= pc[:, :-1]
    return out


def prox_tv_isotropic(f: np.ndarray, weight: float, inner_steps: int) -> np.ndarray:
    pr = np.zeros_like(f)
    pc = np.zeros_like(f)
    if weight <= 0:
        return f.copy()
    for _ in range(inner_steps):
        u = f + weight * div2(pr, pc)
        gr, gc = grad2(u)
        nr = pr + (0.125 / weight) * gr
        nc = pc + (0.125 / weight) * gc
        norm = np.maximum(1.0, np.hypot(nr, nc))
        pr, pc = nr / norm, nc / norm
        pr[-1, :] = 0.0
        pc[:, -1] = 0.0
    return f + weight * div2(pr, pc)


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    mse = float(np.mean((a - b) ** 2))
    return float('inf') if mse == 0 else 10.0 * math.log10(1.0 / mse)


def tv_fista(coeff: np.ndarray, mask: np.ndarray):
    measured = np.where(mask, coeff, 0.0)
    direct = fwht2(measured)
    x = direct.copy()
    z = x.copy()
    t = 1.0
    history = [(0, None)]
    for k in range(1, OUTER_ITERATIONS + 1):
        residual = np.where(mask, fwht2(z) - measured, 0.0)
        projected = z - fwht2(residual)  # L=1 for orthonormal W and row selector P.
        x_new = prox_tv_isotropic(projected, TV_LAMBDA, TV_INNER_ITERATIONS)
        t_new = (1.0 + math.sqrt(1.0 + 4.0 * t * t)) / 2.0
        z = x_new + ((t - 1.0) / t_new) * (x_new - x)
        x, t = x_new, t_new
        if not np.isfinite(x).all():
            raise FloatingPointError(f'non-finite values at outer iteration {k}')
    return np.clip(direct, 0, 1), np.clip(x, 0, 1)


def load_gray(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        im = im.convert('L').resize((SIDE, SIDE), Image.Resampling.LANCZOS)
        return np.asarray(im, dtype=np.float64) / 255.0


def run_self_tests(mask: np.ndarray):
    rng = np.random.default_rng(20261105)
    x = rng.normal(size=(SIDE, SIDE))
    transform_error = float(np.max(np.abs(fwht2(fwht2(x)) - x)))
    if transform_error > 1e-10:
        raise RuntimeError(f'FWHT inverse test failed: {transform_error}')
    if int(mask.sum()) != MEASURE_COUNT:
        raise RuntimeError(f'Mask count {mask.sum()} != {MEASURE_COUNT}')
    # Gradient/divergence adjoint identity with zero boundary components.
    a = rng.normal(size=(SIDE, SIDE))
    p = rng.normal(size=(SIDE, SIDE)); q = rng.normal(size=(SIDE, SIDE))
    p[-1, :] = 0.0; q[:, -1] = 0.0
    gx, gy = grad2(a)
    adj_error = abs(float(np.sum(gx*p + gy*q) + np.sum(a*div2(p, q))))
    if adj_error > 1e-9:
        raise RuntimeError(f'Gradient/divergence adjoint test failed: {adj_error}')
    return transform_error, adj_error


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    mask = make_low_sequency_mask(SIDE, MEASURE_COUNT)
    fwht_err, adj_err = run_self_tests(mask)
    cases = []
    images = []
    if STAGE4_CAT.exists():
        images.append(('cat64_stage4_exact', np.asarray(Image.open(STAGE4_CAT).convert('L'), dtype=np.float64) / 255.0, STAGE4_CAT))
    for name in ('cat', 'moon', 'rocket', 'text'):
        p = DATA / f'{name}.png'
        if p.exists() and name != 'cat':
            images.append((name, load_gray(p), p))
    # Keep exactly four cases, with cat64 being the exact Stage-4 FWHT input image.
    images = images[:4]
    if len(images) < 1:
        raise FileNotFoundError('No test images found in Stage-4/Stage-3 package.')

    plot_rows = []
    canonical = None
    for name, original, source in images:
        start = perf_counter()
        coeff = fwht2(original)
        direct, tv = tv_fista(coeff, mask)
        elapsed = perf_counter() - start
        rec = {
            'image': name,
            'source_file': source.name,
            'resolution': f'{SIDE}x{SIDE}',
            'measurement_count': int(mask.sum()),
            'measurement_ratio': MEASURE_RATIO,
            'lambda': TV_LAMBDA,
            'outer_iterations': OUTER_ITERATIONS,
            'tv_inner_iterations': TV_INNER_ITERATIONS,
            'direct_psnr_db': psnr(original, direct),
            'tv_fista_psnr_db': psnr(original, tv),
            'psnr_gain_db': psnr(original, tv) - psnr(original, direct),
            'python_elapsed_s': elapsed,
            'measurement_source': 'synthetic Hadamard transform; no optical acquisition',
        }
        cases.append(rec)
        plot_rows.append((name, original, direct, tv))
        print(f"[PASS] {name}: direct={rec['direct_psnr_db']:.3f} dB, TV={rec['tv_fista_psnr_db']:.3f} dB, gain={rec['psnr_gain_db']:+.3f} dB, time={elapsed:.3f}s")
        if name == 'cat64_stage4_exact':
            canonical = (original, coeff, direct, tv)

    with (OUT / 'metrics_64.csv').open('w', newline='', encoding='utf-8-sig') as f:
        w = csv.DictWriter(f, fieldnames=list(cases[0]))
        w.writeheader(); w.writerows(cases)

    fig, axes = plt.subplots(len(plot_rows), 3, figsize=(9, 3.0*len(plot_rows)), squeeze=False)
    for i, (name, original, direct, tv) in enumerate(plot_rows):
        for j, (img, title) in enumerate(((original, 'Original'), (direct, '25% direct'), (tv, '25% TV-FISTA'))):
            axes[i, j].imshow(img, cmap='gray', vmin=0, vmax=1)
            axes[i, j].set_title(f'{name} | {title}')
            axes[i, j].axis('off')
    fig.tight_layout()
    fig.savefig(OUT / 'reconstruction_64.png', dpi=180)
    plt.close(fig)

    if canonical is None:
        canonical = (plot_rows[0][1], fwht2(plot_rows[0][1]), plot_rows[0][2], plot_rows[0][3])
    original, coeff, direct, tv = canonical
    raw = np.rint(original * 255.0).astype(np.uint8)
    raw_coeff = fwht2(raw.astype(np.float64)) * SIDE  # unnormalized integer H(x), mathematically integral.
    raw_coeff_int = np.rint(raw_coeff).astype(np.int64)
    if np.max(np.abs(raw_coeff - raw_coeff_int)) > 1e-7:
        raise RuntimeError('Raw integer Hadamard coefficient conversion is not integral.')
    stage4_match = 'not checked (Stage-4 vector files not included)'
    old_input_path = DATA / 'fwht64_input.mem'
    old_expected_path = DATA / 'fwht64_expected.mem'
    if old_input_path.exists() and old_expected_path.exists():
        def read_signed_hex(path: Path) -> np.ndarray:
            vals = []
            for line in path.read_text(encoding='ascii').splitlines():
                u = int(line.strip(), 16)
                vals.append(u - (1 << 32) if u >= (1 << 31) else u)
            return np.asarray(vals, dtype=np.int64)
        old_input = read_signed_hex(old_input_path)
        old_expected = read_signed_hex(old_expected_path)
        if old_input.size != NPIX or old_expected.size != NPIX:
            raise RuntimeError('Stage-4 FWHT vector length mismatch.')
        if not np.array_equal(old_input, raw.reshape(-1).astype(np.int64)):
            raise RuntimeError('64x64 golden image does not match Stage-4 input vector.')
        if not np.array_equal(old_expected, raw_coeff_int.reshape(-1)):
            raise RuntimeError('64x64 2D transform does not match Stage-4 1D FWHT expected vector.')
        stage4_match = 'PASS: input and all 4096 expected FWHT coefficients exactly match Stage-4 vectors'
    np.savez_compressed(
        OUT / 'golden_vectors_cat64.npz',
        image_u8=raw,
        image_float=original,
        mask=mask,
        coeff_orthonormal=coeff,
        coeff_integer_unnormalized=raw_coeff_int,
        direct_reconstruction=direct,
        tv_fista_reconstruction=tv,
    )
    # Export reproducible mask and integer coefficient text files for later RTL interface work.
    np.savetxt(OUT / 'mask_64x64_rowmajor.txt', mask.astype(np.uint8).reshape(-1), fmt='%d')
    with (OUT / 'golden_measurements_1024_int32.hex').open('w', encoding='ascii') as f:
        selected = raw_coeff_int.reshape(-1)[mask.reshape(-1)]
        for v in selected:
            f.write(f'{int(v) & 0xFFFFFFFF:08X}\n')

    mask_hash = hashlib.sha256(mask.astype(np.uint8).tobytes()).hexdigest()
    report = [
        '64x64 TV-FISTA floating-point golden reference',
        'Status: SOFTWARE REFERENCE ONLY; not FPGA execution and not optical acquisition.',
        f'Resolution: {SIDE}x{SIDE}; pixels={NPIX}',
        f'Measurements: {MEASURE_COUNT}/{NPIX} ({MEASURE_RATIO:.0%})',
        'Transform: W = H_4096 / 64 = separable H_64 on rows and columns / 64.',
        'Hadamard order: Sylvester natural order; image flattening: row-major.',
        'Mask: same low-sequency construction as previous Stage-1/2/3 scripts, regenerated at 64x64.',
        f'Mask SHA256: {mask_hash}',
        f'TV model: 0.5*||P W x - y||_2^2 + {TV_LAMBDA}*isotropic_TV(x).',
        'TV proximal solver: projected dual-gradient approximation; zero forward-difference boundary.',
        f'FISTA outer iterations: {OUTER_ITERATIONS}; TV proximal inner steps: {TV_INNER_ITERATIONS}.',
        'Gradient Lipschitz constant L=1 because W is orthonormal and P is a row selector.',
        f'FWHT round-trip max error: {fwht_err:.3e}',
        f'Gradient/divergence adjoint identity error: {adj_err:.3e}',
        f'Stage-4 vector cross-check: {stage4_match}',
        'Integer measurement export: unnormalized H_4096(image_u8), selected by row-major mask; signed int32 hex.',
        'Important: integer unnormalized coefficients are exported for interface development only; the fixed-point TV-FISTA arithmetic scaling is not yet frozen.',
        '', '=== Metrics ==='
    ]
    report += [f"{r['image']}: direct={r['direct_psnr_db']:.4f} dB; TV-FISTA={r['tv_fista_psnr_db']:.4f} dB; gain={r['psnr_gain_db']:+.4f} dB; python={r['python_elapsed_s']:.3f}s" for r in cases]
    report += ['', 'Do not interpret Python elapsed time as FPGA latency.', 'The 64x64 mask is a newly generated 64x64 mask; it is not the 128x128 mask cropped.']
    (OUT / 'reference_report.txt').write_text('\n'.join(report)+'\n', encoding='utf-8')
    print(f'\n[PASS] 64x64 reference self-tests: FWHT={fwht_err:.3e}, adjoint={adj_err:.3e}')
    print(f'[INFO] Stage-4 cross-check: {stage4_match}')
    print(f'[OUTPUT] {OUT}')

if __name__ == '__main__':
    main()
