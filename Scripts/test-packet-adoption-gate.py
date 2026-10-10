#!/usr/bin/env python3
"""Exercise native history and reservoir/load accounting rejection beyond pair equality."""
import argparse,importlib.util,json,shutil,struct,tempfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('packet_adoption',Path(__file__).with_name('verify-packet-adoption-output.py'));gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
def changed_mass(d):
    s=d['remaps'][0]['frames'][0]['cells'][1];s['amount'][0]*=1.1;s['bits'][1]=int.from_bytes(struct.pack('>d',s['amount'][0]),'big')
def controls(source):
    gate.verify(source)
    mutations={
      'missing moving history':lambda d:d['moving'].pop(),
      'duplicate moving identity':lambda d:d['moving'].__setitem__(1,d['moving'][0]),
      'missing accepted interval':lambda d:d['moving'][0]['frames'].pop(),
      'missing native moving cell':lambda d:d['moving'][0]['frames'][0]['cells'].pop(),
      'missing reservoir lane':lambda d:d['moving'][0]['frames'][0]['reservoirExchange'].pop(),
      'unaccounted reservoir mass':lambda d:d['moving'][0]['frames'][0]['reservoirExchange'].__setitem__(0,1),
      'unaccounted wall work':lambda d:d['moving'][0]['frames'][0]['wallWork'].__setitem__(0,1),
      'missing group support':lambda d:d['moving'][0]['frames'][0]['members'].pop(),
      'missing remap interval':lambda d:d['remaps'][0]['frames'].pop(),
      'unaccounted remap mass':changed_mass,
      'missing crossing case':lambda d:d['pistonCrossing'].pop(),
      'crossing energy loss':lambda d:d['pistonCrossing'][0].__setitem__('energyBudgetResidual',1),
    }
    rejected=[]
    for label,mutation in [*mutations.items(),('wrong packet tag',None)]:
      with tempfile.TemporaryDirectory(prefix='bombcad-packet-gate-') as tmp:
        r=Path(tmp);shutil.copytree(source,r,dirs_exist_ok=True)
        if mutation:
          d=json.loads((r/'shared/packet-report.json').read_text());mutation(d);payload=json.dumps(d)
          for v in ['original','shared']:(r/v/'packet-report.json').write_text(payload)
        else:
          p=r/'environment.json';d=json.loads(p.read_text());d['corePin']['version']='0.1.0-alpha.13';p.write_text(json.dumps(d))
        try:gate.verify(r)
        except (ValueError,KeyError,IndexError):rejected.append(label)
        else:raise AssertionError('gate accepted '+label)
    return rejected
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args();d={'schemaVersion':1,'status':'passed','rejectedControls':controls(a.root)};(a.root/'packet-negative-controls.json').write_text(json.dumps(d,indent=2,sort_keys=True)+'\n');print('PASS rejected',len(d['rejectedControls']),'native packet adoption corruption controls')
