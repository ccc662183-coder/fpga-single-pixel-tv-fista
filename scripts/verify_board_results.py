from hashlib import sha256
import json
from pathlib import Path
import struct


ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / 'results'
GOLDEN = ROOT / 'stages/stage5b_uart_fista/data'


def main():
    matched = 0
    for name in ('cat64', 'moon', 'rocket', 'text'):
        report = json.loads((RESULTS / 'board' / f'{name}_board_verification.json').read_text(encoding='utf-8'))
        gui = json.loads((RESULTS / 'gui' / f'{name}_board_summary.json').read_text(encoding='utf-8'))
        payload = (RESULTS / 'board' / f'{name}_fpga_q11_le.bin').read_bytes()
        pixels = struct.unpack('<4096H', payload)
        expected = tuple(int(word, 16) for word in (GOLDEN / f'{name}_expected_final_q11_s16.mem').read_text().split())
        if pixels != expected or sha256(payload).hexdigest() != report['output_sha256'] or gui['output_sha256'] != report['output_sha256']:
            raise ValueError(f'Golden, result bytes or archived digest differ: {name}')
        if not (report['all_pass'] and report['mismatch_count'] == 0 and report['completed_outer_iterations'] == 40
                and gui['all_pass'] and gui['golden_matched_pixels'] == len(pixels)
                and gui['completed_outer_iterations'] == 40):
            raise ValueError(f'Archived protocol/result status does not satisfy 40-iteration acceptance: {name}')
        matched += len(pixels)
        print(f'PASS: {name}: {len(pixels)}/{len(expected)} pixels exact')
    print(f'PASS: {matched}/{matched} pixels exact (archived board output; no new board run)')


if __name__ == '__main__':
    main()
