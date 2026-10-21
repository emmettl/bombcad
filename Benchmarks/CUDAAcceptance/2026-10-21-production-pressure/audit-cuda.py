"""Re-read the remote full-field parity proof and local pressure histories after the CUDA worker ended."""
from pathlib import Path
import hashlib,importlib.util,json,shlex,subprocess,sys
repo=Path.cwd();sys.path.insert(0,str(repo/'Scripts/cuda'));s=importlib.util.spec_from_file_location('queue',repo/'Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
s=importlib.util.spec_from_file_location('phase',repo/'Scripts/cuda/diagnose-phase.py');phase=importlib.util.module_from_spec(s);s.loader.exec_module(phase)
from generate import generate
from trace_columns import trace_source
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-production-pressure-v2');r=q.read(root/'cuda-flat.json');proof=q.read(root/'cuda-flat-numeric-proof.json');assert r['status']=='complete' and not q.group_alive(r['command']['pgid'])
assert r['sourceFileSHA256']==q.digest('/private/tmp/bombcad-pressure/cuda-flat.py')
assert 'dt.npy' in proof['baseline'] and len(proof['baseline'])==12 and set(proof['traced'])-set(proof['baseline'])=={'trace.npy'}
for key,value in proof['baseline'].items():assert proof['traced'][key]==value
for which,key in [('baseline','baselineDirectory'),('traced','tracedDirectory')]:
 directory=proof[key];assert directory.startswith('bombcad-cuda/c58f4f0a7ab5563b/jobs/')
 script="""import pathlib,hashlib,json
p=pathlib.Path.home()/DIRECTORY/'out'
print(json.dumps({str(q.relative_to(p)):hashlib.sha256(q.read_bytes()).hexdigest() for q in p.rglob('*') if q.is_file() and q.suffix in ('.bin','.npy')}))
""".replace('DIRECTORY',repr(directory))
 actual=json.loads(subprocess.check_output(['ssh','-o','BatchMode=yes','bombcad-pc','python3 -c '+shlex.quote(script)],text=True));assert actual==proof[which]
folder=root/'flat-half/cuda-trace';result=q.read(folder/'result.json');source=generate();assert result['sourceSHA256']==hashlib.sha256(source.encode()).hexdigest();assert result['diagnosticSourceSHA256']==hashlib.sha256((source+trace_source(source)).encode()).hexdigest()
assert result['workerFilesSHA256']=={n:q.digest(repo/'Scripts/cuda'/n) for n in ['run.py','job.py','compile.py','trace_columns.py']}
m,d=phase.load(folder);summary=phase.summarize(m,d);assert summary==q.read(folder/'replay.json') and summary['columns'][0]['float32Replay']['recorderValuesDifferent']==0
counter=q.read(root/'phase-decision.json');s=counter['metal']['closingSample'];c=phase.summarize(m,d,{62902:(s,counter['metal']['consumedPressurePa'])})['columns'][0]['specifiedCounterfactual'];assert c==counter['offlineCounterfactual'];assert counter['originalImpulseDifference']>counter['unchangedGateTolerance'] and counter['counterfactualImpulseDifference']<counter['unchangedGateTolerance']
report=dict(status='complete',scope=__doc__,ownedGroupTerminal=True,baselineNumericFilesIndependentlyRehashed=12,tracedNumericFilesIndependentlyRehashed=13,allOriginalNumericFieldsAndTimestepsBitIdentical=True,sourceWorkerDiagnosticProvenanceVerified=True,recorderReplayExact=True,counterfactualCPUOnly=True,originalCUDAAdmissionStillRejected=True)
q.atomic(root/'cuda-audit.json',report);print(json.dumps(report,indent=2))
