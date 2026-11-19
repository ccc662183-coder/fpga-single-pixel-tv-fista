#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AX7020 Stage-5A UART packet link: query baud, binary echo and CRC16 checks.

Uses the unchanged packet format of user's verified UART Experiment 1.
This is a COMMUNICATION LINK test, not a TV-FISTA reconstruction test.
Requires: pip install pyserial  (only for hardware mode)

Offline: python scripts/stage5a_link_test.py --self-test
Board:   python scripts/stage5a_link_test.py --port COM13 --baud 1000000
"""
from __future__ import annotations
import argparse
import hashlib
import json
import random
import struct
import time
from pathlib import Path

SYNC = b"\xA5\x5A"
VERSION = 1
STATUS = 0x10
STATUS_RESP = 0x11
DATA = 0x20
DATA_ECHO = 0x21
MAX_PAYLOAD = 256


def crc16_ccitt_false(payload: bytes) -> int:
    crc = 0xFFFF
    for val in payload:
        crc ^= val << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x1021 if (crc & 0x8000) else 0)) & 0xFFFF
    return crc


def make_packet(typ: int, seq: int, payload: bytes) -> bytes:
    if not 0 <= typ <= 255 or not 0 <= seq <= 65535:
        raise ValueError("type or sequence out of range")
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("packet payload longer than 256 bytes")
    body = bytes([VERSION, typ]) + struct.pack("<HH", seq, len(payload)) + payload
    return SYNC + body + struct.pack("<H", crc16_ccitt_false(body))


def unpack_packet(packet: bytes):
    if len(packet) < 10 or not packet.startswith(SYNC) or packet[2] != VERSION:
        raise ValueError("bad synchronization/version")
    typ, seq, size = struct.unpack_from("<BHH", packet, 3)
    if size > MAX_PAYLOAD or len(packet) != size + 10:
        raise ValueError("bad payload length")
    want_crc = crc16_ccitt_false(packet[2:-2])
    got_crc, = struct.unpack_from("<H", packet, len(packet)-2)
    if want_crc != got_crc:
        raise ValueError("CRC mismatch: received %04X expected %04X" % (got_crc, want_crc))
    return typ, seq, packet[8:-2]


def read_exact(ser, n: int, deadline: float) -> bytes:
    chunks = bytearray()
    while len(chunks) < n:
        if time.monotonic() > deadline:
            raise TimeoutError("serial read timeout: got %d/%d bytes" % (len(chunks), n))
        b = ser.read(n-len(chunks))
        if b:
            chunks.extend(b)
    return bytes(chunks)


def read_packet(ser, timeout: float = 3.0) -> bytes:
    end = time.monotonic() + timeout
    # Robust synchronization; a stray leading A5 can be another sync start.
    state = 0
    while True:
        value = read_exact(ser, 1, end)[0]
        if state == 0:
            state = int(value == 0xA5)
        elif value == 0x5A:
            break
        else:
            state = int(value == 0xA5)
    hdr = read_exact(ser, 6, end)  # ver,type,seqLE,lenLE
    version, typ, seq, length = struct.unpack("<BBHH", hdr)
    if version != VERSION or length > MAX_PAYLOAD:
        raise ValueError("unexpected frame header: ver=%d len=%d" % (version, length))
    tail = read_exact(ser, length+2, end)
    packet = SYNC + hdr + tail
    unpack_packet(packet)
    return packet


def request(ser, typ: int, seq: int, data: bytes, expected_type: int, timeout=3.0):
    packet = make_packet(typ, seq, data)
    count = ser.write(packet)
    if count != len(packet):
        raise IOError("partial serial write")
    ser.flush()
    response = read_packet(ser, timeout=timeout)
    got_type, got_seq, got_data = unpack_packet(response)
    if got_seq != seq or got_type != expected_type:
        raise AssertionError("response type/seq mismatch: %02X/%04X" % (got_type, got_seq))
    return got_data, len(packet), len(response)


def self_test():
    assert crc16_ccitt_false(b"123456789") == 0x29B1
    assert len(make_packet(STATUS, 0x1201, b"")) == 10
    for size in [0,1,8,64,256]:
        source = bytes(((i * 73 + 19) ^ (i >> 3)) & 255 for i in range(size))
        encoded = make_packet(DATA, 0x2345, source)
        assert unpack_packet(encoded) == (DATA, 0x2345, source)
        broken = bytearray(encoded); broken[-1] ^= 0x01
        try:
            unpack_packet(bytes(broken))
        except ValueError:
            pass
        else:
            raise AssertionError("CRC corruption was not detected")
    print("PASS: CRC16-CCITT-FALSE 123456789 -> 0x29B1")
    print("PASS: packet encode/decode lengths 0, 1, 8, 64, 256")
    print("PASS: corrupted CRC rejected")
    print("ALL TESTS PASSED: Stage-5A host-side protocol self-test")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--port", help="Windows COM port, e.g. COM13")
    parser.add_argument("--baud", type=int, default=1_000_000)
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--report", type=Path, default=Path("stage5a_link_results.json"))
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.port:
        parser.error("--port COM13 is required for hardware mode")
    if args.rounds < 1:
        parser.error("--rounds must be at least 1")
    try:
        import serial  # type: ignore
    except ImportError as exc:
        raise SystemExit("pyserial not installed. Execute: python -m pip install pyserial") from exc
    print("Opening %s, %d bps, 8N1" % (args.port, args.baud))
    report = {"stage":"5A", "port":args.port, "baud_bps":args.baud,
              "kind":"UART framed DATA_ECHO only; NOT FPGA image reconstruction", "cases":[]}
    start = time.monotonic()
    with serial.Serial(args.port, args.baud, bytesize=8, parity='N', stopbits=1,
                       timeout=0.05, write_timeout=3.0) as ser:
        time.sleep(0.2)
        ser.reset_input_buffer()
        status, tx, rx = request(ser, STATUS, 1, b"", STATUS_RESP)
        if len(status) != 4:
            raise AssertionError("expected 4-byte STATUS payload")
        fpga_baud, = struct.unpack("<I",status)
        if fpga_baud != args.baud:
            raise AssertionError("FPGA active_baud=%d, PC baud=%d; do NOT continue" % (fpga_baud,args.baud))
        print("PASS: FPGA STATUS reports %d bps" % fpga_baud)
        report["fpga_active_baud_bps"] = fpga_baud
        sequence = 2
        for round_idx in range(args.rounds):
            for size in [0,8,64,256]:
                # deterministic and diverse binary, including A5 5A marker values.
                rng=random.Random(0x5A50 + round_idx*1000 + size)
                payload=bytes(rng.randrange(256) for _ in range(size))
                if size >= 8:
                    payload = b"\xA5\x5A\x00\xFF" + payload[4:]
                t0=time.monotonic()
                result, n_req, n_resp = request(ser, DATA, sequence, payload, DATA_ECHO)
                elapsed=time.monotonic()-t0
                if result != payload:
                    raise AssertionError("echo mismatch at round=%d len=%d seq=%04X" % (round_idx,size,sequence))
                digest=hashlib.sha256(payload).hexdigest()
                report['cases'].append({"round":round_idx+1,"payload_bytes":size,"sequence":sequence,
                         "sha256":digest,"request_wire_bytes":n_req,"response_wire_bytes":n_resp,
                         "elapsed_s":round(elapsed,6),"pass":True})
                print("PASS: binary DATA_ECHO round=%d len=%d seq=%04X time=%.3fs" % (round_idx+1,size,sequence,elapsed))
                sequence=(sequence+1)&0xFFFF
    report['elapsed_s']=round(time.monotonic()-start,6)
    report['total_echo_payload_bytes']=sum(x['payload_bytes'] for x in report['cases'])
    report['all_pass']=True
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print("ALL TESTS PASSED: Stage-5A physical UART echo link; report=%s" % args.report)


if __name__ == '__main__':
    main()
