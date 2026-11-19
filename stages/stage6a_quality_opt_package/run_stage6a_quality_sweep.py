#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stage-6A: fixed-point TV-FISTA image-quality parameter & mask exploration.

This program is PC-side ONLY. It does NOT modify Vivado/FPGA firmware.
It preserves the published frozen Stage-0.2 reference source in reference/.
All floating and fixed point metrics refer to 64x64 data, 0..1 image range.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import sys
from pathlib import Path
from time import perf_counter

import numpy as np
from PIL import Image, ImageDraw
from skimage.metrics import structural_similarity
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent
REF = ROOT / 'reference'
sys.path.insert(0, str(REF))
import stage0_2_fixedpoint as ref
import stage0_reference_64 as rf

NAMES = ('cat64', 'moon', 'rocket', 'text')
LAMBDA_Q11 = (8, 9, 10, 11, 12, 13, 14, 15, 16, 20, 24, 28, 32, 40, 48, 64)
OUTER_STEPS = (20, 40, 60, 80)
INNER_STEPS = (15, 25, 35, 50)
MEASURE_COUNT = 1024
FRAC = 11
ONE = 1 << FRAC


def fail_if_overflow(arr: np.ndarray, bits: int, label: str) -> None:
    low, high = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if np.any((arr < low) | (arr > high)):
        raise OverflowError(f'{label}: outside signed-{bits} range')


def tv_prox_param_q11(f: np.ndarray, lam: int, steps: int) -> np.ndarray:
    """Exact Stage-0.2 arithmetic except programmable positive lambda.

    Important: the dual step must scale as 256/lambda_q11, NOT 64/5 for
    every lambda. The original Stage-4A divider is fixed at lambda_q11=20.
    Changing lambda requires new RTL and a new golden regression.
    """
    if lam <= 0:
        raise ValueError('lambda_q11 must be a positive integer')
    f = np.asarray(f, np.int64)
    h, w = f.shape
    px = np.zeros_like(f)
    py = np.zeros_like(f)
    for _ in range(steps):
        div = px + py
        div = div.copy()
        div[1:, :] -= px[:-1, :]
        div[:, 1:] -= py[:, :-1]
        fail_if_overflow(div, 18, 'TV divergence')

        u = f + ((div * lam) >> FRAC)
        fail_if_overflow(u, 16, 'TV u')

        gx = np.zeros_like(u)
        gy = np.zeros_like(u)
        gx[:-1, :] = u[1:, :] - u[:-1, :]
        gy[:, :-1] = u[:, 1:] - u[:, :-1]
        fail_if_overflow(gx, 18, 'TV gx')
        fail_if_overflow(gy, 18, 'TV gy')

        # For lambda_q11=20, integer identity:
        # floor(abs(g)*256/20) == floor(abs(g)*64/5).
        # Restore sign after truncating magnitude toward zero.
        dx = (np.abs(gx) * 256) // lam
        dy = (np.abs(gy) * 256) // lam
        dx = np.where(gx < 0, -dx, dx)
        dy = np.where(gy < 0, -dy, dy)
        vx, vy = px + dx, py + dy
        vx[-1, :] = 0
        vy[:, -1] = 0
        fail_if_overflow(vx, 16, 'TV vx')
        fail_if_overflow(vy, 16, 'TV vy')
        px, py = ref.proj_q11_array(vx, vy)

    div = px + py
    div = div.copy()
    div[1:, :] -= px[:-1, :]
    div[:, 1:] -= py[:, :-1]
    result = f + ((div * lam) >> FRAC)
    fail_if_overflow(result, 16, 'TV output')
    return result


def run_fista(image: np.ndarray, mask: np.ndarray, lam: int, outer: int = 40, inner: int = 35):
    assert image.shape == (64, 64) and mask.shape == (64, 64)
    assert mask.dtype == np.bool_ and mask.sum() == MEASURE_COUNT
    image_q11 = (image.astype(np.int64) * ONE + 127) // 255
    coeff = ref.fwht2_int(image_q11)
    fail_if_overflow(coeff, 32, 'Forward FWHT')
    y = np.where(mask, coeff >> 6, 0)
    direct_raw = ref.fwht2_int(y)
    fail_if_overflow(direct_raw, 32, 'Direct FWHT')
    direct = direct_raw >> 6
    fail_if_overflow(direct, 16, 'Direct initialization')
    x = direct.copy()
    z = x.copy()
    betas = ref.make_beta_q15(outer)

    for k in range(outer):
        c_raw = ref.fwht2_int(z)
        fail_if_overflow(c_raw, 32, 'Forward iteration FWHT')
        resid = np.where(mask, (c_raw >> 6) - y, 0)
        fail_if_overflow(resid, 32, 'Residual')
        adj_raw = ref.fwht2_int(resid)
        fail_if_overflow(adj_raw, 32, 'Adjoint FWHT')
        projected = z - (adj_raw >> 6)
        fail_if_overflow(projected, 16, 'Projected v')
        x_new = tv_prox_param_q11(projected, lam, inner)
        z_new = x_new + (((x_new - x) * int(betas[k])) >> 15)
        fail_if_overflow(z_new, 16, 'Momentum z')
        x, z = x_new, z_new
    return np.clip(x, 0, ONE), np.clip(direct, 0, ONE)


def masks() -> dict[str, np.ndarray]:
    low = ref.mask_low_sequency()
    assert low.sum() == MEASURE_COUNT
    # Deterministic low-frequency biased mix: original first 768 low-sequency
    # positions plus 256 randomly selected positions from the remaining 3328.
    perm = rf.sequency_to_sylvester(64)
    coords = [(r, c) for r in range(64) for c in range(64)]
    coords.sort(key=lambda rc: (rc[0]+rc[1], max(rc), rc[0], rc[1]))
    ordered = np.array([perm[r]*64 + perm[c] for r, c in coords])
    assert len(np.unique(ordered)) == 4096
    assert np.array_equal(np.sort(ordered[:1024]), np.flatnonzero(low.ravel()))
    rng = np.random.default_rng(20261119)
    mix = np.zeros(4096, dtype=bool)
    mix[ordered[:768]] = True
    mix[rng.choice(ordered[768:], size=256, replace=False)] = True
    rnd = np.zeros(4096, dtype=bool)
    rnd[0] = True  # Always retain DC coefficient for a fairer random-mask baseline.
    rnd[rng.choice(np.arange(1,4096), size=1023, replace=False)] = True
    return {"frozen_low1024": low, "mixed_low768_random256": mix.reshape(64,64), "random1024": rnd.reshape(64,64)}


def metrics_for(orig_u8, recon_q11, direct_q11):
    original = orig_u8.astype(float) / 255.0
    rec = recon_q11.astype(float) / ONE
    direct = direct_q11.astype(float) / ONE
    def psnr(a, b):
        mse = float(np.mean((a-b)**2))
        return float('inf') if mse == 0 else 10 * math.log10(1/mse)
    return {
        'psnr_db': psnr(original,rec),
        'ssim': float(structural_similarity(original,rec,data_range=1.0)),
        'direct_psnr_db': psnr(original,direct),
        'edge_rmse': float(np.sqrt(0.5 * (
            np.mean((np.diff(original,axis=0)-np.diff(rec,axis=0))**2)
            +np.mean((np.diff(original,axis=1)-np.diff(rec,axis=1))**2)
        )))
    }


def save_image_comparison(name, img_u8, base, choice, info, out):
    # Data visualization, never claimed as true optically measured imagery.
    a=np.clip(img_u8,0,255).astype(np.uint8)
    imgs=[a,(base*255//ONE).astype(np.uint8),(choice*255//ONE).astype(np.uint8)]
    labels=["Original", "Baseline lambda 20", f"Candidate lambda {info['lambda_q11']}"]
    s=3
    canvas=Image.new('RGB',(3*64*s,64*s+30),'white')
    draw=ImageDraw.Draw(canvas)
    for i,(label,im) in enumerate(zip(labels,imgs)):
        tile=Image.fromarray(im).resize((64*s,64*s),Image.Resampling.NEAREST).convert('RGB')
        canvas.paste(tile,(i*64*s,30))
        draw.text((i*64*s+8,9),label,fill='black')
    canvas.save(out)


def main():
    parser=argparse.ArgumentParser(description='Stage-6A fixed-point image-quality sweep. PC-only.')
    parser.add_argument('--phase', choices=['lambda','all'], default='lambda', help='all adds iteration and mask sensitivity experiments')
    parser.add_argument('--out', default='reports', help='output directory')
    args=parser.parse_args()
    out=Path(args.out)
    if not out.is_absolute(): out=ROOT/out
    out.mkdir(parents=True,exist_ok=True)
    mask_map=masks()
    imgs={n:ref.load_u8(ref.DATA/f'{n}.png') for n in NAMES}
    frozen=mask_map['frozen_low1024']
    records=[]
    cache={}
    def evaluate(name, mask_name, lam, outer, inner=35):
        key=(name,mask_name,lam,outer,inner)
        if key in cache: return cache[key]
        start=perf_counter()
        try:
            rec,direct=run_fista(imgs[name],mask_map[mask_name],lam,outer=outer,inner=inner)
            metr=metrics_for(imgs[name],rec,direct)
            r={"image":name,"mask":mask_name,"lambda_q11":lam,"outer_iters":outer,"tv_inner_iters":inner,
               "lambda_float":lam/ONE,"status":"PASS","runtime_pc_s":round(perf_counter()-start,3),
               "sum_q11":int(rec.sum()),"min_q11":int(rec.min()),"max_q11":int(rec.max()),**metr}
        except (OverflowError,ValueError) as ex:
            rec=None; r={"image":name,"mask":mask_name,"lambda_q11":lam,"outer_iters":outer,"tv_inner_iters":inner,
               "lambda_float":lam/ONE,"status":f"INVALID: {ex}","runtime_pc_s":round(perf_counter()-start,3)}
        records.append(r)
        cache[key]=(r,rec)
        print(f"[{r['status']}] {name:6s} mask={mask_name:24s} lam={lam:2d} outer={outer:2d} inner={inner:2d} psnr={r.get('psnr_db',float('nan')):.3f} ss={r.get('ssim',float('nan')):.4f} in {r['runtime_pc_s']:.2f}s",flush=True)
        return r,rec

    # Baseline exact regression -- must pass before ANY exploratory sweep.
    for n in NAMES:
        r,actual=evaluate(n,'frozen_low1024',20,40)
        golden=ref.parse_signed_hex(ref.VECTORS/n/'tv_fista_reconstruction_q11_s16.hex',16).reshape(64,64)
        if actual is None or not np.array_equal(actual,golden):
            raise RuntimeError(f'FROZEN BASELINE REGRESSION FAILED for {n} (do not trust results)')
        print(f"[BASELINE-EXACT] {n}: 4096/4096 pixels; sum={int(actual.sum())}")

    for lam in LAMBDA_Q11:
        for n in NAMES:
            evaluate(n,'frozen_low1024',lam,40)

    def summarize(rows, key='lambda_q11'):
        agg={}
        for r in rows:
            if r['status']!='PASS':continue
            v=r[key]
            agg.setdefault(v,[]).append(r)
        return [(k,np.mean([z['psnr_db'] for z in rs]),np.mean([z['ssim'] for z in rs]),len(rs))
                for k,rs in agg.items() if len(rs)==len(NAMES)]

    current=[r for r in records if r['mask']=='frozen_low1024' and r['outer_iters']==40 and r['tv_inner_iters']==35]
    ranks=sorted(summarize(current),key=lambda p:(-p[1],-p[2]))
    if not ranks: raise RuntimeError('All lambdas failed')
    best_lam=int(ranks[0][0])
    print(f'BEST AVERAGE PSNR on these 4 sample images: lambda_q11={best_lam}',flush=True)

    if args.phase=='all':
        for outer in OUTER_STEPS:
            for n in NAMES:
                evaluate(n,'frozen_low1024',best_lam,outer)
        for inner in INNER_STEPS:
            for n in NAMES:
                evaluate(n,'frozen_low1024',best_lam,40,inner=inner)
        for mname in mask_map:
            for n in NAMES:
                evaluate(n,mname,best_lam,40)

    # Save reproducible CSV with ALL attempts including overflow-invalid rows.
    fields=['image','mask','lambda_q11','lambda_float','outer_iters','tv_inner_iters','status','psnr_db','ssim',
            'direct_psnr_db','edge_rmse','runtime_pc_s','min_q11','max_q11','sum_q11']
    with (out/'results.csv').open('w',newline='',encoding='utf-8-sig') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(records)
    lam_summary=[]
    for lam,mean_psnr,mean_ssim,count in sorted(summarize(current)):
        lam_summary.append({'lambda_q11':int(lam),'mean_psnr_db':float(mean_psnr),'mean_ssim':float(mean_ssim),'image_count':int(count)})

    def plot_lambda():
        fig,ax=plt.subplots(figsize=(8,4.5))
        ls=[r['lambda_q11'] for r in lam_summary]
        ps=[r['mean_psnr_db'] for r in lam_summary]
        ax.plot(ls,ps,marker='o',linewidth=1.8,color='black')
        ax.axvline(20,linestyle='--',linewidth=1.0,color='0.55',label='frozen lambda=20')
        ax.set(xlabel='TV lambda (Q11 integer)',ylabel='Mean PSNR (dB)',title='Software-only quality sweep, 4 images / 25% low-sequency')
        ax.legend();fig.tight_layout();fig.savefig(out/'lambda_psnr.png',dpi=160);plt.close(fig)
    plot_lambda()
    for n in NAMES:
        b=cache[(n,'frozen_low1024',20,40,35)][1]
        opt=cache[(n,'frozen_low1024',best_lam,40,35)][1]
        save_image_comparison(n,imgs[n],b,opt,{'lambda_q11':best_lam},out/f'{n}_baseline_candidate.png')

    winner=[]
    for n in NAMES:
        b=cache[(n,'frozen_low1024',20,40,35)][0]
        candidate=cache[(n,'frozen_low1024',best_lam,40,35)][0]
        winner.append({'image':n,'baseline_psnr':b['psnr_db'],'candidate_psnr':candidate['psnr_db'],
                       'delta_psnr_db':candidate['psnr_db']-b['psnr_db'],
                       'baseline_ssim':b['ssim'],'candidate_ssim':candidate['ssim'],
                       'delta_ssim':candidate['ssim']-b['ssim']})

    report={
        'scope':'PC ONLY; exploratory, no new FPGA bitstream created, no hardware quality claim',
        'input_images':list(NAMES),'measurement_count':1024,'resolution':'64x64',
        'frozen_reference':'Stage-0.2 fixed-point golden, exact 4096/4096 per image',
        'hardware_baseline':{'lambda_q11':20,'outer_iters':40,'inner_iters':35},
        'mask_restriction':'Changing mask requires FPGA mask ROM change / new bitstream and new matched measurements',
        'lambda_restriction':'Stage-4A uses a fixed /5 divider; changing lambda requires corresponding RTL changes and re-verification',
        'iteration_restriction':'Extending >40 outer loops requires ROM / control changes and re-verification',
        'lambda_table':lam_summary,'best_mean_psnr_lambda_q11':best_lam,'per_image_comparison':winner,
        'all_runs':len(records),'invalid_runs':len([r for r in records if r['status']!='PASS']),
        'mask_sha256':{name:hashlib.sha256(mask.astype(np.uint8).tobytes()).hexdigest() for name,mask in mask_map.items()},
    }
    if args.phase=='all':
        report['additional_experiments']='outer_iters 20/40/60/80; TV inner 15/25/35/50; mixed/random 25% mask at selected lambda'
    with (out/'summary.json').open('w',encoding='utf-8') as f:
        json.dump(report,f,ensure_ascii=False,indent=2,allow_nan=False)
    lines=[
        'Stage-6A | PC fixed-point quality-sweep results',
        '================================================',
        'Not an FPGA hardware experiment. Baseline 4 images checked bit-exact.',
        'Baseline: 64x64, 1024 measurements (25%), low-sequency mask, lambda_q11=20, 40x35.',
        f'Sweep lambda values: {list(LAMBDA_Q11)}',
        '', 'Lambda | Mean PSNR (dB) | Mean SSIM',
    ]
    for r in lam_summary:lines.append(f"{r['lambda_q11']:6d} | {r['mean_psnr_db']:14.4f} | {r['mean_ssim']:.5f}")
    lines+=['',f'Best MEAN PSNR on these four images only: lambda Q11 = {best_lam} ({best_lam/2048:.7f})',
            'Per-image PSNR change compared with frozen lambda20:']
    for r in winner: lines.append(f"  {r['image']}: {r['baseline_psnr']:.4f} -> {r['candidate_psnr']:.4f} dB ({r['delta_psnr_db']:+.4f} dB), SSIM {r['baseline_ssim']:.4f} -> {r['candidate_ssim']:.4f}")
    lines+=['','Do NOT reclassify this parameter sweep as a validated FPGA result.',
            'Do NOT assume tuned lambda generalizes to unseen or real optical datasets.',
            'See summary.json for mask and RTL compatibility risks.']
    (out/'summary.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print('\n'.join(lines[-13:]))
    print(f'WROTE: {out.resolve()}')

if __name__=='__main__':
    main()
