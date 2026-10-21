from pathlib import Path
import json,sys,tempfile
sys.path.insert(0,str(Path.cwd()/'Scripts/cuda'))
from test_phase_pressure import replay,write
with tempfile.TemporaryDirectory() as temp:
 folder=Path(temp);meta=dict(format='bombcad-production-pressure-trace-1',complete=True,columns=[0],seedRecords=[[.1,.1,.1,.1,1]],steps=[0,1],times=[0,.125],fields=replay.FIELDS)
 rows=[[0,.1,.1,.1,.1,1,0,0],[0,.1,.1,.1,.1,1,.125,.125]];write(folder,meta,rows)
 m,d=replay.load(folder);report=replay.summarize(m,d);assert report['columns'][0]['exactAccumulationPolicies']==['separate','fused'];print(json.dumps(dict(status='complete',scope='Short JSON decimal seeds round back to float32 before replay; no GPU/solver experiment.',report=report),indent=2))
