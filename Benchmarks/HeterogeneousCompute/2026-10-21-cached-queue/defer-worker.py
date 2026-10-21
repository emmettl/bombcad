import sys,importlib.util,json
from pathlib import Path
sys.path.insert(0,str(Path('Scripts/cuda').resolve()))
s=importlib.util.spec_from_file_location('queue','Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
original=q.pc_snapshot;calls=0
def observed(contract):
 global calls
 calls+=1
 if calls==2:return {'available':False,'freeBytes':0,'reason':'explicit post-preparation deferral control, no external workload'}
 return original(contract)
q.pc_snapshot=observed
raise SystemExit(q.worker(Path(sys.argv[2]),sys.argv[3],sys.argv[4]))
