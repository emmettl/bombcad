"""Independent input/protocol/math controls; never runs a scientific GPU case."""
import copy
import gzip
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import numpy as np
import audit
import phase
import readouts
import replay
import run

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('reference',HERE/'reference-worker.py');reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference)


class Controls(unittest.TestCase):
    def test_complete_factorial_plan(self):
        plan=run.plan();self.assertEqual(len(plan['jobs']),432);self.assertEqual(plan['expectedExports'],1296)
        self.assertEqual(len({r['label'] for r in plan['jobs']}),432)
        for key,count in [('method',2),('policy',2),('cfl',2),('components',3),('amplitudePa',3),('nx',3),('tiled',2)]:
            levels={r[key] for r in plan['jobs']};self.assertEqual(len(levels),count)
            self.assertTrue(all(sum(r[key]==level for r in plan['jobs'])==432//count for level in levels))
        for row in plan['jobs']:
            args=row['arguments'];self.assertEqual(args[args.index('--only-case')+1],row['case'])
            self.assertEqual('--discard-compensation' in args,row['method']=='protected-update-no-carry-v1')

    def test_phase_semantics_and_open_history(self):
        p=[0.,1.,-1.,1.5,-1.,3.,-1.];dt=[0.,1.,1.,1.,1.,1.,1.]
        self.assertEqual(phase.whole(p,dt)['impulse'],2.5);self.assertEqual(phase.streaming(p,dt)['impulse'],5.5)
        self.assertEqual(phase.whole(p,dt)['closingSample'],4);self.assertEqual(phase.streaming(p,dt)['closingSample'],6)
        self.assertTrue(phase.streaming([0.,1.],[0.,1.])['open'])
        self.assertEqual(audit.column([-1.,-1.],[0.,1.],1.,1.)['peak'],0)

    def test_low_pair_parts_are_not_lost_by_background_subtraction(self):
        state=np.array([[1.225,0,253314.546875]],dtype=np.float32)
        before=np.array([[0,0,3,0]],dtype=np.float32).view(np.uint32);after=before.copy()
        after.view(np.float32)[0,1]=2**-40
        self.assertEqual(float(state[0,2])-float(after.view(np.float32)[0,1]),float(state[0,2]))
        result=readouts.conserved_changes(state,state,before,after,1.)
        self.assertEqual(result['rawChange'],[0.,0.,0.]);self.assertEqual(result['residualCorrectedChange'][2],-2**-40)

    def test_retained_reference_state_dtype_clock_and_conservation(self):
        gamma=np.float32(1.4);energy=np.float32(101325)/(gamma-np.float32(1))
        initial=np.tile(np.array([1.225,0,energy],dtype=np.float32),(32,1));dt=np.full(10,2e-6,dtype=np.float32);clock=np.r_[0.,np.cumsum(dt.astype(np.float64))]
        with tempfile.TemporaryDirectory(prefix='bombcad-wave-oracle-control-') as directory:
            root=Path(directory);np.savez(root/'in.npz',initial=initial,dt=dt,clock=clock,indices=np.array([0,8],dtype=np.int64),gamma=np.array(float(gamma)),dx=np.array(.25))
            engine=Path.cwd()/'Scripts/reference/planar_euler.py'
            result=reference.execute(engine,root/'in.npz',root/'out.npz',root/'out.json')
            with np.load(root/'out.npz') as output:
                self.assertEqual(output['final'].dtype,np.float64);self.assertTrue(np.array_equal(output['final'],initial.astype(np.float64)))
                self.assertTrue(np.all(output['pressure']==(float(gamma)-1)*float(energy)-101325))
                self.assertTrue(np.all(output['storedChangeFromSteps']==0))
            self.assertEqual(result['maximumAbsoluteClockLagS'],0);self.assertEqual(result['maximumAbsoluteBoundaryBalancedResidual'],[0.,0.,0.])

    def test_real_scalar_words_skip_carry_and_corruption(self):
        # Synthetic conservation mapping of actual scalar GPU words; NOT a wave experiment.
        root=HERE.parent/'2026-10-22-compensated-scalar/evidence'
        fixture=json.loads(gzip.decompress((root/'fixtures.json.gz').read_bytes()));gpu=json.loads(gzip.decompress((root/'gpu.json.gz').read_bytes()))
        record=next(r for r in gpu['results'] if r['policy']=='default' and r['method']=='protected-kahan' and r['observed'])
        sequence=next(s for s in fixture['sequences'] if s['name']=='energy-negative');offset=sum(len(s['deltas']) for s in fixture['sequences'][:2]);n=len(sequence['deltas'])
        actual=np.asarray(record['traceWords'][offset*2:(offset+n)*2],dtype=np.uint32).reshape(n,2)
        raw=np.zeros((n,1,33),dtype=np.uint32);v=raw.view(np.float32);v[:,0,0]=v[:,0,5]=1
        raw[:,0,4]=np.r_[np.uint32(sequence['initial']),actual[:-1,0]];raw[:,0,9]=actual[:,0]
        raw[:,0,25]=np.r_[np.uint32(0),actual[:-1,1]];raw[:,0,27]=actual[:,1]
        v[:,0,19]=2**-12;v[:,0,20:22]=1;v[:,0,23]=1;v[:,0,28]=2;v[:,0,32]=-2**-12
        before=np.array([[0,0,2,0]],dtype=np.float32).view(np.uint32);after=before.copy();after[0,1]=actual[-1,1]
        trace=dict(valueBits=raw.tolist(),executed=np.ones((n,1),dtype=bool).tolist(),initialStateBits=raw[0,:,:5].tolist(),finalStateBits=raw[-1,:,5:10].tolist(),indices=[0],steps=list(range(1,n+1)))
        result=replay.audit(trace,before.tolist(),after.tolist());self.assertTrue(result['strictNoFloorReplay']);self.assertEqual(result['components'][0]['exactPairIncrementRemainderNonzero'],0)
        skipped=copy.deepcopy(trace);skipped['valueBits'].insert(0,[[0]*33]);skipped['executed'].insert(0,[False]);skipped['steps']=list(range(1,n+2))
        self.assertTrue(replay.audit(skipped,before.tolist(),after.tolist())['strictNoFloorReplay'])
        corrupt=copy.deepcopy(trace);corrupt['valueBits'][0][0][9]^=1
        result=replay.audit(corrupt,before.tolist(),after.tolist());self.assertFalse(result['strictNoFloorReplay']);self.assertGreater(result['prePostStateDiscontinuities'],0)
        corrupt=copy.deepcopy(trace);corrupt['executed'][0]=['false']
        with self.assertRaises(ValueError):replay.audit(corrupt,before.tolist(),after.tolist())


if __name__=='__main__':unittest.main()
