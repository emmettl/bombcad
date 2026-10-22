"""Post-hoc independent final-target and whole-output checks; never runs the GPU."""
from pathlib import Path
import json, math, struct, decimal, sys
root=Path(sys.argv[1])
f=json.loads((root/'fixtures.json').read_text()); r=json.loads((root/'gpu.json').read_text())
by={(x['policy'],x['method'],x['observed']):x for x in r['results']}
flags={}
for p in ['default','unfused']:
 flags[p+'UnprotectedEqualsNaiveWholeTraceAndFinal']=all(by[p,'naive',True][k]==by[p,'kahan',True][k] for k in ['traceWords','finalWords'])
flags['allObservationPairsFinalExact']=all(by[p,m,True]['finalWords']==by[p,m,False]['finalWords'] for p in ['default','unfused','safe-unfused'] for m in ['naive','kahan','protected-kahan'])
flags['safeUnprotectedEqualsProtectedWholeTraceAndFinal']=all(by['safe-unfused','kahan',True][k]==by['safe-unfused','protected-kahan',True][k] for k in ['traceWords','finalWords'])
assert all(flags.values())
def val(x):return struct.unpack('<f',struct.pack('<I',x))[0]
decimal.getcontext().prec=80
checks=[]
for s in f['sequences']:
 anchor=val(s['initial']); deltas=[]
 for i,d in enumerate(s['deltas']):
  if str(i) in s['resets']:anchor=val(s['resets'][str(i)]); deltas=[]
  deltas.append(val(d))
 exact=decimal.Decimal.from_float(anchor)+sum(map(decimal.Decimal.from_float,deltas),decimal.Decimal(0))
 target=math.fsum([anchor,*deltas]); assert decimal.Decimal.from_float(target)==exact
 checks.append(dict(case=s['name'],exactFinalTarget=str(exact),doubleFsumTarget=target))
report=dict(status='complete',checks=flags,independentFinalTargets=checks,scope='Post-hoc Decimal exact binary-input final targets; whole trace/final comparisons; independent of the operation-rounded Kahan oracle.')
Path(sys.argv[2]).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
