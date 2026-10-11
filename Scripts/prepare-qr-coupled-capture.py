#!/usr/bin/env python3
"""Copy actual CPU reference source and add byte-reversible coupled stage observations."""
import argparse,hashlib,importlib.util,json,shutil,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--variant',choices=['original','shared'],required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--original-source-root',type=Path);args=p.parse_args()
root=Path(__file__).resolve().parents[1];fixtures=root/'Fixtures/QRReconstructionAdoption'
spec=importlib.util.spec_from_file_location('reference_sources',root/'Scripts/check-grouped-gas-reference.py');reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference)
sources=args.output/'Sources/CoupledCapture';sources.mkdir(parents=True,exist_ok=True);bindings=[]
def instrument(name,raw,callback):
    text=raw;patches=[]
    def patch(old,new,label):
        nonlocal text
        assert text.count(old)==1,(name,label);text=text.replace(old,new);patches.append({'original':old,'traced':new,'label':label})
    callback(patch)
    restored=text
    for item in reversed(patches):
        assert restored.count(item['traced'])==1;restored=restored.replace(item['traced'],item['original'])
    assert restored==raw,'unchanged coupled arithmetic/control flow'
    (sources/(name+'.swift')).write_text(text);bindings.append({'path':'Sources/BlastCore/'+name+'.swift','sourceSHA256':hashlib.sha256(raw.encode()).hexdigest(),'compiledSHA256':hashlib.sha256(text.encode()).hexdigest(),'patches':patches})
def moving(patch):
    anchor='''        let advanced = try FractionalEulerFlux.advanceWithWalls(
            cells, faces: faces, walls: walls, duration: plan.duration, cfl: cfl)'''
    patch(anchor,'        QRCoupledTrace.record("moving-stage-input", ["plan": plan, "inventories": inventories, "centres": suppliedCentres as Any, "supplied": supplied, "cells": cells, "faces": faces, "walls": walls, "duration": plan.duration, "cfl": cfl, "limit": limit, "conserved": conservedGeometry != nil])\n'+anchor+'\n        QRCoupledTrace.record("moving-stage-output", ["result": advanced])','observe all actual moving Euler stage inputs/outputs')
    anchor='''        let scattered = limited ? try LimitedMovingGroupScatter.scatter(plan, updated: updated) : nil'''
    patch(anchor,anchor+'\n        QRCoupledTrace.record("moving-final", ["plan": plan, "updated": updated, "wallImpulses": patchImpulses, "wallWork": patchWork, "wallMoments": patchMoments, "reservoir": reservoir, "limit": limit, "integration": timeIntegration.rawValue, "scattered": scattered as Any])','observe corrected Heun inventories and actual final scatter')
    anchor='        return zip(locations, prepared.walls).map { location, wall in'
    patch(anchor,'        QRCoupledTrace.record("initial-wall-prepared", ["plan": plan, "inventories": inventories, "locations": locations, "supplied": supplied, "prepared": prepared])\n'+anchor,'observe complete actual initial wall preparation')
def volume(patch):
    anchor='        let kinds = rawKinds + boundedKinds'
    patch(anchor,'        QRCoupledTrace.record("volume-pressure-fits", ["plan": plan, "body": body, "h": h, "traces": traces, "reference": reference, "rings": stencilRings, "adjacency": adjacency, "stencils": stencils, "samples": samples, "volumeNodes": volumeNodes, "fits": fits, "bounded": bounded, "wallPoints": wallPoints, "allPoints": allPoints])\n'+anchor,'observe actual volume moments, stencil inputs, fits, controls and analytic load reference')
def stationary(patch):
    anchor='''            let first = try FractionalEulerFlux.advanceWithWalls(
                old, faces: firstTraces.faces,
                walls: firstTraces.walls, duration: duration, cfl: cfl)'''
    patch(anchor,'            QRCoupledTrace.record("stationary-first-input", ["cells": old, "faces": firstTraces.faces, "walls": firstTraces.walls, "duration": duration, "cfl": cfl])\n'+anchor+'\n            QRCoupledTrace.record("stationary-first-output", ["result": first])','observe actual stationary first stage')
    anchor='''            let second = try FractionalEulerFlux.advanceWithWalls(
                first.cells, faces: secondTraces.faces,
                walls: secondTraces.walls, duration: duration, cfl: cfl)'''
    patch(anchor,'            QRCoupledTrace.record("stationary-second-input", ["cells": first.cells, "faces": secondTraces.faces, "walls": secondTraces.walls, "duration": duration, "cfl": cfl, "limit": limit])\n'+anchor+'\n            QRCoupledTrace.record("stationary-second-output", ["result": second])','observe actual stationary second stage')
    anchor='''            let checked = try FractionalGasTransport.advance(
                cells, newVolumes: cells.map(\.volume), transfers: [])'''
    patch(anchor,anchor+'\n            QRCoupledTrace.record("stationary-final", ["old": old, "first": first, "second": second, "checked": checked, "boundaries": boundaries])','observe full SSPRK2 accepted result and paired loads')
def reflection(patch):
    anchor='''                            cells = update.cells
                            elapsed += dt
                            steps += 1'''
    patch(anchor,'                            QRCoupledTrace.record("reflection-step", ["before": cells, "update": update, "elapsed": elapsed, "duration": dt, "steps": steps, "rejected": rejected, "impulse": impulse, "exactImpulse": exact, "reference": reference, "area": area, "historyError": historyError, "reflectingImpulse": reflectingImpulse, "wallImpulse": wallImpulse])\n'+anchor,'observe every accepted reflection cell/clock/load step')
def trajectory(patch):
    anchor='''                        let plan = domain.plan
                        let nextBody = body.translated(by: step * velocity)'''
    patch(anchor,'                        QRCoupledTrace.record("trajectory-step", ["before": cells, "result": r, "plan": domain.plan, "body": body, "elapsed": elapsed, "step": step, "velocity": velocity, "target": target, "steps": steps])\n'+anchor,'observe every accepted actual trajectory state and geometry')
hooks={'MovingConnectedGasGroups':moving,'ExperimentalVolumePressureFitStudy':volume,'LimitedGroupedGasFlux':stationary,'ExperimentalWallReflectionStudy':reflection,'ExperimentalMovingTrajectoryStudy':trajectory}
for name in reference.SOURCES:
    path='Sources/BlastCore/'+name+'.swift'
    if args.variant=='original':
        raw=(args.original_source_root/path).read_text() if args.original_source_root else subprocess.check_output(['git','show','b7d86c445d7aa40ed63bab1562e9c956b1c5c31e:'+path],cwd=root).decode()
        protected=json.loads((fixtures/'CoupledOriginalSources.json').read_text())['sources'][path]
        assert hashlib.sha256(raw.encode()).hexdigest()==protected['sha256'], 'protected complete original gas source'
        assert hashlib.sha1(b'blob '+str(len(raw.encode())).encode()+b'\0'+raw.encode()).hexdigest()==protected['blob']
    else:raw=(root/path).read_text()
    instrument(name,raw,hooks.get(name,lambda _:None))
for name in ['CoupledTrace.swift','CoupledMain.swift']:shutil.copyfile(fixtures/name,sources/('main.swift' if name=='CoupledMain.swift' else name))
version='0.1.0-alpha.16' if args.variant=='original' else '0.1.0-alpha.19';products=['.product(name: "CompressibleFlow", package: "continuumkit")']
if args.variant=='shared':products.append('.product(name: "Numerics", package: "continuumkit")')
(args.output/'Package.swift').write_text(f'''// swift-tools-version: 6.4
import PackageDescription
let package = Package(name: "CoupledCapture", platforms: [.macOS(.v15)], dependencies: [.package(url: "https://github.com/emmettl/ContinuumKit.git", exact: "{version}")], targets: [.executableTarget(name: "CoupledCapture", dependencies: [{', '.join(products)}])], swiftLanguageModes: [.v6])
''')
(args.output/'bindings.json').write_text(json.dumps({'schemaVersion':1,'variant':args.variant,'originalRevision':'b7d86c445d7aa40ed63bab1562e9c956b1c5c31e','sources':bindings,'scope':'complete actual CPU gas reference source; only reversible passive stage/state/load observations'},indent=2,sort_keys=True)+'\n')
print('PASS actual coupled CPU source and byte-reversible observations',args.variant,len(bindings))
