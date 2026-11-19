#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stage-5B real AX7020 TV-FISTA: 1024 measurements -> PL compute -> 4096 pixels.

Board: 50MHz PL, 1Mbps 8N1, fixed 40 FISTA x35 TV, J10 UART.
Use `--self-test` before synthesizing the FPGA. No fake/simulated hardware results.
"""
from __future__ import annotations
import argparse, struct, time, json, hashlib, sys
from pathlib import Path
# Compatible with both `from scripts.stage5b_reconstruct import ...` (GUI)
# and `python scripts/stage5b_reconstruct.py ...` (standalone CLI).
if __package__:
    from .stage5a_link_test import (crc16_ccitt_false, make_packet, unpack_packet,
                                    read_packet, SYNC, MAX_PAYLOAD)
else:
    from stage5a_link_test import (crc16_ccitt_false, make_packet, unpack_packet,
                                   read_packet, SYNC, MAX_PAYLOAD)

RESET=0x48; RESET_ACK=0x49
LOAD=0x40; LOAD_ACK=0x41
START=0x42; START_ACK=0x43
GET_STATE=0x44; STATE=0x45
READ=0x46; READ_RESP=0x47
ERROR=0x7F
STATUS=0x10; STATUS_RESP=0x11
BASE=Path(__file__).resolve().parent.parent
DATA=BASE/'data'


def get_inputs(dataset: str):
    inpath=DATA/f'{dataset}_measurements_q11_s32.mem'
    goldpath=DATA/f'{dataset}_expected_final_q11_s16.mem'
    vals=[int(s,16) for s in inpath.read_text().split() if s and not s.startswith('//')]
    gold=[int(s,16) for s in goldpath.read_text().split() if s and not s.startswith('//')]
    if len(vals)!=1024 or len(gold)!=4096:
        raise ValueError(f'Unexpected input sizes: {len(vals)}, {len(gold)}')
    assert all(0<=v<2**32 for v in vals)
    assert all(0<=v<2**16 for v in gold)
    return vals, gold


def chunk_generator(vals):
    assert len(vals)==1024
    for index in range(17):
        group=vals[index*63:min((index+1)*63,1024)]
        assert len(group)==(16 if index==16 else 63)
        payload=bytes([index])+struct.pack('<'+'I'*len(group),*group)
        assert len(payload)==(65 if index==16 else 253)
        yield index,payload


def decode_state(payload: bytes):
    if len(payload)!=12: raise ValueError(f'State payload {len(payload)} !=12')
    flags,outer,loaded,cycles,crc_errors,ignored=struct.unpack('<BBHIHH',payload)
    # RTL outer_iter is a ZERO-BASED current/last iteration index.
    # At DONE, index 39 means all 40 requested iterations have completed.
    # Do not infer completed count from the in-progress index.
    done = bool(flags & 4)
    return dict(ready=bool(flags&1),busy=bool(flags&2),done=done,
                range_error=bool(flags&8),protocol_error=bool(flags&16),
                iter=outer,
                completed_outer_iterations=(outer + 1 if done else None),
                measurements_loaded=loaded,compute_cycles=cycles,
                uart_crc_errors=crc_errors)


def self_test():
    if __package__:
        from .stage5a_link_test import self_test as base_test
    else:
        from stage5a_link_test import self_test as base_test
    base_test()
    for dataset in ('cat64','moon','rocket','text'):
        vals,gold=get_inputs(dataset)
        packet_bytes=[]
        for chunk,pload in chunk_generator(vals):
            enc=make_packet(LOAD,0x8000+chunk,pload)
            typ,seq,parsed=unpack_packet(enc)
            assert (typ,seq,parsed)==(LOAD,0x8000+chunk,pload)
            packet_bytes.append(pload[1:])
        rec=b''.join(packet_bytes)
        vals2=list(struct.unpack('<1024I',rec))
        assert vals2==vals
        assert len(gold)==4096
        print(f'PASS: {dataset} 1024 measurements -> 17 packets -> lossless little-endian round-trip')
    flags=1|4
    # Stage-4C core exposes zero-based 39 after the last of 40 rounds.
    status=struct.pack('<BBHIHH',flags,39,1024,242_929_421,0,0)
    decoded=decode_state(status)
    assert decoded['done'] and decoded['ready'] and decoded['measurements_loaded']==1024
    assert decoded['iter']==39 and decoded['completed_outer_iterations']==40
    # A running status is not evidence of completed iterations.
    pending=decode_state(struct.pack('<BBHIHH',2,3,1024,123,0,0))
    assert pending['busy'] and pending['completed_outer_iterations'] is None
    print('PASS: zero-based outer_iter=39 at done means 40 completed rounds')
    print('ALL TESTS PASSED: Stage-5B host protocol and dataset framing')


def query(ser, typ: int, seq: int, content: bytes, expected_type: int, timeout: float=4.0):
    encoded=make_packet(typ,seq,content)
    sent=ser.write(encoded)
    if sent!=len(encoded): raise IOError(f'UART write only {sent}/{len(encoded)} bytes')
    ser.flush()
    answer=read_packet(ser,timeout=timeout)
    rtype,rseq,body=unpack_packet(answer)
    if rtype==ERROR:
        raise RuntimeError(f'FPGA error for type=0x{body[0]:02X}, code={body[1]} (seq=0x{seq:04X})')
    if rseq!=seq or rtype!=expected_type:
        raise AssertionError(f'Response type/seq mismatch: 0x{rtype:02X}/0x{rseq:04X} expected 0x{expected_type:02X}/0x{seq:04X}')
    return body


def save_image(pixels, target: Path):
    # Portable PGM: no Pillow, matplotlib, or display dependency.
    # Q5.11 [0,2048] maps to grayscale [0,255].
    grayscale=bytes(max(0,min(255,(v*255+1024)//2048)) for v in pixels)
    target.write_bytes(b'P5\n64 64\n255\n'+grayscale)
    try:
        from PIL import Image
    except ImportError: return None
    png=target.with_suffix('.png')
    Image.frombytes('L',(64,64),grayscale).save(png)
    return png


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--port',help='Windows serial port, e.g. COM13')
    parser.add_argument('--baud',type=int,default=1_000_000)
    parser.add_argument('--dataset',choices=['cat64','moon','rocket','text'],default='cat64')
    parser.add_argument('--compute-timeout',type=float,default=30.0)
    parser.add_argument('--out',type=Path,default=Path('stage5b_board_results'))
    args=parser.parse_args()
    if args.self_test: self_test(); return
    if not args.port: parser.error('--port COM13 is required for hardware')
    vals,gold=get_inputs(args.dataset)
    try: import serial
    except ImportError: raise SystemExit('Install pyserial: python -m pip install pyserial')
    args.out.mkdir(parents=True,exist_ok=True)
    log={'stage':'5B','dataset':args.dataset,'port':args.port,'baud':args.baud,
         'measurement_count':1024,'pixel_count':4096,'outer_iterations_configured':40,
         'hardware':'AX7020 PL UART TV-FISTA; not a software reconstruction',
         'chunks':[]}
    seq=0x1000
    clock_start=time.monotonic()
    def send(ser,typ,buf,want,timeout=4.0):
        nonlocal seq
        val=query(ser,typ,seq,buf,want,timeout=timeout)
        seq=(seq+1)&0xFFFF
        return val
    print(f'Opening {args.port}, {args.baud} bps, 8N1, dataset={args.dataset}')
    with serial.Serial(args.port,args.baud,bytesize=8,parity='N',stopbits=1,
                       timeout=.05,write_timeout=4.0) as ser:
        time.sleep(.2);ser.reset_input_buffer()
        reported_baud,=struct.unpack('<I',send(ser,STATUS,b'',STATUS_RESP))
        if reported_baud!=args.baud: raise RuntimeError(f'FPGA reports {reported_baud} bps, PC uses {args.baud}')
        print(f'PASS: UART status {reported_baud} bps')
        ack=send(ser,RESET,b'',RESET_ACK)
        assert ack==b'\x00'
        print('PASS: independent compute-core reset')
        tload=time.monotonic()
        for idx,pay in chunk_generator(vals):
            ack=send(ser,LOAD,pay,LOAD_ACK)
            aidx,loaded,status=struct.unpack('<BHB',ack)
            wanted=min((idx+1)*63,1024)
            if (aidx,loaded,status)!=(idx,wanted,0):
                raise RuntimeError(f'LOAD ack failed: got={aidx,loaded,status} expected={idx,wanted,0}')
            log['chunks'].append({'index':idx,'words':(16 if idx==16 else 63),'ack_count':loaded})
        log['load_time_s']=round(time.monotonic()-tload,6)
        state=decode_state(send(ser,GET_STATE,b'',STATE))
        if not state['ready'] or state['measurements_loaded']!=1024:
            raise RuntimeError(f'FPGA not ready after loading: {state}')
        print(f'PASS: 1024/1024 measurement words loaded in 17 CRC-verified packets; {log["load_time_s"]:.3f}s')
        tcalc=time.monotonic()
        assert send(ser,START,b'',START_ACK)==b'\x00'
        deadline=time.monotonic()+args.compute_timeout
        history=[]
        while True:
            state=decode_state(send(ser,GET_STATE,b'',STATE))
            history.append(state)
            if state['range_error'] or state['protocol_error']:
                raise RuntimeError(f'FPGA core error: {state}')
            if state['done']:
                break
            if time.monotonic()>deadline: raise TimeoutError(f'FPGA did not finish: last status {state}')
            time.sleep(.20)
        log['compute_poll_elapsed_s']=round(time.monotonic()-tcalc,6)
        log['compute_cycles']=state['compute_cycles']
        log['compute_time_50mhz_s']=round(state['compute_cycles']/50_000_000,8)
        # Preserve both the raw RTL index and the user-facing completed count.
        log['final_outer_iter_index']=state['iter']
        log['completed_outer_iterations']=state['completed_outer_iterations']
        log['final_outer_iter']=state['completed_outer_iterations']  # legacy JSON key
        log['status_poll_count']=len(history)
        if state['completed_outer_iterations']!=40:
            raise RuntimeError(
                f'FPGA completed {state["completed_outer_iterations"]} outer iterations '
                f'(raw zero-based index={state["iter"]}), expected 40'
            )
        print(f'PASS: FPGA PL completed 40 outer iterations '
              f'(raw final index={state["iter"]}); core cycles={state["compute_cycles"]}')
        tdown=time.monotonic()
        blobs=[]
        for idx in range(32):
            resp=send(ser,READ,bytes([idx]),READ_RESP)
            if len(resp)!=256: raise RuntimeError(f'Result block {idx} bad size {len(resp)}')
            blobs.append(resp)
        raw=b''.join(blobs)
        log['result_read_time_s']=round(time.monotonic()-tdown,6)
        pixels=list(struct.unpack('<4096H',raw))
        (args.out/f'{args.dataset}_fpga_q11_le.bin').write_bytes(raw)
        log['output_sha256']=hashlib.sha256(raw).hexdigest()
        mismatches=[(i,v,gold[i]) for i,v in enumerate(pixels) if v!=gold[i]]
        log['mismatch_count']=len(mismatches)
        log['first_mismatches']=mismatches[:8]
        log['pixel_min']=min(pixels)
        log['pixel_max']=max(pixels)
        log['pixel_sum']=sum(pixels)
        pgm=args.out/f'{args.dataset}_fpga_reconstruction.pgm'
        png=save_image(pixels,pgm)
        log['image_file']=str(png or pgm)
        log['elapsed_s']=round(time.monotonic()-clock_start,6)
        log['all_pass']=(len(mismatches)==0)
        jpath=args.out/f'{args.dataset}_board_verification.json'
        jpath.write_text(json.dumps(log,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        if mismatches:
            print(f'FAIL: {len(mismatches)}/4096 pixels mismatch; examples={mismatches[:8]}')
            print(f'Log saved: {jpath}')
            sys.exit(2)
        print(f'PASS: FPGA reconstructed 4096/4096 exact; range=[{min(pixels)},{max(pixels)}], sum={sum(pixels)}')
        print(f'PASS: Board link load={log["load_time_s"]:.3f}s result={log["result_read_time_s"]:.3f}s')
        print(f'ALL TESTS PASSED: Stage-5B full 40-iteration FPGA hardware reconstruction; report={jpath}')


if __name__=='__main__': main()
