#!/usr/bin/env python3
"""Compile actual original/shared reconstruction with reversible passive observation hooks."""
import argparse, hashlib, json, shutil
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--variant',choices=['original','shared'],required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
root=Path(__file__).resolve().parents[1];fixtures=root/'Fixtures/QRReconstructionAdoption';manifest=json.loads((fixtures/'source.json').read_text())
assert manifest['revision']=='b7d86c445d7aa40ed63bab1562e9c956b1c5c31e'
for path,entry in manifest['sources'].items():
    raw=(fixtures/entry['snapshot']).read_bytes()
    assert hashlib.sha256(raw).hexdigest()==entry['sha256']
    assert hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()==entry['gitBlob']
args.output.mkdir(parents=True,exist_ok=True)
sources=args.output/'Sources/ReconstructionCapture';sources.mkdir(parents=True,exist_ok=True)
bindings=[]
def instrument(path,callback):
    entry=manifest['sources'][path]
    raw=(fixtures/entry['snapshot']).read_text() if args.variant=='original' else (root/path).read_text()
    text=raw;patches=[]
    def patch(old,new,label):
        nonlocal text
        assert text.count(old)==1,label
        text=text.replace(old,new);patches.append({'original':old,'traced':new,'label':label})
    callback(patch)
    restored=text
    for item in reversed(patches):
        assert restored.count(item['traced'])==1,item['label']
        restored=restored.replace(item['traced'],item['original'])
    assert restored==raw,'byte-exact original/shared arithmetic restoration'
    output=sources/Path(path).name;output.write_text(text)
    bindings.append({'path':path,'variant':args.variant,'sourceSHA256':hashlib.sha256(raw.encode()).hexdigest(),'compiledSHA256':hashlib.sha256(text.encode()).hexdigest(),'patches':patches})
def pressure(patch):
    if args.variant=='original':patch('    private struct QR {','    struct QR {','fixture-only QR type visibility')
    patch('        private let weights: [Double]','        private let weights: [Double]\n        private let traceStencil: Int','fixture-only stable stencil identity')
    if args.variant=='original':
        anchor='            linearQR = QR(rows: weighted.map { Array($0.prefix(3)) })'
    else:
        anchor='            linearQR = try? PivotedQR(\n                rows: weighted.map { Array($0.prefix(3)) }, relativeRankTolerance: 1e-10)'
    patch(anchor,anchor+'\n            traceStencil = ReconstructionTrace.stencil(cell: cell, neighbours: neighbours, scale: scale, aware: volumeAware, rows: weighted, weights: distanceWeights, quadratic: quadraticQR.map { ReconstructionTrace.factor($0) }, linear: linearQR.map { ReconstructionTrace.factor($0) })','observe actual stored factors and geometry once')
    anchor='            return .init(\n                cell: .init(centre: cell.centre, covariance: cell.covariance, average: average),'
    patch(anchor,'            ReconstructionTrace.solve(stencil: traceStencil, average: average, neighbours: neighbourAverages, rhs: rhs, quadratic: quadratic, coefficients: coefficients)\n'+anchor,'observe actual complete RHS and selected coefficients')
    anchor='            for point in points {\n                let delta = value(at: point) - cell.average'
    patch(anchor,'            for point in points {\n                let traceBefore = factor\n                let delta = value(at: point) - cell.average','observe bound input without changing evaluation')
    anchor='                if delta < 0 { factor = min(factor, (lower - cell.average) / delta) }'
    patch(anchor,anchor+'\n                ReconstructionTrace.limit(point: point, mean: cell.average, lower: lower, upper: upper, delta: delta, before: traceBefore, after: factor)','observe every actual sampled bound step')
    anchor='            return .init(fit: self, factor: max(0, min(1, factor)))'
    patch(anchor,'            ReconstructionTrace.limited(factor)\n'+anchor,'observe raw component limiter result')
def conserved(patch):
    anchor='        let mean = frame[0]'
    patch(anchor,anchor+'\n        ReconstructionTrace.frame(velocity: velocity, densities: frame, mean: mean)','observe actual velocity-frame data')
    anchor='        for c in 0..<5 {\n            let local = FiniteVolumePressureFit.Sample('
    patch(anchor,'        for c in 0..<5 {\n            ReconstructionTrace.beginComponent(c)\n            let local = FiniteVolumePressureFit.Sample(','observe actual conserved component sequence')
    anchor='            polynomials.append(polynomial)'
    patch(anchor,'            ReconstructionTrace.component(polynomial: polynomial, originalScale: originalScale, lower: lower, upper: upper, bound: boundComponents, globalFactor: factor, fallback: fallback)\n'+anchor,'observe actual constant threshold, polynomial and component factor')
    anchor='        let densityFloor = 1e-12 * mean[0]'
    patch(anchor,'        ReconstructionTrace.deltas(deltas)\n'+anchor,'observe all actual control deltas')
    anchor='        let internalFloor = 1e-12 * (mean[4] - 0.5 * simd_length_squared(momentum) / mean[0])'
    patch(anchor,anchor+'\n        ReconstructionTrace.floors(densityFloor, internalFloor)','observe actual sampled admissibility floors')
    anchor='''        func accepted(_ theta: Double) -> Bool {
            deltas.allSatisfy {
                admissible(mean + theta * $0, densityFloor: densityFloor, internalFloor: internalFloor)
            }
        }'''
    patch(anchor,'''        func accepted(_ theta: Double) -> Bool {
            ReconstructionTrace.probe(theta)
            return ReconstructionTrace.answer(deltas.allSatisfy {
                admissible(mean + theta * $0, densityFloor: densityFloor, internalFloor: internalFloor)
            })
        }''','passively observe actual short-circuit predicate and result')
    anchor='            for _ in 0..<48 {\n                let mid = (low + high) / 2'
    patch(anchor,'            for _ in 0..<48 {\n                let traceLow = low\n                let traceHigh = high\n                let mid = (low + high) / 2','observe unchanged backoff inputs')
    anchor='                if accepted(mid) { low = mid } else { high = mid }'
    patch(anchor,anchor+'\n                ReconstructionTrace.backoff(beforeLow: traceLow, beforeHigh: traceHigh, mid: mid, low: low, high: high)','observe every actual backoff update')
    anchor='        let fit = Fit(\n            cell: cell, velocityFrame: velocity, polynomials: polynomials, factor: factor,'
    patch(anchor,'        ReconstructionTrace.selected(factor: factor, reduced: reduced, fallback: fallback)\n'+anchor,'observe actual selected factor and fallback')
    anchor='''        _ = try FractionalGasTransport.advance(
            controls.map { fit.state(at: $0) }, newVolumes: controls.map { _ in 1 }, transfers: [])'''
    patch(anchor,'        ReconstructionTrace.outputs(fit, controls: controls)\n'+anchor,'observe full final lab-frame/EOS inputs before actual validation')
    anchor='''        guard (0..<8).allSatisfy({ u[$0].isFinite }), u[0] > densityFloor else { return false }'''
    patch(anchor,'''        ReconstructionTrace.admissibleInput(u, density: densityFloor, internalEnergy: internalFloor)
        guard (0..<8).allSatisfy({ u[$0].isFinite }), u[0] > densityFloor else { return ReconstructionTrace.admissibleResult(false, energy: nil) }''','observe actual finite/density guard')
    anchor='        return internalEnergy.isFinite && internalEnergy > internalFloor'
    patch(anchor,'        return ReconstructionTrace.admissibleResult(internalEnergy.isFinite && internalEnergy > internalFloor, energy: internalEnergy)','observe actual internal-energy predicate without recomputation')
instrument('Sources/BlastCore/FiniteVolumePressureFit.swift',pressure)
instrument('Sources/BlastCore/ConservedGasReconstruction.swift',conserved)
instrument('Sources/BlastCore/FractionalGasTransport.swift',lambda _:None)
for name in ['Trace.swift','main.swift']:shutil.copyfile(fixtures/name,sources/name)
shutil.copyfile(fixtures/'CapturePackage.swift',args.output/'Package.swift')
(args.output/'bindings.json').write_text(json.dumps({'schemaVersion':1,'variant':args.variant,'scope':'only visibility, stable observation identities and passive trace hooks; arithmetic and control flow restore byte-exactly','sources':bindings},indent=2,sort_keys=True)+'\n')
print('PASS protected source and reversible passive reconstruction bindings',args.variant)
