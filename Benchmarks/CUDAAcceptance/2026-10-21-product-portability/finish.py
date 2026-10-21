"""Resume only saved-output analysis and finalize terminal experiment state."""
import importlib.util,json,sys
from pathlib import Path
sys.path.insert(0,'Scripts/cuda');s=importlib.util.spec_from_file_location('q','Scripts/cuda/field-queue.py');q=importlib.util.module_from_spec(s);s.loader.exec_module(q)
root=Path('/Volumes/StudioData/bombcad/experiments/2026-10-21-product-portability-v4');r=q.read(root/'study.json');a=q.read(root/'analysis.json');control=q.read(root/'lf-control.json')
assert r['error']=="KeyError('roof')" and a['status']=='complete' and a['identicalControl'] and control['status']=='complete'
assert 'if code:report' in Path('/private/tmp/bombcad-product-portability/study.py').read_text()
terminal=[]
for folder in [root.parent/'2026-10-21-product-portability-v2',root.parent/'2026-10-21-product-portability-v3',root]:
 p=q.read(folder/'study.json')['process'];assert not q.group_alive(p['pgid']);terminal.append(dict(folder=str(folder),**p,alive=False))
p=q.read(root/'lf-process.json');assert not q.group_alive(p['pgid']);terminal.append(dict(control='LF',**p,alive=False))
(root/'controller-postprocess-failed.json').write_text(json.dumps(r,indent=2)+'\n')
r.update(status='complete',buildings=a['buildings'],controllerPostprocessError=r.pop('error'),judgingReturnEvidence='Controller reached the roof-key postprocessing error after its explicit nonzero-return guard. It had not saved returncode before the wrapper reread state; zero is inferred from that pinned control flow, not a contemporaneously saved returncode receipt.',analysisResume='Separate saved-output audit handles omitted optional roof keys. No original judgement relaunch.',analysis='analysis.json',lfControl=control,terminalOwnedGroups=terminal)
(root/'study.json').write_text(json.dumps(r,indent=2)+'\n')
print('Completed saved-output analysis; four owned CLI groups terminal, two successful judgements and two retained CSV failures')
