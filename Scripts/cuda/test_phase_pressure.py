"""Consumed-pressure format, initialization and exact arithmetic controls; CPU only."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('pressure_replay',Path(__file__).with_name('diagnose-phase.py'))
replay=importlib.util.module_from_spec(spec);spec.loader.exec_module(replay)


def write(folder,meta,rows):
    (folder/'pressure-trace.json').write_text(json.dumps(meta))
    header=repr(dict(descr='<f4',fortran_order=False,shape=(len(rows),1,8)))
    encoded=header.encode();encoded+=b' '*((64-(10+len(encoded)+1)%64)%64)+b'\n'
    data=[v for row in rows for v in row]
    (folder/'pressure-trace.npy').write_bytes(b'\x93NUMPY\x01\x00'+struct.pack('<H',len(encoded))+encoded+struct.pack('<'+'f'*len(data),*data))


class PhasePressureTests(unittest.TestCase):
    def fixture(self,folder):
        meta=dict(format='bombcad-production-pressure-trace-1',complete=True,columns=[17],
                  seedRecords=[[4,.5,.5,4,1]],steps=list(range(5)),times=[0,.125,.25,.375,.5],fields=replay.FIELDS)
        rows=[[-1,4,.5,.5,4,0,0,0], [12,12,2,2,12,1,.125,.125],
              [0,12,2,2,12,1,.125,.25], [-1,12,2,2,12,0,.125,.375],
              [3,12,2.375,2,12,0,.125,.5]]
        write(folder,meta,rows)
        return meta,rows

    def test_seeded_zero_dt_initial_close_and_later_phase_reopen(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);self.fixture(folder);meta,data=replay.load(folder)
            result=replay.summarize(meta,data)['columns'][0]
            self.assertEqual(result['float32Replay']['recorderValuesDifferent'],0)
            self.assertEqual(result['float32Replay']['closingSamples'],[0,3])
            self.assertEqual(result['float32Replay']['finalFirstPhaseImpulse'],2)
            self.assertEqual(result['exactAccumulationPolicies'],['separate','fused'])

    def test_fused_accumulation_is_checked_without_tolerance_or_per_step_switching(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);eps=2**-23;small=2**-24
            meta=dict(format='bombcad-production-pressure-trace-1',complete=True,columns=[17],
                      seedRecords=[[1,small,small,1,1]],steps=[0,1],times=[0,1+eps],fields=replay.FIELDS)
            rows=[[0,1,small,small,1,1,0,0],
                  [1+eps,1+eps,1+3*eps,1+3*eps,1+eps,1,1+eps,1+eps]]
            write(folder,meta,rows);m,d=replay.load(folder);r=replay.summarize(m,d)['columns'][0]
            self.assertEqual(r['exactAccumulationPolicies'],['fused'])
            self.assertEqual(r['float32Replay']['recorderValuesDifferent'],2)
            self.assertEqual(r['float32FusedReplay']['recorderValuesDifferent'],0)

    def test_incomplete_or_misidentified_pressure_cannot_be_replayed(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);meta,rows=self.fixture(folder)
            for change in [dict(complete=False),dict(format='bombcad-production-phase-trace-1'),
                           dict(seedRecords=[]),dict(steps=[0,1,3,4,5]),dict(times=[0,.125,.125,.375,.5])]:
                with self.subTest(change=change):
                    broken=dict(meta,**change);write(folder,broken,rows)
                    with self.assertRaises(ValueError):replay.load(folder)
            for sample,dt in [(0,.125),(1,0),(2,-.125)]:
                bad=copy.deepcopy(rows);bad[sample][6]=dt;write(folder,meta,bad)
                with self.subTest(sample=sample,dt=dt),self.assertRaises(ValueError):replay.load(folder)

    def test_recorder_only_history_is_explicitly_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp);(folder/'production-trace.json').write_text('{}')
            with self.assertRaisesRegex(ValueError,'recorder-only'):replay.load(folder)


if __name__=='__main__':unittest.main()
