#!/usr/bin/env python3
"""Contract, rejection and negative-control tests; no CUDA installation required."""
import ctypes
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
import sys
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent))
from generate import generate
from fixtures import make
from job import validate,scalar_layout
from compare import compare
import remote


class DeploymentTests(unittest.TestCase):
    def test_dataset_only_keeps_provenance_without_retrieving_raw_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            job = Path(temp) / 'input'
            job.mkdir()
            (job / 'job.json').write_text('{}')
            out = Path(temp) / 'output'
            source = 'test generated source'
            worker = Path(remote.__file__).parent
            report = {
                'sourceSHA256': hashlib.sha256(source.encode()).hexdigest(),
                'workerFilesSHA256': {
                    name: hashlib.sha256((worker / name).read_bytes()).hexdigest()
                    for name in ('run.py', 'job.py', 'compile.py')
                },
            }
            commands = []

            def command(args):
                commands.append(args)
                if args[0] == 'scp' and args[-2].endswith('/out/result.json'):
                    Path(args[-1]).write_text(json.dumps(report))

            with patch.object(remote, 'generate', return_value=source), \
                    patch.object(remote, 'validate', return_value=({'files': {}}, None)), \
                    patch.object(remote, 'command', side_effect=command):
                self.assertEqual(remote.deploy('bombcad-pc', job, out, dataset_only=True,cache_dir='bombcad-cuda/ptx-cache'), report)
            self.assertTrue(any(c[0]=='ssh' and '--cache-dir bombcad-cuda/ptx-cache' in c[-1] for c in commands))
            self.assertTrue((out / 'deployment.json').exists())
            downloads = [c[-2] for c in commands if c[0] == 'scp' and c[-2].startswith('bombcad-pc:')]
            self.assertEqual(len(downloads), 2)
            self.assertTrue(downloads[0].endswith('/out/dataset'))
            self.assertTrue(downloads[1].endswith('/out/result.json'))


    def test_trace_retrieval_is_not_silently_dropped_by_dataset_only(self):
        with self.assertRaisesRegex(ValueError,'trace retrieval requires full output'):
            remote.deploy('bombcad-pc','unused','unused-output',dataset_only=True,trace_columns=[1])

    def test_invalid_cache_path_is_rejected_before_deployment(self):
        with self.assertRaisesRegex(ValueError,'invalid remote cache path'):
            remote.deploy('bombcad-pc','unused','unused-output',cache_dir='../other')



class CompileCacheTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import importlib.util
        spec=importlib.util.spec_from_file_location('cuda_compiler_test',Path(__file__).with_name('compile.py'))
        cls.compiler=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.compiler)

    def test_contract_changes_invalidate_cache_key(self):
        key=self.compiler.cache_key('source',[b'--fmad=false',b'compute_86'],'compiler')
        for source,flags,compiler in [('changed',[b'--fmad=false',b'compute_86'],'compiler'),
                                      ('source',[b'--fmad=true',b'compute_86'],'compiler'),
                                      ('source',[b'--fmad=false',b'compute_89'],'compiler'),
                                      ('source',[b'--fmad=false',b'compute_86'],'new compiler')]:
            self.assertNotEqual(key,self.compiler.cache_key(source,flags,compiler))

    def test_corruption_and_wrong_key_are_misses(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'cache'/'entry.json'
            self.assertIsNone(self.compiler.cached_ptx(path,'key'))
            self.compiler.store_ptx(path,'key',b'PTX contents')
            self.assertEqual(self.compiler.cached_ptx(path,'key'),b'PTX contents')
            self.assertIsNone(self.compiler.cached_ptx(path,'wrong key'))
            item=json.loads(path.read_text());item['ptx']='changed';path.write_text(json.dumps(item))
            self.assertIsNone(self.compiler.cached_ptx(path,'key'))
            path.write_text('{partial')
            self.assertIsNone(self.compiler.cached_ptx(path,'key'))
            self.compiler.store_ptx(path,'key',b'rebuilt')
            self.assertEqual(self.compiler.cached_ptx(path,'key'),b'rebuilt')
            self.assertEqual([p.name for p in path.parent.iterdir()],['entry.json'])


class TraceTests(unittest.TestCase):
    def test_bad_or_unbounded_column_lists_are_rejected(self):
        import argparse
        from trace_columns import parse_columns
        self.assertEqual(parse_columns('17,400'),[17,400])
        for value in ('','1,','-1','1,1','1.5','1,no',','.join(str(i) for i in range(65))):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                parse_columns(value)

    def test_diagnostic_uses_existing_pressure_expression(self):
        from generate import numerical_source
        from trace_columns import trace_source
        source=numerical_source()
        begin=source.index('    float pressure = 0;',source.index('void portableFirstPhase('))
        end=source.index('    float dt = max(control.dt',begin)
        for metal in (False,True):
            self.assertIn(source[begin:end],trace_source(source,metal))

class JobTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source=generate()

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.folder=Path(self.temp.name)/'job';make(self.folder,self.source,'burning',4)
        self.meta=json.loads((self.folder/'job.json').read_text())

    def save(self):
        (self.folder/'job.json').write_text(json.dumps(self.meta))

    def test_real_layout_and_species_stride(self):
        meta,u=validate(self.folder,self.source)
        self.assertEqual(ctypes.sizeof(u),276)
        self.assertEqual(ctypes.sizeof(scalar_layout(self.source,'StepControl')),72)
        self.assertEqual((self.folder/'species.bin').stat().st_size,4**3*8)
        self.assertIn('sizeof(V<float,2>) == 8',self.source)

    def test_unsupported_features_fail_instead_of_disappearing(self):
        for name in ('refineRatio','gravity','deflagration','mixingCoefficient','experimentalBox'):
            with self.subTest(name=name):
                self.meta['uniforms'][name]=1;self.save()
                with self.assertRaisesRegex(ValueError,'unsupported uniform'):validate(self.folder,self.source)
                del self.meta['uniforms'][name]

    def test_modified_shader_rejected(self):
        with self.assertRaisesRegex(ValueError,'hashes differ'):validate(self.folder,self.source+'\n')

    def test_corrupted_buffer_rejected(self):
        p=self.folder/'state.bin';p.write_bytes(p.read_bytes()[:-4])
        with self.assertRaisesRegex(ValueError,'checksum mismatch'):validate(self.folder,self.source)

    def test_nonfinite_and_unstable_configuration_rejected(self):
        for value in (float('nan'),float('inf'),0,-1,.9):
            self.meta['uniforms']['cfl']=value;self.save()
            with self.assertRaises(ValueError):validate(self.folder,self.source)

    def test_wire_overflow_and_fractional_integer_rejected(self):
        self.meta['uniforms']['gamma']=1e100;self.save()
        with self.assertRaisesRegex(ValueError,'overflows'):validate(self.folder,self.source)
        self.meta['uniforms']['gamma']=1.4;self.meta['uniforms']['airModel']=1.5;self.save()
        with self.assertRaisesRegex(ValueError,'integer'):validate(self.folder,self.source)

    def test_unknown_metadata_and_future_format_rejected(self):
        self.meta['format']='future';self.save()
        with self.assertRaises(ValueError):validate(self.folder,self.source)
        self.meta['format']='bombcad-cuda-job-1';self.meta['terrain']={};self.save()
        with self.assertRaises(ValueError):validate(self.folder,self.source)

    def test_far_field_without_ambient_state_rejected(self):
        self.meta['uniforms']['boundaryFlags']=64;self.meta['uniforms']['stillRho']=0;self.save()
        with self.assertRaisesRegex(ValueError,'ambient'):validate(self.folder,self.source)

    def test_integer_overflow_rejected(self):
        self.meta['shape']=[65536]*3;self.save()
        with self.assertRaisesRegex(ValueError,'index range'):validate(self.folder,self.source)

    def test_receiver_indices_require_physical_axes(self):
        self.meta['axes']=[2,0,1];self.save()
        with self.assertRaisesRegex(ValueError,'axes'):validate(self.folder,self.source)

    def terrain(self):
        import struct
        self.meta['terrain']={'records':1,'cutColumnCount':1}
        columns=[(0,0,1,1)]+[(1,0,0,0)]*24
        buffers={'cut-columns.bin':b''.join(struct.pack('<4I',*c) for c in columns),
                 'cut-records.bin':struct.pack('<4f',.5,1,1,1),
                 'cut-walls.bin':struct.pack('<4f',0,0,-1,0),'cut-defects.bin':bytes(32),
                 'cut-list.bin':bytes(16),'cut-ceilings.bin':struct.pack('<4I',2,0,0,0)}
        for name,value in buffers.items():
            (self.folder/name).write_bytes(value)
            self.meta['files'][name]=hashlib.sha256(value).hexdigest()
        self.save()

    def test_cut_geometry_and_out_of_bounds_refusal(self):
        import struct
        self.terrain();validate(self.folder,self.source)
        path=self.folder/'cut-columns.bin';data=bytearray(path.read_bytes())
        data[:4]=struct.pack('<I',10);path.write_bytes(data)
        self.meta['files'][path.name]=hashlib.sha256(data).hexdigest();self.save()
        with self.assertRaisesRegex(ValueError,'outside'):validate(self.folder,self.source)

    def test_duplicate_redistribution_columns_refused(self):
        self.terrain();self.meta['terrain']['cutColumnCount']=2;self.save()
        with self.assertRaisesRegex(ValueError,'overlap'):validate(self.folder,self.source)

    def test_comparator_rejects_changed_and_nonfinite_fields(self):
        import array
        a=Path(self.temp.name)/'a';b=Path(self.temp.name)/'b';a.mkdir();b.mkdir()
        for name in ('state','species','peak','impulse','first-phase'):
            (a/(name+'.bin')).write_bytes(array.array('f',[1,2,3]).tobytes())
            (b/(name+'.bin')).write_bytes(array.array('f',[1,2,3]).tobytes())
        self.assertTrue(compare(a,b)['passed'])
        (b/'peak.bin').write_bytes(array.array('f',[1,2,30]).tobytes())
        self.assertFalse(compare(a,b)['passed'])
        (b/'peak.bin').write_bytes(array.array('f',[1,2,float('nan')]).tobytes())
        self.assertFalse(compare(a,b)['passed'])


if __name__=='__main__':unittest.main()
