#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Optional quick PC probes for iterations, TV inner iterations and masks.
Never writes to the FPGA or edits frozen RTL.
"""
import sys,csv,json
from pathlib import Path
from time import perf_counter
import numpy as np
BASE=Path(__file__).resolve().parent
sys.path.insert(0,str(BASE))
from run_stage6a_quality_sweep import ref, NAMES, masks, run_fista, metrics_for

OUT=BASE/'reports'; OUT.mkdir(parents=True,exist_ok=True)
imgs={n:ref.load_u8(ref.DATA/f'{n}.png') for n in NAMES}
mask_dict=masks()
records=[]

cases=[]
for name in NAMES:
    cases.append((name,'frozen_low1024',20,40,35,'baseline'))
    cases.extend((name,'frozen_low1024',11,o,35,'outer_sweep') for o in (20,40,60,80))
    cases.extend((name,'frozen_low1024',11,40,i,'inner_sweep') for i in (15,25,50))
    cases.extend((name,m,11,40,35,'mask_sweep') for m in ('mixed_low768_random256','random1024'))

for name,mask_key,lam,outer,inner,phase in cases:
    t=perf_counter()
    try:
        recon,direct=run_fista(imgs[name],mask_dict[mask_key],lam,outer,inner)
        m=metrics_for(imgs[name],recon,direct)
        row={'image':name,'phase':phase,'mask':mask_key,'lambda_q11':lam,'outer_iters':outer,
             'inner_iters':inner,'status':'PASS','runtime_pc_s':round(perf_counter()-t,3),**m}
    except (OverflowError,ValueError) as ex:
        row={'image':name,'phase':phase,'mask':mask_key,'lambda_q11':lam,'outer_iters':outer,
             'inner_iters':inner,'status':f'INVALID: {ex}','runtime_pc_s':round(perf_counter()-t,3)}
    records.append(row)
    print(f"[{row['status']}] {name} {phase} lam={lam} outer={outer} inner={inner} mask={mask_key} PSNR={row.get('psnr_db',float('nan')):.3f}",flush=True)

fields=['image','phase','mask','lambda_q11','outer_iters','inner_iters','status','psnr_db','ssim',
        'direct_psnr_db','edge_rmse','runtime_pc_s']
with (OUT/'additional_probes.csv').open('w',encoding='utf-8-sig',newline='') as f:
    w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(records)

def aggregate(label, selection):
    r=[p for p in records if selection(p)]
    valid=[p for p in r if p['status']=='PASS']
    return {'experiment':label,'valid':len(valid),'total':len(r),
            'mean_psnr_db':float(np.mean([p['psnr_db'] for p in valid])) if valid else None,
            'mean_ssim':float(np.mean([p['ssim'] for p in valid])) if valid else None,
            'by_image':{n:next((p['psnr_db'] for p in valid if p['image']==n),None) for n in NAMES}}

summary=[]
summary.append(aggregate('lambda20_outer40_inner35_low1024',lambda p:p['phase']=='baseline'))
for o in (20,40,60,80):
    summary.append(aggregate(f'lambda11_outer{o}_inner35_low1024',lambda p,o=o:p['phase']=='outer_sweep' and p['outer_iters']==o))
for i in (15,25,50):
    summary.append(aggregate(f'lambda11_outer40_inner{i}_low1024',lambda p,i=i:p['phase']=='inner_sweep' and p['inner_iters']==i))
for m in ('mixed_low768_random256','random1024'):
    summary.append(aggregate(f'lambda11_outer40_inner35_{m}',lambda p,m=m:p['phase']=='mask_sweep' and p['mask']==m))
with (OUT/'additional_summary.json').open('w',encoding='utf-8') as f:json.dump(summary,f,indent=2,ensure_ascii=False)
print('\n=== Mean PSNR (these 4 images only) ===')
for row in summary:print(f"{row['experiment']}: {row['mean_psnr_db']:.3f} dB ({row['valid']}/{row['total']} PASS)")
