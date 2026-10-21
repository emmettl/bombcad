#!/usr/bin/env python3
"""Measure lossless compression on explicitly selected files, without modifying them."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import statistics
import time
import zlib

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('files',type=Path,nargs='+');p.add_argument('--out',required=True,type=Path)
a=p.parse_args()
rows=[]
for path in a.files:
    raw=path.read_bytes()
    for level in (1,6):
        samples=[]
        for _ in range(3):
            start=time.perf_counter();compressed=zlib.compress(raw,level)
            samples.append(time.perf_counter()-start)
        start=time.perf_counter();restored=zlib.decompress(compressed)
        decode=time.perf_counter()-start
        if restored!=raw: raise RuntimeError('lossless round trip failed')
        rows.append({'file':str(path),'sha256':hashlib.sha256(raw).hexdigest(),
                     'bytes':len(raw),'level':level,'compressedBytes':len(compressed),
                     'ratio':len(raw)/max(1,len(compressed)),'encodeSeconds':samples,
                     'medianEncodeSeconds':statistics.median(samples),'decodeSeconds':decode})
with a.out.open('x') as f:
    json.dump({'date':datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'scope':'Local CPU zlib buffer experiment; not SSH compression or an end-to-end transfer benchmark',
               'samples':rows},f,indent=2);f.write('\n')
for r in rows: print(Path(r['file']).name,r['level'],round(r['ratio'],2),round(r['medianEncodeSeconds'],4))
