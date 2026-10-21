"""Profiler orchestration contracts with explicit CPU-only fake workers, not GPU evidence."""
import importlib.util
import itertools
import os
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
if __name__=='__main__':
 import argparse,json
 p=argparse.ArgumentParser();p.add_argument('job');p.add_argument('--source');p.add_argument('--out');p.add_argument('--cache-dir');a=p.parse_args()
 result=run(Path(a.job),Path(a.source),Path(a.out),Path(a.cache_dir) if a.cache_dir else None)
 (Path(a.out)/'result.json').write_text(json.dumps(result));print(json.dumps(result))
'''
        for name in ['baseline','candidate']:
            value="'wrong'" if name=='candidate' and bad_provenance else 'hashlib.sha256(Path(__file__).read_bytes()).hexdigest()'
            (root/(name+'.py')).write_text(worker.replace('HASH',value))
        args=['profile-worker.py','--baseline',str(root/'baseline.py'),'--candidate',str(root/'candidate.py'),'--source',str(source),'--jobs',str(job),'--out',str(root/'out'),'--lock',str(root/'lock'),'--lock-helper',str(helper),*map(str,options)]
        torch=types.SimpleNamespace(__version__='CPU fixture',version=types.SimpleNamespace(cuda=None),cuda=types.SimpleNamespace(init=lambda:None,get_device_name=lambda:'CPU fixture'))
        actual_run=subprocess.run
        def observed_run(command,**kwargs):
            if command[0]=='nvidia-smi':return subprocess.CompletedProcess([],0,stdout='CPU fixture',stderr='')
            return actual_run(command,**kwargs)
        with patch.object(sys,'argv',args), patch.dict(sys.modules,{'torch':torch}), patch.object(module,'elapsed_time',side_effect=lambda:float(next(ticks))), patch.object(module.subprocess,'run',side_effect=observed_run):
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
        for options in [[],['--fresh-process']]:
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temp:
                root=Path(temp)
                with self.assertRaisesRegex(RuntimeError,'provenance differs'):self.profile(root,options,bad_provenance=True)
                self.assertFalse((root/'out/profile.json').exists());self.assertTrue((root/'lock-released').exists())

    def test_fresh_process_routes_distinct_cache_paths_to_real_children(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);a=root/'cache-a';b=root/'cache-b'
            report=self.profile(root,['--fresh-process','--baseline-cache-dir',a,'--candidate-cache-dir',b])
            for name,path in [('baseline',a),('candidate',b)]:
                for repetition in range(3):self.assertEqual((root/f'out/job-{repetition}-{name}/cache.txt').read_text(),str(path))
            self.assertIn('EOF',report['freshProcessObserver'])

    def test_fresh_process_baseline_only_cache_does_not_pass_none_as_path(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);a=root/'cache-a';self.profile(root,['--fresh-process','--baseline-cache-dir',a])
            self.assertEqual((root/'out/job-0-baseline/cache.txt').read_text(),str(a))
            self.assertEqual((root/'out/job-0-candidate/cache.txt').read_text(),'None')

    def runner(self):
        spec=importlib.util.spec_from_file_location('runner_test',Path(__file__).with_name('profile-worker.py'))
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

    def test_runner_drains_output_larger_than_pipe_capacity(self):
        result=self.runner().run_fresh([sys.executable,'-c',"import sys;sys.stdout.write('x'*262144)"])
        self.assertEqual(result.stdout,b'x'*262144)

    def test_runner_propagates_child_failure_with_captured_output(self):
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.runner().run_fresh([sys.executable,'-c',"print('failure evidence');raise SystemExit(7)"])
        self.assertEqual(error.exception.returncode,7);self.assertIn(b'failure evidence',error.exception.stdout)

    def test_runner_timeout_reaps_owned_child(self):
        with tempfile.TemporaryDirectory() as temp:
            pidfile=Path(temp)/'pid'
            code="import os,time;from pathlib import Path;Path(%r).write_text(str(os.getpid()));time.sleep(60)"%str(pidfile)
            with self.assertRaises(subprocess.TimeoutExpired):self.runner().run_fresh([sys.executable,'-c',code],timeout=3)
            pid=int(pidfile.read_text())
            with self.assertRaises(ProcessLookupError):os.kill(pid,0)
