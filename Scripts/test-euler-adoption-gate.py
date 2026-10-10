#!/usr/bin/env python3
"""Require rejection beyond paired equality, including app-owned staged state/load composition."""
import argparse,copy,importlib.util,json,struct
from pathlib import Path
spec=importlib.util.spec_from_file_location('euler_adoption',Path(__file__).with_name('verify-euler-adoption-output.py'))
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
def native_change(c,axis,value):
 c['amount'][axis]=value;c['bits'][axis+1]=int.from_bytes(struct.pack('>d',value),'big')
def controls(root):
 gate.verify(root);source=json.loads((root/'shared/euler-report.json').read_text());rejected=[]
 labels=['missing run','duplicate identity','missing physical interval','missing native result','missing replay stage','missing reconstruction trace','unaccounted mass','unaccounted energy','wrong first CFL','wrong second CFL','wrong composed wall work','missing native load bit','missing native grid','incomplete member support','missing scattered cell']
 for label in labels:
  d={**source,'runs':list(source['runs'])};idx=next(k for k,r in enumerate(d['runs']) if r['kind']=='group') if label in ['missing native grid','incomplete member support','missing scattered cell'] else next(k for k,r in enumerate(d['runs']) if r['integration']=='ssprk2')
  d['runs'][idx]=copy.deepcopy(d['runs'][idx]);r=d['runs'][idx];f=r['frames'][0]
  if label=='missing run':d['runs'].pop()
  elif label=='duplicate identity':d['runs'][1]=d['runs'][0]
  elif label=='missing physical interval':r['frames'].pop()
  elif label=='missing native result':f['result']['cells'].pop()
  elif label=='missing replay stage':f['second']=None
  elif label=='missing reconstruction trace':f['faces'][0]['left']=None
  elif label=='unaccounted mass':native_change(f['result']['cells'][0],0,f['result']['cells'][0]['amount'][0]*1.1)
  elif label=='unaccounted energy':native_change(f['result']['cells'][0],4,f['result']['cells'][0]['amount'][4]*1.1)
  elif label=='wrong first CFL':f['limit']*=1.1
  elif label=='wrong second CFL':f['stageLimit']*=1.1
  elif label=='wrong composed wall work':
   w=f['result']['loads'][0];w['work']=1.0;w['bits'][3]=int.from_bytes(struct.pack('>d',1.0),'big')
  elif label=='missing native load bit':f['first']['loads'][0]['bits'].pop()
  elif label=='missing native grid':r['nativeGrid'].pop()
  elif label=='incomplete member support':r['members'][0].pop()
  elif label=='missing scattered cell':f['scattered'].pop()
  try:gate.verify(root,d)
  except (ValueError,KeyError,IndexError,TypeError,ZeroDivisionError):rejected.append(label)
  else:raise AssertionError('gate accepted '+label)
 return rejected
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args()
 result={'schemaVersion':1,'status':'passed','rejectedControls':controls(a.root)}
 (a.root/'euler-negative-controls.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
 print('PASS rejected',len(result['rejectedControls']),'complete Euler/staged/native adoption controls')
