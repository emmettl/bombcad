#!/usr/bin/env python3
import json,sys
from pathlib import Path
r=Path(sys.argv[1]);old=json.loads((r/'results.json').read_text());new=json.loads((r/'shared/results.json').read_text())
def records(rows):return sorted([(x['caseSpecification']['id'],x['steps'],x['samples']) for x in rows],key=lambda x:x[:2])
assert records(old)==records(new),'full historical/current adiabatic sample mismatch'
pins=json.loads((r/'shared/consumer-Package.resolved').read_text())['pins'];assert any(p['identity']=='continuumkit' and p['state']=={'version':'0.1.0-alpha.14','revision':'f5543e3c336a80ec86868c3f0f245b688dfba148'} for p in pins)
print('PASS complete historical/current adiabatic samples and exact alpha.14 production binding')
