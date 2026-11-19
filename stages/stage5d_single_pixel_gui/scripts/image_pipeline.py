#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stage-5D measurement preparation and visualization.

Measurement convention is IDENTICAL to frozen Stage-0.2/Stage-5B:
- input uint8 -> Q5.11: (u8*2048+127)//255
- 4096 point natural Sylvester Hadamard, unnormalized integer FWHT
- normalized: arithmetic right shift by 6 (including negative values)
- choose 1024 ones of the EXACT original row-major low-sequency mask
- 32-bit two's complement wire representation, little-endian on UART.
No floating point approximations are used in the measurement operator.
"""
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
import hashlib
import json
import re
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parent.parent
DATA=ROOT/'data'
KNOWN=('cat64','moon','rocket','text')
Q11_ONE=2048


def read_mask() -> np.ndarray:
    vals=np.array([int(s) for s in (DATA/'mask_4096_rowmajor.mem').read_text(encoding='ascii').split()],dtype=np.uint8)
    if vals.shape!=(4096,) or int(vals.sum())!=1024 or np.any((vals!=0)&(vals!=1)):
        raise ValueError('Invalid frozen 4096-bit Hadamard mask')
    return vals.astype(bool)

MASK=read_mask()
MASK_SHA256=hashlib.sha256((DATA/'mask_4096_rowmajor.mem').read_bytes()).hexdigest()


def fwht_4096_int(values:np.ndarray) -> np.ndarray:
    a=np.asarray(values,dtype=np.int64).reshape(-1).copy()
    if len(a)!=4096: raise ValueError('FWHT input must have exactly 4096 points')
    for depth in range(12):
        stride=1<<depth
        b=a.reshape(-1,2,stride)
        lo=b[:,0,:].copy();hi=b[:,1,:].copy()
        b[:,0,:]=lo+hi
        b[:,1,:]=lo-hi
    return a


def image_to_u8(path:Path|str) -> np.ndarray:
    with Image.open(path) as im:
        return np.asarray(im.convert('L').resize((64,64),Image.Resampling.LANCZOS),dtype=np.uint8).copy()


def make_measurements(image_u8:np.ndarray) -> list[int]:
    a=np.asarray(image_u8,dtype=np.int64)
    if a.shape!=(64,64) or np.any(a<0) or np.any(a>255):
        raise ValueError('Expected 64x64 uint8-equivalent image')
    q=(a*Q11_ONE+127)//255
    coeff=fwht_4096_int(q.reshape(-1))>>6
    if np.any(coeff < -(2**31)) or np.any(coeff >= 2**31):
        raise ValueError('Hadamard measurements exceed signed 32 bit')
    return [int(v) & 0xFFFFFFFF for v in coeff[MASK]]


def signed_measurements(words:list[int]) -> np.ndarray:
    a=np.array(words,dtype=np.int64)
    if a.shape!=(1024,) or np.any(a<0) or np.any(a>0xFFFFFFFF):
        raise ValueError('Exactly 1024 32-bit measurement words required')
    return np.where(a>=2**31,a-2**32,a)


def direct_backprojection(words:list[int]) -> np.ndarray:
    buf=np.zeros(4096,dtype=np.int64)
    buf[MASK]=signed_measurements(words)
    return (fwht_4096_int(buf)>>6).reshape(64,64)


def pixels_q11_to_u8(pixels:np.ndarray|list[int]) -> np.ndarray:
    a=np.asarray(pixels,dtype=np.int64).reshape(64,64)
    # Exact same display conversion as Stage-5B; clipping is display-only.
    return np.clip((np.clip(a,0,Q11_ONE)*255+1024)//Q11_ONE,0,255).astype(np.uint8)


def psnr_q11(reference_u8:np.ndarray, reconstructed_q11:np.ndarray|list[int]) -> float:
    ref=(np.asarray(reference_u8,dtype=np.int64)*Q11_ONE+127)//255
    rec=np.asarray(reconstructed_q11,dtype=np.int64).reshape(64,64)
    mse=float(np.mean((ref-rec).astype(np.float64)**2))
    return float('inf') if mse==0 else float(10*np.log10((Q11_ONE**2)/mse))


def read_hex_words(path:Path, count:int, width:int) -> list[int]:
    text=path.read_text(encoding='ascii')
    out=[]
    for line in text.splitlines():
        line=line.split('//',1)[0].split('#',1)[0].strip()
        if not line:continue
        for tok in line.split():
            v=int(tok,16)
            if not 0<=v<2**width: raise ValueError(f'{path.name}: value out of {width}-bit range')
            out.append(v)
    if len(out)!=count:raise ValueError(f'{path.name}: found {len(out)} words; expected {count}')
    return out


def read_external_words(path:Path) -> list[int]:
    path=Path(path)
    suffix=path.suffix.lower()
    if suffix in ('.mem','.hex'):
        return read_hex_words(path,1024,32)
    if suffix in ('.npy','.npz'):
        result=np.load(path,allow_pickle=False)
        if isinstance(result,np.lib.npyio.NpzFile):
            keys=[k for k in ('measurements','y','arr_0') if k in result.files]
            if not keys and len(result.files)==1:keys=result.files
            if not keys:raise ValueError('NPZ must contain measurements/y/arr_0 or a unique array')
            arr=np.asarray(result[keys[0]])
            result.close()
        else:arr=np.asarray(result)
        if not np.issubdtype(arr.dtype,np.integer):
            raise ValueError('External measurements must be 32-bit integer Q11. Float requires explicit calibration first.')
        vals=arr.reshape(-1).astype(np.int64)
    elif suffix in ('.txt','.csv'):
        text=path.read_text(encoding='utf-8-sig')
        vals_list=[]
        for line in text.splitlines():
            line=line.split('#',1)[0].strip()
            if not line:continue
            for tok in re.split(r'[,;\s]+',line):
                if tok: vals_list.append(int(tok,10))
        vals=np.asarray(vals_list,dtype=np.int64)
    else:
        raise ValueError('Supported: .mem/.hex (hex), .csv/.txt (decimal integer), .npy/.npz (integer array)')
    if vals.shape!=(1024,):raise ValueError(f'Expected 1024 measurement integers, got {vals.size}')
    if np.any(vals<-(2**31)) or np.any(vals>0xFFFFFFFF):
        raise ValueError('Measurement value outside signed int32 / unsigned bit-pattern range')
    return [int(x)&0xFFFFFFFF for x in vals]


@dataclass
class Dataset:
    label:str
    kind:str
    words:list[int]
    image_u8:np.ndarray|None=None
    golden:list[int]|None=None
    source_path:str=''
    provenance:dict[str,Any]=field(default_factory=dict)
    direct_q11:np.ndarray|None=None

    def __post_init__(self):
        signed_measurements(self.words)
        if self.golden is not None and len(self.golden)!=4096:
            raise ValueError('Golden vector must contain 4096 Q11 elements')
        self.direct_q11=direct_backprojection(self.words)


def builtin_dataset(name:str) -> Dataset:
    if name not in KNOWN:raise ValueError(f'Unknown built-in dataset {name}')
    im_path=DATA/'input_images'/f'{name}.png'
    image=image_to_u8(im_path)
    words=read_hex_words(DATA/f'{name}_measurements_q11_s32.mem',1024,32)
    expected=read_hex_words(DATA/f'{name}_expected_final_q11_s16.mem',4096,16)
    if make_measurements(image)!=words:
        raise AssertionError(f'Built-in {name} image no longer matches frozen measurement file')
    return Dataset(name,'builtin',words,image,expected,str(im_path),{
        'acquisition':'software-generated Hadamard measurements from bundled images',
        'ground_truth_type':'input image', 'golden_type':'Stage-0.2 fixed-point 40-round reference',
    })


def user_image_dataset(path:Path|str) -> Dataset:
    path=Path(path)
    im=image_to_u8(path)
    return Dataset(path.stem,'user_image',make_measurements(im),im,None,str(path),{
        'acquisition':'software-generated Hadamard measurements from user-supplied image',
        'ground_truth_type':'input image',
        'golden_type':'none; do not claim 4096/4096 bit-exact golden matching',
    })


def external_measurement_dataset(path:Path|str, *, reference_path:Path|str|None=None,
                                 source_url:str='', acquisition_type:str='unverified',
                                 operator_confirmed:bool=False)->Dataset:
    path=Path(path)
    if not operator_confirmed:
        raise ValueError('You must confirm the 64x64 natural Hadamard/1024-mask/Q11 measurement convention')
    im=image_to_u8(reference_path) if reference_path else None
    return Dataset(path.stem,'external_measurements',read_external_words(path),im,None,str(path),{
        'acquisition':acquisition_type,'source_url':source_url.strip() or 'not supplied',
        'operator_confirmed_compatible':True,
        'important':'Compatible file dimensions do NOT authenticate original optical acquisition.',
        'reference_image':str(reference_path or ''),
        'golden_type':'not available; do not claim bit-exact validation',
    })


def write_mem(path:Path, words:list[int], width:int):
    digits=width//4
    path.write_text(''.join(f'{v & (2**width-1):0{digits}x}\n' for v in words),encoding='ascii')


def save_grayscale(path:Path, u8:np.ndarray):
    Image.fromarray(np.asarray(u8,dtype=np.uint8),mode='L').save(path)
