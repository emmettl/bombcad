#!/usr/bin/env python3
"""Contract, rejection and negative-control tests; no CUDA installation required."""
import ctypes
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from generate import generate
from fixtures import make
from job import validate,scalar_layout
from compare import compare


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
