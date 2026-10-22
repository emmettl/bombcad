"""Compare captured native selectors and exact rational Float32 division."""
import importlib.util
import json
import struct
import subprocess
import sys

from exact_division import select, value
from prepare import ROOT, HERE, load, save, sha


def main():
    prepared = load(ROOT / 'preparation.json')
    consumed = {}

    def read(path):
        consumed[str(path)] = sha(path)
        return load(path)

    for mapping in [prepared['pins'], prepared['consumed']]:
        for path, h in mapping.items():
            assert sha(path) == h, path
    receipts = {(backend, stage): read(ROOT / (backend + '-' + stage) / 'receipt.json')
                for backend in ['metal', 'cuda'] for stage in ['own', 'cross']}
    assert all(r['status'] == 'complete-all-outcomes' for r in receipts.values())
    assert all(receipts[b, 'own']['allFirstDTGatesPass'] for b in ['metal', 'cuda'])
    assert receipts['metal', 'own']['sourceSHA256'] == receipts['metal', 'cross']['sourceSHA256']
    assert receipts['metal', 'own']['binarySHA256'] == receipts['metal', 'cross']['binarySHA256']
    assert receipts['cuda', 'own']['compile'] == receipts['cuda', 'cross']['compile']
    spec = importlib.util.spec_from_file_location('wire', ROOT / 'worker/job.py')
    wire = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wire)
    metal_source = (ROOT / 'analysis/producer-library.metal').read_text()
    cuda_source = (ROOT / 'worker/solver.cu').read_text()
    layouts = {b: (wire.scalar_layout(s, 'SolverUniforms'), wire.scalar_layout(s, 'StepControl'))
               for b, s in [('metal', metal_source), ('cuda', cuda_source)]}
    rows = []
    for item in prepared['rows']:
        name = item['id']
        uniforms, controls = {}, {}
        for b, (U, C) in layouts.items():
            folder = ROOT / 'cases' / name
            uniforms[b] = U.from_buffer_copy((folder / ('prepare-' + b + '.bin')).read_bytes())
            controls[b] = C.from_buffer_copy((folder / ('control-' + b + '.bin')).read_bytes())
        # These are the consumed scalar selector inputs. Absolute clock origin is separate.
        for k in ['cfl', 'dx', 'maxStep', 'forcedStep']:
            assert struct.pack('<f', getattr(uniforms['metal'], k)) == struct.pack('<f', getattr(uniforms['cuda'], k))
        for k in ['batchTime', 'timeLimit', 'stepIndex', 'stopped']:
            assert getattr(controls['metal'], k) == getattr(controls['cuda'], k)
        assert all(uniforms[b].maxStep == uniforms[b].forcedStep == 0 for b in uniforms)
        speed_words, matrix = {}, {}
        for origin in ['metal', 'cuda']:
            own = ROOT / (origin + '-own') / name / 'measured-speed.bin'
            consumed[str(own)] = sha(own)
            speed_words[origin] = list(struct.unpack('<2I', own.read_bytes()))
            rational = select(uniforms['metal'].cfl, uniforms['metal'].dx, value(speed_words[origin][0]))
            matrix[origin] = dict(correctlyRoundedFloat32Word=rational, correctlyRoundedFloat32=value(rational))
            for backend, (_, C) in layouts.items():
                output = ROOT / (backend+'-cross') / name / ('selected-'+origin+'.bin')
                consumed[str(output)] = sha(output)
                control = C.from_buffer_copy(output.read_bytes())
                actual = struct.unpack('<I', struct.pack('<f', control.dt))[0]
                receipt_row = next(r for r in receipts[backend, 'cross']['rows'] if r['id'] == name and r['speedOrigin'] == origin)
                assert receipt_row['dtWord'] == actual and receipt_row['speedWords'] == speed_words[origin]
                assert control.stopped == 0 and control.stepIndex == control.activeSteps == 1
                assert control.dt == control.lastStep == control.batchTime
                matrix[origin][backend] = dict(dtWord=actual, dt=control.dt, ulpsFromCorrectRounding=actual-rational)
                if origin == backend:
                    own_path = ROOT / (backend+'-own') / name / ('selected-'+origin+'.bin')
                    consumed[str(own_path)] = sha(own_path)
                    assert output.read_bytes() == own_path.read_bytes()
        rows.append(dict(id=name, history=item['history'], measuredSpeedWords=speed_words,
            measuredSpeeds={b: value(w[0]) for b, w in speed_words.items()},
            sameMeasuredFastestWord=speed_words['metal'][0] == speed_words['cuda'][0],
            selectionInputs=dict(cfl=uniforms['metal'].cfl, dx=uniforms['metal'].dx,
                maxStep=0, forcedStep=0, timeLimit=controls['metal'].timeLimit,
                batchTime=0, stepIndex=0, stopped=0),
            crossSelection=matrix))
    with (ROOT / 'division-controls.log').open('xb') as f:
        result = subprocess.run([sys.executable, '-B', str(HERE / 'check_division.py')], stdout=f, stderr=subprocess.STDOUT)
    assert result.returncode == 0
    for path, h in consumed.items():
        assert sha(path) == h, path
    report = dict(status='complete-all-outcomes', rows=rows, consumed=consumed,
        analyticControls=3, sourceSHA256=sha(__file__), allSixFirstDTGatesPass=True,
        allOwnCrossControlBytesEqual=True, PDEAdvanced=False,
        limits='Initial same-state measurement/selection only. Original full consumed controls/maxima were not captured; native first-dt parity is an end-to-end gate. No instruction, full argmax/tie, later-step or continuum attribution. No default policy change.')
    save(ROOT / 'results.json', report)
    print(json.dumps({k: v for k, v in report.items() if k != 'consumed'}, indent=2))


if __name__ == '__main__':
    main()
