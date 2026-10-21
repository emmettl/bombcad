#!/usr/bin/env python3
"""Bounded SSH echo probe; no GPU work or files on the remote host.

Reports application-level round trips, not raw network latency. Run again in a
coordinated quiet window before using these numbers for scheduling decisions.
"""
import argparse
import datetime
import json
import statistics
import re
import signal
import subprocess
import time

REMOTE = '''import sys
r=sys.stdin.buffer; w=sys.stdout.buffer
w.write(b"ready\\n"); w.flush()
while True:
    line=r.readline()
    if not line: break
    n=int(line)
    data=bytearray()
    while len(data)<n:
        part=r.read(n-len(data))
        if not part: raise EOFError()
        data.extend(part)
    w.write(data); w.flush()
'''


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('host'); p.add_argument('--out', required=True)
    p.add_argument('--context', required=True)
    a=p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*',a.host):
        p.error('use a configured SSH host alias')
    from pathlib import Path
    if Path(a.out).exists(): p.error('output must be new')
    ssh=['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10',a.host]
    def snapshot():
        return subprocess.run(ssh+['cat bombcad-ml/lock/owner 2>/dev/null; nvidia-smi --query-gpu=name,memory.used,utilization.gpu --format=csv'],capture_output=True,text=True,timeout=20).stdout
    before=snapshot()
    import shlex
    start=time.perf_counter()
    proc=subprocess.Popen(ssh+['python3 -u -c '+shlex.quote(REMOTE)],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
    def deadline(signum, frame):
        raise TimeoutError('SSH echo exceeded 90 seconds')
    previous=signal.signal(signal.SIGALRM,deadline)
    signal.alarm(90)
    try:
        if proc.stdout.readline()!=b'ready\n': raise RuntimeError('remote did not start')
        setup=time.perf_counter()-start
        rows=[]
        for n,repeats in [(1,20),(65536,5),(1048576,3),(4194304,3)]:
            payload=bytes((i%251 for i in range(n)))
            samples=[]
            for _ in range(repeats):
                start=time.perf_counter()
                proc.stdin.write(str(n).encode()+b'\n'+payload); proc.stdin.flush()
                data=bytearray()
                while len(data)<n:
                    part=proc.stdout.read(n-len(data))
                    if not part: raise EOFError()
                    data.extend(part)
                samples.append(time.perf_counter()-start)
                if data!=payload: raise RuntimeError('echo mismatch')
            median=statistics.median(samples)
            rows.append({'bytesEachDirection':n,'seconds':samples,'medianSeconds':median,
                         'aggregateEchoMiBPerSecond':2*n/median/1048576})
        proc.stdin.close(); proc.wait(timeout=10)
        if proc.returncode: raise RuntimeError('ssh failed')
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM,previous)
        if proc.poll() is None: proc.kill();proc.wait()
    result={'date':datetime.datetime.now(datetime.timezone.utc).isoformat(),'host':a.host,
            'context':a.context,'scope':'SSH application echo, one persistent connection, no compression requested; Python and local pipes included',
            'setupSeconds':setup,'before':before,'after':snapshot(),'samples':rows}
    with open(a.out,'x') as f: json.dump(result,f,indent=2);f.write('\n')
    print(json.dumps(result,indent=2))

if __name__=='__main__': main()
