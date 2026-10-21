"""Profiler orchestration contracts with explicit CPU-only fake workers, not GPU evidence."""
import importlib.util
import itertools
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


class ProfileWorkerTests(unittest.TestCase):
    def profile(self,root,options=(),bad_provenance=False):
        spec=importlib.util.spec_from_file_location('profile_test',Path(__file__).with_name('profile-worker.py'))
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        helper=root/'lock.py';helper.write_text('from pathlib import Path\ndef acquire(*a): return True\ndef boot_id(): return "fixture"\ndef release(p): Path(p+"-released").touch()\n')
        source=root/'source.cu';source.write_text('CPU orchestration fixture, not CUDA')
        job=root/'job';job.mkdir();(job/'job.json').write_text('{}')
        worker='''import hashlib
from pathlib import Path
def run(job,source,out,cache_dir=None):
 out.mkdir();(out/'dt.npy').write_bytes(b'CPU orchestration fixture')
 (out/'cache.txt').write_text(str(cache_dir))
 return dict(wallSeconds=.1,steps=1,elapsedSimulationTime=.01,workerFilesSHA256={'run.py':HASH})
'''
        for name in ['baseline','candidate']:
            value="'wrong'" if name=='candidate' and bad_provenance else 'hashlib.sha256(Path(__file__).read_bytes()).hexdigest()'
            (root/(name+'.py')).write_text(worker.replace('HASH',value))
        args=['profile-worker.py','--baseline',str(root/'baseline.py'),'--candidate',str(root/'candidate.py'),'--source',str(source),'--jobs',str(job),'--out',str(root/'out'),'--lock',str(root/'lock'),'--lock-helper',str(helper),*map(str,options)]
        torch=types.SimpleNamespace(__version__='CPU fixture',version=types.SimpleNamespace(cuda=None),cuda=types.SimpleNamespace(init=lambda:None,get_device_name=lambda:'CPU fixture'))
        with patch.object(sys,'argv',args), patch.dict(sys.modules,{'torch':torch}), patch.object(module,'elapsed_time',side_effect=lambda:float(next(ticks))), patch.object(module.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout='CPU fixture',stderr='')):
            ticks=itertools.count();module.main()
        return json.loads((root/'out/profile.json').read_text())

    def test_symmetric_cache_paths_reach_each_worker_and_report(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);a=root/'cache-a';b=root/'cache-b'
            report=self.profile(root,['--baseline-cache-dir',a,'--candidate-cache-dir',b])
            self.assertEqual(report['baselineCacheDir'],str(a));self.assertEqual(report['candidateCacheDir'],str(b))
            for name,path in [('baseline',a),('candidate',b)]:
                for repetition in range(3):self.assertEqual((root/f'out/job-{repetition}-{name}/cache.txt').read_text(),str(path))
            self.assertTrue(report['allOutputsAndTimestepsBitIdentical'])
            self.assertTrue((root/'lock-released').exists())

    def test_candidate_only_cache_preserves_uncached_baseline(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);report=self.profile(root,['--candidate-cache-dir',root/'cache'])
            self.assertIsNone(report['baselineCacheDir'])
            self.assertEqual((root/'out/job-0-baseline/cache.txt').read_text(),'None')

    def test_false_worker_provenance_rejects_report_and_releases_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            with self.assertRaisesRegex(RuntimeError,'provenance differs'):self.profile(root,bad_provenance=True)
            self.assertFalse((root/'out/profile.json').exists());self.assertTrue((root/'lock-released').exists())
