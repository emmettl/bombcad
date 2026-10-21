#!/usr/bin/env python3
"""Send actual recorded thermal cells one way over persistent SSH; verify decoded SHA256.

No remote files or GPU work. Timings include local pipes, SSH, remote decode/hash and
small acknowledgement RTT. They are not raw network bandwidth or CUDA replay timings.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import shlex
import signal
import statistics
import subprocess
import time
import zlib

REMOTE = '''import sys,json,zlib,hashlib,time
r=sys.stdin.buffer; w=sys.stdout
print('ready',flush=True)
while True:
    line=r.readline()
    if not line: break
    h=json.loads(line); start=time.perf_counter(); data=bytearray()
    while len(data)<h['bytes']:
        part=r.read(h['bytes']-len(data))
        if not part: raise EOFError()
        data.extend(part)
    received=time.perf_counter()-start; start=time.perf_counter()
    raw=zlib.decompress(data) if h['compressed'] else data
    digest=hashlib.sha256(raw).hexdigest()
    print(json.dumps(dict(sha256=digest,rawBytes=len(raw),receiveSeconds=received,
         decodeHashSeconds=time.perf_counter()-start)),flush=True)
'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('host')
    p.add_argument('recording', type=Path)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--context', required=True)
    p.add_argument('--sequence', action='store_true', help='also send a length-prefixed complete input batch, compressed only')
    a = p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', a.host):
        p.error('use a configured SSH alias')
    if a.out.exists():
        p.error('output must be new')
    frames = json.loads((a.recording / 'frames.json').read_text())
    positive = [f for f in frames if f['cellBytes'] > 32]
    if not positive:
        p.error('recording has no luminous cells')
    ordered = sorted(positive, key=lambda f: f['cellBytes'])
    selected = sorted(set(f['index'] for f in (positive[0], ordered[len(ordered)//2], ordered[-1], positive[-1])))
    ssh = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', a.host]
    def snapshot():
        return subprocess.run(ssh + ['cat bombcad-ml/lock/owner 2>/dev/null; nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader'], capture_output=True, text=True, timeout=20).stdout
    before = snapshot()
    started = time.perf_counter()
    proc = subprocess.Popen(ssh + ['python3 -u -c ' + shlex.quote(REMOTE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    def deadline(*_):
        raise TimeoutError('thermal transfer probe exceeded 180 seconds')
    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(180)
    rows = []
    try:
        if proc.stdout.readline() != b'ready\n':
            raise RuntimeError('receiver did not start')
        setup = time.perf_counter() - started
        for index in selected + (['sequence'] if a.sequence else []):
            if index == 'sequence':
                names = ['setup.json', 'frames.json'] + [f'{i:05d}.{ext}' for i in range(len(frames)) for ext in ('json', 'bin')]
                chunks = [(a.recording / name).read_bytes() for name in names]
                raw = b''.join(len(chunk).to_bytes(8, 'little') + chunk for chunk in chunks)
            else:
                raw = (a.recording / f'{index:05d}.bin').read_bytes()
            if len(raw) > (512 * 1048576 if index == 'sequence' else 7 * 1048576 + 32):
                raise ValueError('payload exceeds current cell limit')
            digest = hashlib.sha256(raw).hexdigest()
            for level in ((1, 6) if index == 'sequence' else (0, 1, 6)):
                start = time.perf_counter()
                payload = zlib.compress(raw, level) if level else raw
                encoding = time.perf_counter() - start
                samples = []
                for _ in range(3):
                    start = time.perf_counter()
                    proc.stdin.write(json.dumps(dict(bytes=len(payload), compressed=bool(level))).encode() + b'\n')
                    proc.stdin.write(payload)
                    proc.stdin.flush()
                    ack = json.loads(proc.stdout.readline())
                    elapsed = time.perf_counter() - start
                    if ack['sha256'] != digest or ack['rawBytes'] != len(raw):
                        raise RuntimeError('decoded payload mismatch')
                    samples.append(dict(seconds=elapsed, **ack))
                rows.append(dict(index=index, time=None if index == 'sequence' else frames[index]['time'], rawBytes=len(raw), sha256=digest,
                                 level=level, wireBytes=len(payload), encodingSeconds=encoding,
                                 medianSeconds=statistics.median(s['seconds'] for s in samples), samples=samples))
        proc.stdin.close()
        proc.wait(timeout=10)
        if proc.returncode:
            raise RuntimeError('SSH failed')
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    totals = dict(setupBytes=(a.recording / 'setup.json').stat().st_size,
                  frameJSONBytes=sum((a.recording / f'{i:05d}.json').stat().st_size for i in range(len(frames))),
                  cellBytes=sum(f['cellBytes'] for f in frames),
                  localConsumerSeconds=sum(f['localConsumerSeconds'] for f in frames),
                  extractionSeconds=sum(f['extractionSeconds'] for f in frames),
                  encodingWriteSeconds=sum(f['encodingSeconds'] for f in frames))
    result = dict(date=datetime.datetime.now(datetime.timezone.utc).isoformat(), host=a.host, context=a.context, totals=totals,
                  scope=__doc__, before=before, after=snapshot(), setupSeconds=setup,
                  selectedIndices=selected, frames=frames, samples=rows)
    with a.out.open('x') as f:
        json.dump(result, f, indent=2)
        f.write('\n')
    print(json.dumps(dict(selectedIndices=selected, samples=[{k:v for k,v in r.items() if k != 'samples'} for r in rows]), indent=2))


if __name__ == '__main__':
    main()
