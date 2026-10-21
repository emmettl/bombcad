"""Queue admission, publication, planning and real local-process recovery; no GPU required."""
import array
import importlib.util
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('field_queue',Path(__file__).with_name('field-queue.py'))
q=importlib.util.module_from_spec(spec);spec.loader.exec_module(q)


def write_npy(path,shape,values):
    header=repr({'descr':'<f4','fortran_order':False,'shape':shape}).encode()
    header+=b' '*((64-(10+len(header)+1)%64)%64)+b'\n'
    data=array.array('f',values)
    if sys.byteorder!='little':data.byteswap()
    Path(path).write_bytes(b'\x93NUMPY\x01\x00'+struct.pack('<H',len(header))+header+data.tobytes())


class QueueFixture(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.queue=self.root/'queue'
        self.osm=self.root/'scene.osm';self.osm.write_text('unit fixture, not physical OSM')
        self.refs=self.root/'refs';self.refs.mkdir();ref=self.refs/'one';ref.mkdir()
        args=['--osm',str(self.osm),'--id','one','--first-phase']
        self.args=args
        write_npy(ref/'inputs.npy',(6,2,2),range(24));write_npy(ref/'mask.npy',(2,2),[1,1,1,0]);write_npy(ref/'targets.npy',(3,2,2),[100]*12)
        q.atomic(ref/'meta.json',{'format':'bombcad-field-1','inputs':[{'name':n} for n in q.INPUT_NAMES],'stable':True,'configuration':'recommended','id':'one','arguments':args,
          'targets':[{'name':n} for n in q.TARGET_NAMES],'rows':2,'columns':2,'cells':8,'solverBytes':1024})
        self.exe=self.root/'scenebench';self.exe.write_text('#!'+sys.executable+'\n'+f'''
import pathlib,sys,time,shutil,json
r=pathlib.Path({str(self.root)!r})
if (r/'fail-next').exists():
 (r/'fail-next').unlink();raise SystemExit(3)
time.sleep(.2)
a=sys.argv;out=pathlib.Path(a[a.index('--out')+1]);ident=a[a.index('--id')+1]
shutil.copytree(r/'refs'/ident,out)
if not (r/'missing-phases').exists():
 (out/'phase-timings.json').write_text(json.dumps(dict(format='bombcad-field-phases-1',mode='metal',clock='unit orchestration fixture',seconds=dict(scenePreparationSeconds=.01,solverSetupIncludingCompileSeconds=.01,recorderSetupSeconds=.01,solveSeconds=.01,outputSeconds=.01),totalSecondsBeforeTimingReceipt=.1)))
if (r/'bad-gate').exists():
 p=out/'targets.npy';p.write_bytes(p.read_bytes()[:-4]+b'\\x00\\x00\\x80\\x7f')
 # Corrupt an unmasked target too, preserving the NPY container.
 import struct
 b=bytearray(p.read_bytes());n=struct.unpack('<H',b[8:10])[0];b[10+n:14+n]=struct.pack('<f',10000);p.write_bytes(b)
''');self.exe.chmod(0o755)
        self.slot=self.root/'gpu-slot';self.slot.write_text('#!'+sys.executable+'\n'+'''
import os,sys
if '--status' in sys.argv:
 print('memory budget 26 GB of 36 GB RAM')
 for i in range(1,6):print('slot %d: free'%i)
else:os.execv(sys.argv[3],sys.argv[3:])
''');self.slot.chmod(0o755)
        self.cost=self.root/'cost.json';q.atomic(self.cost,{'metal':1.,'cuda':8.})
        self.job={'id':'one','arguments':args,'reference':str(ref),'physics':'recommended-uniform','backends':['metal'],
                  'metalGB':.5,'costs':{'metal':[{'report':str(self.cost),'keys':['metal']}]},'timeoutSeconds':20}
        self.plan={'format':q.FORMAT,'purpose':'reference-replay','scenebench':str(self.exe),'gpuSlot':str(self.slot),'jobs':[self.job]}
        self.mac={'available':True,'waiting':False,'regularFree':True,'smallFree':True,'budgetGB':26,'declaredGB':0,'pressure':'1'}

    def tearDown(self):
        if self.queue.exists():
            for f in self.queue.glob('cases/*/attempts/*/process.json'):
                pid=q.read(f)['pgid']
                if q.group_alive(pid):
                    try:os.killpg(pid,signal.SIGTERM)
                    except ProcessLookupError:pass
                try:os.waitpid(pid,0)
                except ChildProcessError:pass
        self.temp.cleanup()

    def init(self):return q.init(self.plan,self.queue)

    def tick(self):
        with patch.object(q,'mac_snapshot',return_value=self.mac), patch.object(q,'pc_snapshot',return_value={'available':False,'freeBytes':0}):return q.run_queue(self.queue,once=True)

    def await_attempt(self,number,status):
        deadline=time.time()+12
        while time.time()<deadline:
            attempts=list(self.queue.glob('cases/*/attempts/*'))
            if len(attempts)>=number:
                results=[q.read(p/'result.json') for p in attempts if (p/'result.json').exists()]
                if len(results)>=number and any(r['status']==status for r in results):
                    for p in attempts:
                        if (p/'process.json').exists():
                            pid=q.read(p/'process.json')['pid']
                            try:os.waitpid(pid,0)
                            except ChildProcessError:pass
                    return
            time.sleep(.05)
        self.fail('worker did not reach '+status)


class AdmissionTests(QueueFixture):
    def test_unknown_physics_option_is_rejected_before_queue_creation(self):
        self.job['arguments']+=['--refine','2']
        with self.assertRaisesRegex(ValueError,'unsupported'):self.init()
        self.assertFalse(self.queue.exists())

    def test_unsupported_cuda_declaration_and_low_memory_are_rejected(self):
        self.plan['cuda']={'host':'unit-offline'};self.job['backends']=['cuda'];self.job['cudaBytes']=1000
        self.job['costs']={'cuda':[{'report':str(self.cost),'keys':['cuda']}]};self.job['physics']='moving-structures'
        with self.assertRaisesRegex(ValueError,'unsupported'):self.init()
        self.job['physics']='recommended-uniform';self.job['metalGB']=.1
        with self.assertRaisesRegex(ValueError,'memory bound'):self.init()

    def test_changed_reference_command_is_rejected(self):
        self.job['arguments']+=['--mass','20']
        with self.assertRaisesRegex(ValueError,'reference command'):self.init()

    def test_cuda_output_cannot_be_its_own_reference(self):
        p=self.refs/'one/meta.json';meta=q.read(p);meta['cudaProvenance']={};q.atomic(p,meta)
        with self.assertRaisesRegex(ValueError,'Metal reference'):self.init()

    def test_sources_inputs_and_cost_evidence_are_pinned(self):
        c=self.init();self.cost.write_text('{}')
        with self.assertRaisesRegex(ValueError,'pinned file changed'):q.verify_contract(c)

    def test_invalid_numeric_option_does_not_fall_back_to_solver_default(self):
        with self.assertRaisesRegex(ValueError,'invalid numeric'):q.arguments(['--osm',str(self.osm),'--id','one','--mass','nan'])

    def test_integer_option_must_not_fall_back_from_decimal_syntax(self):
        with self.assertRaisesRegex(ValueError,'integer edge'):
            q.arguments(['--osm',str(self.osm),'--id','one','--edge','3.0'])

    def test_channel_semantics_and_feature_shape_are_checked(self):
        path=self.refs/'one/meta.json';meta=q.read(path);meta['targets'].reverse();q.atomic(path,meta)
        with self.assertRaisesRegex(ValueError,'channel semantics'):self.init()
        meta['targets'].reverse();q.atomic(path,meta)
        write_npy(self.refs/'one/inputs.npy',(24,),range(24))
        with self.assertRaisesRegex(ValueError,'shape differs'):self.init()

    def test_probe_overrides_are_cleared_and_dirty_source_context_is_explicit(self):
        c=self.init()
        with patch.dict(os.environ,{'BOMBCAD_KERNEL_MATH':'safe','GPU_SLOT_MEM':'20','BOMBCAD_GPU_MEM_FORCE':'1'}):
            env=q.clean_env(c)
        self.assertNotIn('BOMBCAD_KERNEL_MATH',env);self.assertNotIn('GPU_SLOT_MEM',env)
        self.assertNotIn('BOMBCAD_GPU_MEM_FORCE',env)
        self.assertEqual(env['BOMBCAD_SOURCE_REVISION'],c['revisionObservedAtInit']+('-dirty' if c['worktreeDirtyAtInit'] else ''))

    def test_only_bounded_explicit_replay_plans_are_admitted(self):
        self.plan['purpose']='bulk-training'
        with self.assertRaisesRegex(ValueError,'reference-replay'):self.init()


class PlannerTests(unittest.TestCase):
    def inputs(self,count=8):
        jobs=[{'key':str(i),'estimatedSeconds':{'metal':2.,'cuda':8.},'metalGB':2,'cudaBytes':100} for i in range(count)]
        states={j['key']:{'status':'pending','eligibleBackends':['metal','cuda'],'retryAfter':0} for j in jobs}
        mac={'available':True,'waiting':False,'regularFree':True,'smallFree':True,'budgetGB':26,'declaredGB':0,'pressure':'1'}
        pc={'available':True,'freeBytes':1000}
        return {'jobs':jobs},states,mac,pc

    def test_measured_costs_plan_spillover_without_forcing_every_job_to_cuda(self):
        c,s,m,p=self.inputs();proposals=q.plan_dispatch(c,s,m,p,now=10)
        ready=[x for x in proposals if x['launchNow']]
        self.assertEqual([(r['case'],r['backend']) for r in ready],[('0','metal'),('4','cuda')])

    def test_busy_pc_yields_without_blocking_metal_jobs(self):
        c,s,m,p=self.inputs(2);p['available']=False;s['0']['eligibleBackends']=['cuda']
        ready=[r for r in q.plan_dispatch(c,s,m,p,now=10) if r['launchNow']]
        self.assertEqual([(r['case'],r['backend']) for r in ready],[('1','metal')])

    def test_vram_and_mac_memory_bounds_are_required_before_dispatch(self):
        c,s,m,p=self.inputs(1);p['freeBytes']=100;m['declaredGB']=25
        self.assertEqual(q.plan_dispatch(c,s,m,p,now=10),[])

    def test_reserved_check_slot_is_not_general_capacity(self):
        text='memory budget 26 GB of 36 GB RAM\n'+'\n'.join('slot %d: %s'%(i,'free' if i==4 else 'pid 5 since now (2 GB)') for i in range(1,6))
        m=q.parse_mac(text,'1',{});self.assertFalse(m['regularFree']);self.assertFalse(m['smallFree'])

    def test_pid_reuse_does_not_block_a_stopped_attempt(self):
        process={'pid':123,'pgid':123,'boot':'boot','birth':'old','attempt':'nonce','queue':'root'}
        with patch.object(q,'boot_id',return_value='boot'), patch.object(q,'process_snapshot',return_value={'birth':'new','command':'unrelated'}), patch.object(q,'group_alive') as group:
            self.assertFalse(q.tracked_alive(process));group.assert_not_called()

    def test_surviving_descendants_are_live_after_session_leader_exits(self):
        process={'pid':123,'pgid':123,'boot':'boot','birth':'old','attempt':'nonce','queue':'root'}
        with patch.object(q,'boot_id',return_value='boot'), patch.object(q,'process_snapshot',return_value=None), patch.object(q,'group_alive',return_value=True):
            self.assertTrue(q.tracked_alive(process))

    def test_zombie_leader_does_not_hide_live_descendants(self):
        process={'pid':123,'pgid':123,'boot':'boot','birth':'old','attempt':'nonce','queue':'root'}
        with patch.object(q,'boot_id',return_value='boot'), patch.object(q,'process_snapshot',return_value={'state':'Z','birth':'old','command':'defunct'}), patch.object(q,'group_alive',return_value=True):
            self.assertTrue(q.tracked_alive(process))

    def test_probe_timeout_bytes_are_reported_without_becoming_available(self):
        with patch.object(q.subprocess,'run',side_effect=subprocess.TimeoutExpired(['ssh'],1,stderr=b'timed out')):
            observed=q.pc_snapshot({'cuda':{'host':'configured'}})
        self.assertFalse(observed['available']);self.assertIn('timed out',observed['stderr']);json.dumps(observed)


class PublicationTests(QueueFixture):
    def test_metal_only_pending_case_never_probes_pc(self):
        self.init()
        with patch.object(q,'mac_snapshot',return_value=self.mac), patch.object(q,'pc_snapshot',side_effect=AssertionError('irrelevant SSH')), patch.object(q,'launch') as launch:
            self.assertEqual(q.run_queue(self.queue,once=True),75)
            self.assertEqual(launch.call_args.args[2]['backend'],'metal')
        self.assertEqual(q.read(self.queue/'dispatch.json')['cuda']['reason'],'no runnable CUDA cases')

    def test_running_or_backoff_only_queue_does_not_probe_resources(self):
        c=self.init();key=c['jobs'][0]['key']
        for state in ({'status':'running'}, {'status':'pending','retryAfter':time.time()+60}):
            with self.subTest(state=state), patch.object(q,'snapshot_states',return_value={key:state}), patch.object(q,'mac_snapshot',side_effect=AssertionError('no dispatch possible')), patch.object(q,'pc_snapshot',side_effect=AssertionError('no dispatch possible')), patch.object(q,'launch') as launch:
                self.assertEqual(q.run_queue(self.queue,once=True),75)
                launch.assert_not_called()

    def test_runnable_cuda_case_still_probes_pc(self):
        self.plan['cuda']={'host':'unit-offline'};self.job['backends']=['metal','cuda'];self.job['cudaBytes']=1000
        self.job['costs']['cuda']=[{'report':str(self.cost),'keys':['cuda']}]
        self.init()
        with patch.object(q,'mac_snapshot',return_value=self.mac), patch.object(q,'pc_snapshot',return_value={'available':False,'freeBytes':0}) as pc, patch.object(q,'launch'):
            self.assertEqual(q.run_queue(self.queue,once=True),75)
            pc.assert_called_once()

    def test_resume_reuses_accepted_object_and_recovers_missing_pointer(self):
        c=self.init();self.assertEqual(self.tick(),75);self.await_attempt(1,'accepted')
        self.assertEqual(self.tick(),0);self.assertEqual(len(list((self.queue/'objects').iterdir())),1)
        pointer=next(self.queue.glob('cases/*/accepted.json'));ident=q.read(pointer)['object'];pointer.unlink()
        q.recover(self.queue,c);self.assertEqual(q.read(pointer)['object'],ident)
        with patch.object(q,'mac_snapshot',side_effect=AssertionError('accepted case dispatched again')):
            self.assertEqual(q.run_queue(self.queue,once=True),0)
        self.assertEqual(len(list(self.queue.glob('cases/*/attempts/*'))),1)

    def test_transient_failed_attempt_returns_to_queue_then_accepts_once(self):
        self.init();(self.root/'fail-next').touch();self.tick();self.await_attempt(1,'failed');time.sleep(2.1)
        self.tick();self.await_attempt(2,'accepted');self.assertEqual(self.tick(),0)
        self.assertEqual(len(list((self.queue/'objects').iterdir())),1)

    def test_gate_failure_is_quarantined_and_retry_does_not_admit_it(self):
        c=self.init();(self.root/'bad-gate').touch();self.tick();self.await_attempt(1,'blocked')
        state=q.case_state(self.queue,c,c['jobs'][0]);self.assertEqual(state['status'],'failed')
        self.assertEqual(state['blockedBackends'],['metal']);self.assertFalse(list((self.queue/'objects').iterdir()))

    def test_failed_gate_returns_case_to_other_backend_and_survives_retry_generation(self):
        self.plan['cuda']={'host':'unit-offline'};self.job['backends']=['metal','cuda'];self.job['cudaBytes']=1000
        self.job['costs']['cuda']=[{'report':str(self.cost),'keys':['cuda']}]
        c=self.init();(self.root/'bad-gate').touch();self.tick();self.await_attempt(1,'blocked')
        folder=self.queue/'cases'/c['jobs'][0]['key'];q.atomic(folder/'retry.json',{'generation':1,'since':time.time()})
        state=q.case_state(self.queue,c,c['jobs'][0]);self.assertEqual(state['status'],'pending')
        self.assertEqual(state['eligibleBackends'],['cuda']);self.assertEqual(state['blockedBackends'],['metal'])
        self.assertFalse(list((self.queue/'objects').iterdir()))

    def test_accepted_bytes_corruption_fails_closed(self):
        c=self.init();self.tick();self.await_attempt(1,'accepted');p=next(self.queue.glob('objects/*/dataset/targets.npy'));p.write_bytes(b'bad')
        with self.assertRaisesRegex(ValueError,'corrupted'):q.recover(self.queue,c)

    def test_missing_phase_receipt_is_not_silently_accepted(self):
        self.init();(self.root/'missing-phases').touch();self.tick();self.await_attempt(1,'blocked')
        self.assertFalse(list((self.queue/'objects').iterdir()))

    def test_live_worker_is_observed_without_duplicate_launch(self):
        c=self.init();self.tick();self.assertEqual(self.tick(),75);self.await_attempt(1,'accepted')
        self.assertEqual(len(list(self.queue.glob('cases/*/attempts/*'))),1)
