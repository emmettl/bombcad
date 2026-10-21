"""Protocol generation, analytic extraction, provenance, and invalid-history tests. Stdlib only."""
import copy
import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('runner', HERE/'run_decks.py')
r = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(r)
p = r.protocol


class Decks(unittest.TestCase):
    def test_committed_decks_and_source_budgets(self):
        for cid in p.IDS:
            deck = p.deck(cid)
            self.assertEqual((p.DECKS/f'{cid}.json').read_text(), json.dumps(deck, indent=2)+'\n')
            for run in deck['runs']:
                v = deck['mesh']['cell_size_m']**3
                energy = sum((c['internal_energy_J_m3']-101325/0.4)*v for c in run['initial_cells'])
                mass = sum((c['density_kg_m3']-1.225)*v for c in run['initial_cells'])
                self.assertAlmostEqual(energy/run['source']['excess_energy_J'], 1)
                self.assertAlmostEqual(mass/run['source']['excess_mass_kg'], 1)
        free = p.deck(p.IDS[0])['runs'][0]
        self.assertEqual(free['source']['represented_charge_kg'], 25)
        self.assertEqual(free['source']['excess_energy_J']*4, 100*4184000)

    def test_triangle_and_nonuniform_interpolated_zero(self):
        # Piecewise-linear pulse: verify arrival and all trapezoids, including the interpolated end.
        trace = [(0,0), (1,1000), (2,3000), (3,1000), (4,-1000)]
        values, info = r.incident(trace)
        self.assertAlmostEqual(values['arrival_time'], 1250)
        self.assertAlmostEqual(values['peak_incident_overpressure'], 3)
        self.assertAlmostEqual(values['incident_positive_impulse'], 4750)
        self.assertAlmostEqual(info['phase_end_s'], 3.5)
        trace = [(0,0), (.5,0), (1,1000), (2,3000), (3,1000), (4,-1000)]
        values, _ = r.incident(trace)
        self.assertAlmostEqual(values['incident_positive_impulse'], 4500)
        self.assertAlmostEqual(r.integral([(0,100),(1,200),(3,400)], .5, 2.5), 500)

    def test_missing_phase_end_and_later_larger_pulse(self):
        for trace in [[(0,0),(1,2000),(2,1000)], [(0,0),(1,1200),(2,0),(3,2000),(4,-1)]]:
            with self.assertRaises(ValueError):
                r.incident(trace)

    def test_room_window_exact_linear_average(self):
        trace = [(0,0), (.1,100000), (.11,110000), (.12,120000)]
        self.assertAlmostEqual(r.integral(trace, .1, .12)/.02, 110000)

    def histories(self, root, deck, run):
        path = root/r.filename(deck, run)
        dt, stop = deck['sampling']['interval_s'], deck['sampling']['stop_s']
        with path.open('w', newline='') as stream:
            out = csv.writer(stream)
            out.writerow(['case','run','gauge','time_s','overpressure_Pa'])
            for i in range(round(stop/dt)+1):
                t = i*dt
                # A known triangular pulse per gauge (not an empirical reference prediction).
                value = max(0, 1000*(1-abs(t-.02)/.01)) if deck['case_id'] == p.IDS[0] else 100000*t
                for gauge in run['gauges']:
                    out.writerow([deck['case_id'],run['id'],gauge['id'],t,value])
        return path

    def test_end_to_end_and_tamper_incomplete_extra_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pairs = r.selected()
            for deck, run in pairs:
                self.histories(root, deck, run)
            build = root/'build'
            build.mkdir()
            binary = build/'test-code'
            binary.write_text('original executable')
            bundle = build/'Test.bundle'
            bundle.mkdir()
            (bundle/'shader.txt').write_text('original shader')
            snapshot = r.snapshot_runtime(binary, root)
            binary.write_text('changed by concurrent build')
            (bundle/'shader.txt').write_text('changed shader')
            self.assertEqual(snapshot.read_text(), 'original executable')
            self.assertEqual((root/'runtime/Test.bundle/shader.txt').read_text(), 'original shader')
            receipt = r.make_receipt(root, pairs, {'name':'synthetic verification','version':'1'}, snapshot)
            r.write_new(root/'receipt.json', receipt)
            results, diagnostics = r.extract(root)
            self.assertEqual(sum(len(c['predictions']) for c in results['cases']), 29)
            self.assertEqual(len(diagnostics), 13)
            spec = importlib.util.spec_from_file_location('scorer', HERE/'score.py')
            scorer = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(scorer)
            cases = {cid: json.loads((p.CASES/f'{cid}.json').read_text()) for cid in p.IDS}
            self.assertEqual(scorer.check_results(results, cases), ([], []))
            self.assertAlmostEqual(results['cases'][1]['predictions'][0]['value'], 11)
            for mutate in ['missing','duplicate','hash','path','deck']:
                changed = copy.deepcopy(receipt)
                if mutate == 'missing': changed['histories'].pop()
                if mutate == 'duplicate': changed['histories'].append(changed['histories'][0])
                if mutate == 'hash': changed['histories'][0]['sha256'] = 'bad'
                if mutate == 'path': changed['histories'][0]['path'] = '../elsewhere.csv'
                if mutate == 'deck': changed['decks'][p.IDS[0]]['sha256'] = 'bad'
                (root/'receipt.json').write_text(json.dumps(changed))
                with self.assertRaises(ValueError, msg=mutate): r.extract(root)
            (root/'receipt.json').write_text(json.dumps(receipt))
            snapshot.write_text('tampered runtime')
            with self.assertRaises(ValueError): r.extract(root)

    def test_history_rejections(self):
        with tempfile.TemporaryDirectory() as directory:
            deck, run = r.selected(p.IDS[0])[0]
            path = self.histories(Path(directory), deck, run)
            good = path.read_text()
            lines = good.splitlines()
            bad_inputs = [good.replace(',Z0.75,', ',unknown,'), good.replace(',0.0,0', ',nan,0'),
                          '\n'.join(lines[:-8]), '\n'.join(lines[:1]+lines[9:]),
                          '\n'.join(lines[:9]+lines[1:9]+lines[9:]),
                          '\n'.join(lines[:9]+lines[17:])]
            for bad in bad_inputs:
                path.write_text(bad)
                with self.assertRaises(ValueError): r.read_history(path, deck, run)


if __name__ == '__main__':
    unittest.main()
