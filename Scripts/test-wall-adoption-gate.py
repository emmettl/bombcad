#!/usr/bin/env python3
"""Exercise completeness and conservation rejection using real retained reports."""
import argparse
import importlib.util
import json
import shutil
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("wall_gate", Path(__file__).with_name("verify-wall-adoption-output.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

def controls(source):
    gate.verify(source)
    cases = {
        "missing wall state": lambda d: d['wallCases'].pop(),
        "duplicate reflection input": lambda d: d['reflection'].__setitem__(1, d['reflection'][0]),
        "missing reflection clock": lambda d: d['reflection'][0]['frames'].pop(),
        "reflection energy loss": lambda d: d['reflection'][0].__setitem__('relativeEnergyChange', .1),
        "missing native frame": lambda d: d['pistons'][0]['frames'].pop(),
        "missing accepted interval": lambda d: d['pistons'][0]['intervals'].pop(),
        "discontinuous accepted clock": lambda d: d['pistons'][0]['intervals'][0].__setitem__('time', .1),
        "unaccounted gas energy": lambda d: d['pistons'][0]['cells'][0]['amount'].__setitem__(4, 1000000),
        "nonpositive native volume": lambda d: d['pistons'][0]['frames'][0]['cells'][0].__setitem__('volume', 0),
    }
    passed=[]
    for label, mutate in [*cases.items(), ('changed shared report',None), ('wrong release pin',None), ('dirty producer',None)]:
        with tempfile.TemporaryDirectory(prefix='bombcad-wall-gate-control-') as tmp:
            root=Path(tmp)
            shutil.copytree(source,root,dirs_exist_ok=True)
            if mutate:
                d=json.loads((root/'shared/report.json').read_text());mutate(d)
                # Alter BOTH copies to test independent gates, beyond pair equality.
                payload=json.dumps(d).encode()
                for variant in ['original','shared']:(root/variant/'report.json').write_bytes(payload)
            elif label=='changed shared report':
                with (root/'shared/report.json').open('ab') as f:f.write(b' ')
            elif label=='wrong release pin':
                p=root/'shared/consumer-Package.resolved';d=json.loads(p.read_text());d['pins'][0]['state']['version']='0.1.0-alpha.5';p.write_text(json.dumps(d))
            else:
                p=root/'environment.json';d=json.loads(p.read_text());d['workingTreeDirty']=True;p.write_text(json.dumps(d))
            try:gate.verify(root)
            except (ValueError,KeyError,IndexError):passed.append(label)
            else:raise AssertionError('gate accepted control: '+label)
    return passed

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args()
    result={'schemaVersion':1,'status':'passed','rejectedControls':controls(a.root)}
    (a.root/'negative-controls.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
    print('PASS rejected',len(result['rejectedControls']),'completeness, conservation, pin and producer controls')
