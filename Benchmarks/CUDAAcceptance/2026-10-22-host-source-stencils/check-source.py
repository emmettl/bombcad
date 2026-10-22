"""Pinned CLI-fixture parser controls; no GPU or oracle execution."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

here=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('source_audit',here/'source-audit.py');audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)


class Controls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        inventory=json.loads((here/'archive.json').read_text());root=Path(inventory['rawRoot']);pins=inventory['rawFiles'];name='a100-n128-full'
        def load(suffix):
            relative='output/'+name+suffix;path=root/relative
            assert hashlib.sha256(path.read_bytes()).hexdigest()==pins[relative]['sha256']
            return json.loads(path.read_text())
        cls.source=load('-source-stencil.json');cls.updates=load('-update-trace.json');cls.snapshot=load('-sources.json')

    def test_valid_actual_serialization(self):
        result=audit.validate(self.source,self.updates,self.snapshot,128)
        self.assertEqual(result['state'].shape,(252,6,5,5))

    def test_corrupt_later_source_word_refuses(self):
        bad=copy.deepcopy(self.source);bad['sourceConservedBits'][1][0][2][0]^=1
        with self.assertRaises(AssertionError):audit.validate(bad,self.updates,self.snapshot,128)

    def test_bad_canonical_or_mapping_refuses(self):
        for mutate in [lambda x:x['sourceConservedBits'][0][0][0].__setitem__(0,-1),
                       lambda x:x['sourceConservedBits'][0][0][0].__setitem__(0,0x7fc00000),
                       lambda x:x['sourcePhysicalIndices'][0].__setitem__(0,127),
                       lambda x:x['sourceGhostVelocitySigns'][0].__setitem__(0,2),
                       lambda x:x['executed'][0].__setitem__(0,1)]:
            bad=copy.deepcopy(self.source);mutate(bad)
            with self.assertRaises((AssertionError,ValueError)):audit.validate(bad,self.updates,self.snapshot,128)


if __name__=='__main__':unittest.main()
