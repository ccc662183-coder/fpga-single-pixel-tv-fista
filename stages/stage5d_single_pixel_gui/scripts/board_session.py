#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verified Stage-5B packet protocol, reused unmodified on-wire semantics.

This module does NOT implement or emulate TV-FISTA on the PC.
A session requires a connected AX7020 with the Stage-5B 40-iteration bitstream.
"""
from __future__ import annotations
import hashlib, struct, time
from typing import Callable, Any
from .stage5b_reconstruct import (
    RESET,RESET_ACK,LOAD,LOAD_ACK,START,START_ACK,GET_STATE,STATE,
    READ,READ_RESP,STATUS,STATUS_RESP,chunk_generator,decode_state,query)
from .image_pipeline import Dataset, psnr_q11


class UserCancelled(Exception): pass


def run_board_session(ser, dataset:Dataset, baud:int=1_000_000,
                      compute_timeout:float=35.0,
                      progress:Callable[[str,int],None]|None=None,
                      cancelled:Callable[[],bool]|None=None) -> dict[str,Any]:
    """Use the exact Stage-5B command/response types and 17+32 packet sequence.

    `ser` is a real pyserial object in the GUI. Dependency injection permits
    *explicitly labeled* mock transport testing without a physical FPGA.
    """
    def report(msg:str,percentage:int):
        if progress:progress(msg,percentage)
    def check():
        if cancelled and cancelled():raise UserCancelled('用户取消操作；下次运行将重新复位计算核心')
    seq=0x1000
    def send(typ:int,payload:bytes,expected:int,timeout:float=4.0)->bytes:
        nonlocal seq
        check()
        received=query(ser,typ,seq,payload,expected,timeout=timeout)
        seq=(seq+1)&0xFFFF
        return received

    started=time.monotonic()
    if hasattr(ser,'reset_input_buffer'):ser.reset_input_buffer()
    data=send(STATUS,b'',STATUS_RESP)
    if len(data)!=4:raise RuntimeError('FPGA STATUS 响应长度错误')
    actual,=struct.unpack('<I',data)
    if actual!=baud:raise RuntimeError(f'FPGA UART 运行速率 {actual} bps 与 PC 配置 {baud} 不一致')
    report(f'串口已确认：{actual:,} bps，8N1',3)
    if send(RESET,b'',RESET_ACK)!=b'\x00':raise RuntimeError('计算核心 RESET 应答错误')
    report('计算核心已复位；开始加载测量向量',5)

    t_load=time.monotonic()
    for idx,payload in chunk_generator(dataset.words):
        response=send(LOAD,payload,LOAD_ACK)
        if len(response)!=4:raise RuntimeError(f'LOAD[{idx}] ACK 长度错误')
        aidx,loaded,state=struct.unpack('<BHB',response)
        target=min((idx+1)*63,1024)
        if (aidx,loaded,state)!=(idx,target,0):
            raise RuntimeError(f'LOAD[{idx}] 出错：ack={(aidx,loaded,state)}, expected={(idx,target,0)}')
        report(f'加载测量值 {loaded}/1024（第 {idx+1}/17 包）',5+int((idx+1)*19/17))
    load_elapsed=time.monotonic()-t_load
    stat=decode_state(send(GET_STATE,b'',STATE))
    if not stat['ready'] or stat['measurements_loaded']!=1024:
        raise RuntimeError(f'FPGA 测量数据未准备好：{stat}')
    report('1024 个测量值 CRC 校验完成；启动 FPGA PL 重建',26)

    t_compute=time.monotonic()
    if send(START,b'',START_ACK)!=b'\x00':raise RuntimeError('FPGA 拒绝 START 命令')
    deadline=time.monotonic()+compute_timeout
    polls=0
    while True:
        check()
        stat=decode_state(send(GET_STATE,b'',STATE))
        polls+=1
        if stat['range_error'] or stat['protocol_error']:
            raise RuntimeError(f'FPGA 算法错误状态：{stat}')
        if stat['done']:
            break
        if time.monotonic()>deadline:
            raise TimeoutError(f'等待 FPGA 完成超过 {compute_timeout} 秒；最后状态={stat}')
        # Report progress based on zero-based current iteration, not elapsed time.
        pct=max(27,min(79,27+int((stat['iter']+1)*51/40)))
        report(f'PL 计算中：外迭代索引 {stat["iter"]}/39（未完成）',pct)
        time.sleep(.2)
    poll_elapsed=time.monotonic()-t_compute
    if stat['completed_outer_iterations']!=40:
        raise RuntimeError(f'FPGA 实际完成 {stat["completed_outer_iterations"]} 轮，预期 40（原始索引={stat["iter"]}）')
    report(f'PL 计算完成：40 轮，{stat["compute_cycles"]:,} 周期',80)

    chunks=[]
    t_read=time.monotonic()
    for idx in range(32):
        block=send(READ,bytes([idx]),READ_RESP)
        if len(block)!=256:raise RuntimeError(f'结果块 {idx} 长度错误：{len(block)}')
        chunks.append(block)
        report(f'结果回读 {((idx+1)*128):,}/4096 像素',80+int((idx+1)*18/32))
    read_elapsed=time.monotonic()-t_read
    raw=b''.join(chunks)
    pixels=list(struct.unpack('<4096H',raw))
    if any(x>2048 for x in pixels):
        raise RuntimeError('FPGA 输出含超出 [0, 2048] 的裁剪后像素')
    mismatches=[]
    if dataset.golden is not None:
        mismatches=[(i,int(a),int(b)) for i,(a,b) in enumerate(zip(pixels,dataset.golden)) if a!=b]
    psnr=(psnr_q11(dataset.image_u8,pixels) if dataset.image_u8 is not None else None)
    record={
        'source_kind':dataset.kind,
        'dataset':dataset.label,
        'source_path':dataset.source_path,
        'provenance':dataset.provenance,
        'hardware':'AX7020, PL RTL TV-FISTA Stage-4C integrated by Stage-5B UART',
        'link_verified':True,
        'port':str(getattr(ser,'port','Unknown')),
        'baud_bps':baud,
        'measurement_count':1024,
        'measurement_sha256':hashlib.sha256(struct.pack('<1024I',*dataset.words)).hexdigest(),
        'measurement_packets_crc_acknowledged':17,
        'result_packets_crc_verified':32,
        'output_pixel_count':4096,
        'output_sha256':hashlib.sha256(raw).hexdigest(),
        'completed_outer_iterations':40,
        'raw_final_outer_index':stat['iter'],
        'tv_inner_iterations_per_outer':35,
        'compute_cycles':stat['compute_cycles'],
        'core_time_50mhz_s':stat['compute_cycles']/50_000_000,
        'load_time_s':load_elapsed,
        'compute_poll_elapsed_s':poll_elapsed,
        'read_time_s':read_elapsed,
        'total_session_time_s':time.monotonic()-started,
        'status_poll_count':polls,
        'pixel_min':min(pixels),
        'pixel_max':max(pixels),
        'pixel_sum':sum(pixels),
        'golden_available':dataset.golden is not None,
        'golden_matched_pixels':4096-len(mismatches) if dataset.golden is not None else None,
        'golden_mismatch_count':len(mismatches) if dataset.golden is not None else None,
        'golden_first_mismatches':mismatches[:8],
        'psnr_db':psnr,
        'all_pass':len(mismatches)==0 if dataset.golden is not None else True,
        'validation_meaning':(
            'FPGA real board output bit-exact with frozen Stage-0.2 40-round golden'
            if dataset.golden is not None else
            'FPGA executed 40 rounds and 49 CRC-protected packets; no independent bit-exact golden was supplied'
        ),
    }
    report('FPGA 结果回传完成；已生成实测记录',100)
    return {'pixels':pixels,'raw':raw,'report':record}
