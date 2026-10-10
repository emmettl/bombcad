#!/usr/bin/env python3
import hashlib,json
from pathlib import Path
r=Path(__file__).resolve().parent.parent/'Fixtures/AdiabaticBenchmark'
m=json.loads((r/'packet-source.json').read_text());s=(r/'Sources/AdiabaticAdapter/SourceTransport.swift').read_bytes()
assert hashlib.sha256(s).hexdigest()==m['sourceSHA256']=='9a3bccd54cd6448bb468ccd71e6d0f391ccd6f6f19f9661f6c250f2c9daa02a7'
assert hashlib.sha1(b'blob '+str(len(s)).encode()+b'\0'+s).hexdigest()==m['sourceGitBlob']=='af65c142dbd6dfaffe8ccbb516c0b846d62c4086'
print('PASS protected historical adiabatic packet source; current alias checked separately')
