#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Offline regression; MOCK TRANSPORT ONLY. Never proves physical FPGA operation."""
from __future__ import annotations
import io,struct,sys,tempfile
from pathlib import Path
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from scripts.image_pipeline import (
    DATA, MASK, MASK_SHA256, builtin_dataset, user_image_dataset,
    read_external_words, external_measurement_dataset, make_measurements,
    direct_backprojection, pixels_q11_to_u8, signed_measurements, write_mem)
from scripts.board_session import run_board_session
from scripts.stage5b_reconstruct import (
    RESET,RESET_ACK,LOAD,LOAD_ACK,START,START_ACK,GET_STATE,STATE,
    READ,READ_RESP,STATUS,STATUS_RESP,ERROR)
from scripts.stage5a_link_test import make_packet,unpack_packet,crc16_ccitt_false

class MockSerial:
    """Synthetic packet responder, intentionally separate from real serial mode."""
    port='MOCK-NO-HARDWARE'
    def __init__(self, expected):
        self._pending=bytearray()
        self.expected=expected
        self.measurements=[];self.packet_count=0;self.read_count=0;self.started=False
    def reset_input_buffer(self):self._pending.clear()
    def flush(self):pass
    def write(self,packet):
        t,seq,payload=unpack_packet(packet)
        if t==STATUS:resp=struct.pack('<I',1_000_000);response=STATUS_RESP
        elif t==RESET:
            self.measurements=[];self.started=False;resp=b'\0';response=RESET_ACK
        elif t==LOAD:
            idx=payload[0];assert idx==self.packet_count
            self.measurements.extend(struct.unpack('<'+'I'*((len(payload)-1)//4),payload[1:]))
            self.packet_count+=1
            resp=struct.pack('<BHB',idx,len(self.measurements),0);response=LOAD_ACK
        elif t==GET_STATE:
            flags=(1|4) if self.started else 1
            resp=struct.pack('<BBHIHH',flags,39 if self.started else 0,
                             len(self.measurements),242929421 if self.started else 0,0,0)
            response=STATE
        elif t==START:
            assert len(self.measurements)==1024
            self.started=True;resp=b'\0';response=START_ACK
        elif t==READ:
            assert self.started
            idx=payload[0];assert idx==self.read_count
            resp=struct.pack('<128H',*self.expected[idx*128:(idx+1)*128]);response=READ_RESP
            self.read_count+=1
        else:raise AssertionError(f'Unknown type 0x{t:02x}')
        self._pending+=make_packet(response,seq,resp)
        return len(packet)
    def read(self,n):
        chunk=bytes(self._pending[:n]);del self._pending[:n]
        return chunk


def run():
    assert int(MASK.sum())==1024
    assert crc16_ccitt_false(b'123456789')==0x29B1
    print('PASS: fixed 1024/4096 Hadamard low-sequency mask and CRC16 protocol')
    for name in ('cat64','moon','rocket','text'):
        ds=builtin_dataset(name)
        assert len(ds.words)==1024 and len(ds.golden)==4096
        assert make_measurements(ds.image_u8)==ds.words
        assert ds.direct_q11.shape==(64,64)
        assert pixels_q11_to_u8(ds.golden).shape==(64,64)
        assert all(0<=v<2**32 for v in ds.words)
        print(f'PASS: {name} 1024/1024 image->Hadamard Q11 measurements exact')
    print('PASS: 4/4 frozen measurement vectors regenerated pixel-to-measurement exactly')
    cat=builtin_dataset('cat64')
    fake=MockSerial(cat.golden)
    report=run_board_session(fake,cat,progress=lambda _a,_b:None)
    assert fake.packet_count==17 and fake.read_count==32
    assert fake.measurements==cat.words
    assert report['pixels']==cat.golden
    assert report['report']['compute_cycles']==242929421
    assert report['report']['golden_matched_pixels']==4096
    assert report['report']['completed_outer_iterations']==40
    print('PASS: MOCK ONLY 17 LOAD packets / 32 READ packets / state index 39->40 / 4096 golden outputs')
    corrupted=cat.golden[:];corrupted[42]+=1
    fake2=MockSerial(corrupted)
    report2=run_board_session(fake2,cat)
    assert report2['report']['golden_mismatch_count']==1 and not report2['report']['all_pass']
    print('PASS: MOCK ONLY corrupted output pixel detected as FAIL (not silently accepted)')
    with tempfile.TemporaryDirectory() as td:
        directory=Path(td)
        fn=directory/'external.mem';write_mem(fn,cat.words,32)
        assert read_external_words(fn)==cat.words
        try:external_measurement_dataset(fn,operator_confirmed=False)
        except ValueError:pass
        else:raise AssertionError('Expected explicit external measurement compatibility confirmation')
        ext=external_measurement_dataset(fn,operator_confirmed=True)
        assert ext.golden is None and ext.image_u8 is None
        csv=directory/'external.csv'
        csv.write_text(','.join(str(v-2**32 if v>=2**31 else v) for v in cat.words))
        assert read_external_words(csv)==cat.words
        npy=directory/'external.npy';np.save(npy,signed_measurements(cat.words).astype(np.int32))
        assert read_external_words(npy)==cat.words
        print('PASS: .mem / .csv / .npy external Q11 parse and provenance/compatibility gate')
    print('ALL TESTS PASSED: Stage-5D offline host/measurement regression (NO REAL FPGA involved)')

if __name__=='__main__':run()
