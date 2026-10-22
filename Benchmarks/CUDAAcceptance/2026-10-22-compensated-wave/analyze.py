"""Single-attempt terminal-producer analysis pipeline with explicit byte checks."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys


def main(root,baseline):
    root=Path(root).resolve();here=root/'analysis'
    spec=importlib.util.spec_from_file_location('owned',here/'run.py');owned=importlib.util.module_from_spec(spec);spec.loader.exec_module(owned)
    source=json.loads((root/'run.json').read_text())
    assert source['status'] in ['complete','complete-with-failures'] and 'liveProcess' not in source
    assert len(source['commands'])==432 and all('terminalProcess' in c for c in source['commands'])
    report=dict(status='running',controller=dict(pid=os.getpid(),boot=owned.boot_id(),identity=owned.process_snapshot(os.getpid())),
                pipelineSHA256=owned.digest(__file__),stages=[])
    receipt=root/'analysis-pipeline.json';assert not receipt.exists()
    def verify():
        for item in source['frozenSources']:assert owned.digest(item['path'])==item['sha256']
        for category,directory in [('runtimeSHA256',root/'runtime'),('analysisSHA256',here)]:
            for name,pin in source[category].items():assert owned.digest(directory/name)==pin
        for name,pin in source['originalResourceSHA256'].items():assert owned.digest(name)==pin
        for pin in source['environment']['runtimeBytePins']:
            assert owned.digest(pin['original'])==owned.digest(pin['snapshot'])==pin['sha256']
        amendment=json.loads((root/'analysis-amendment.json').read_text())
        assert hashlib.sha256(json.dumps(source['analysisSHA256'],sort_keys=True).encode()).hexdigest()==amendment['originalRunAnalysisManifestSHA256']
        for name,pin in amendment['additionalSHA256'].items():assert owned.digest(here/name)==pin
    def save():owned.atomic(receipt,report)
    audit=root/'audit-v2'
    stages=[('audit',[sys.executable,str(here/'audit-v2.py'),str(root),str(audit)]),
            ('oracles',[sys.executable,str(here/'oracles.py'),str(root),str(audit)]),
            ('finalize',[sys.executable,str(here/'finalize.py'),str(audit)]),
            ('summarize',[sys.executable,str(here/'summarize.py'),str(audit/'final.json'),str(Path(baseline).resolve()),str(audit/'summary.json')])]
    save()
    try:
        for label,command in stages:
            verify()
            entry=dict(stage=label,command=command,status='running');report['stages'].append(entry);save()
            with (root/'logs'/('analysis-'+label+'.log')).open('xb') as log:
                child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
                entry['process']=dict(pid=child.pid,boot=owned.boot_id(),identity=owned.process_snapshot(child.pid));save()
                entry['returncode']=child.wait()
            entry['status']='complete' if entry['returncode']==0 else 'failed';save()
            if entry['returncode']:raise RuntimeError('analysis stage failed: '+label)
            verify()
        report['status']='complete';report['allByteChecksPassed']=True
    except BaseException as error:
        report.update(status='failed',error=repr(error));raise
    finally:save()


if __name__=='__main__':main(*sys.argv[1:])
