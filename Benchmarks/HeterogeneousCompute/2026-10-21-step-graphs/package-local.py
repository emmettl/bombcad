"""Publish the audited bounded graph experiment; numerical arrays stay on the PC."""
from pathlib import Path
import hashlib,json,shutil
root=Path('/private/tmp/bombcad-cuda-graphs');data=root/'collected';dest=Path('Benchmarks/HeterogeneousCompute/2026-10-21-step-graphs');dest.mkdir(exist_ok=True)
a=json.loads((data/'analysis.json').read_text());v=json.loads((data/'verification.json').read_text());assert a['status']==v['status']=='complete'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(data/'baseline.py')==sha(Path('Scripts/cuda/run.py'))==v['workerSHA256']['baseline']
for path in (data/'diagnostic').glob('*/result.json'):
 r=json.loads(path.read_text());name='candidate' if path.parent.name.endswith('-candidate') or path.parent.name=='candidate' else 'baseline'
 assert r['sourceSHA256']==v['sourceSHA256'] and r['workerFilesSHA256']=={'run.py':sha(data/(name+'.py')),'job.py':sha(data/'job.py'),'compile.py':sha(data/'compile.py')}
for name in ['metadata.tar.gz','metadata-files.json','metadata-audit.json']:shutil.copy2(root/name,dest/name)
for name in ['analysis.json','verification.json','inputs.json','candidates.json','candidate.patch']:shutil.copy2(data/name,dest/name)
for source,target in [('baseline.py','baseline.py.txt'),('candidate.py','candidate.py.txt'),('profile-worker.py','profile-worker.py.txt'),('verify.py','verify.py.txt'),('diagnose.py','diagnose.py.txt'),('analyse.py','analyse.py.txt'),('supervise.py','supervise.py.txt'),('setup.py','setup.py.txt'),('make-candidate.py','make-candidate.py.txt')]:shutil.copy2(data/source,dest/target)
for name in ['supervise-pilot.py.txt','supervise-comparison.py.txt']:shutil.copy2(root/name,dest/name)
shutil.copy2(data/'diagnostic/diagnostic.json',dest/'diagnostic.json')
shutil.copy2(root/'package-local.py',dest/'package-local.py')
rows=[]
for row in a['rows']:
 g=row['graph'];n=row['identicalWorkerLabels'];rows.append(f"| {row['job']} | {g['medianProcessSeconds']['baseline']:.3f} / {g['medianProcessSeconds']['candidate']:.3f} | {g['medianRatioChangePercent']:+.2f}% | {min(g['pairedProcessChangePercent']):+.2f} to {max(g['pairedProcessChangePercent']):+.2f}% | {n['medianProcessSeconds']['baseline']:.3f} / {n['medianProcessSeconds']['candidate']:.3f} |")
table='\n'.join(rows);samples=sum(p['samples'] for p in v['reports']);unknown=sum(p['exitedBeforeGroupRead'] for p in v['reports'])
summary=f'''# Steady-state CUDA graph dispatch — 21 October 2026

**Decision: no adoption.** The bounded candidate for emmettl/bombcad-work#71 preserves exact
CUDA numerical outputs but does not establish a consistent complete-worker benefit across
these workloads. Production `Scripts/cuda/run.py` remains byte-identical to the measured
baseline at worktree base `d4cc8555eab24dcaba879c277afad78756dbd291`. Broader profiling under
emmettl/bombcad-work#60 remains open; emmettl/bombcad-work#72 separately tracks launch block sizes.

The candidate captures/replays only prepare, axis sweeps and optional terrain redistribution
when the startup CFL ramp reaches one. Graph keys contain axis parity and state/species buffer
identity, including zero-dt batch transitions. Captured uniforms and buffers remain referenced.
Startup steps, dynamic cooling, first-phase recording and every host stop/fatal/batch readback
retain their order. Each iteration still allocates/uploads its prepare uniform, even when the
graph uses its retained constant copy: this isolates grouping from allocation reuse. Capture,
setup, output and teardown are included in complete process cost. This follows the fixed-input
and lifetime constraints in [PyTorch 2.11's CUDA graph documentation](https://docs.pytorch.org/docs/2.11/notes/cuda.html#cuda-graphs).
It does not test batching multiple timesteps, removing control checks, larger graph scopes or
uniform-allocation reuse.

## Complete-worker observations

RTX 3080 Ti, driver 617.42, PyTorch 2.11.0+cu128 / CUDA 12.8. Each case has three alternating
fresh-process baseline/candidate pairs, using the corrected drained-stdout/EOF observer and
equal primed PTX caches. A separate three-pair same-worker control uses the **same baseline
file for both labels**. Seconds are Linux `CLOCK_MONOTONIC_RAW`; deployment/retrieval are outside
timing. Numerical source, precision, input state and all physical targets remain fixed.

| Case | Baseline / graph median process, s | Ratio of medians | Individual paired changes | Same-worker label medians, s |
|---|---:|---:|---:|---:|
{table}

Negative changes mean shorter graph time. The ranges are the three observed paired ratios,
not confidence intervals or error bounds. Flat and Beirut graph labels win only one of three
pairs each; their small median shifts do not establish a reliable gain. Cooling64 wins all
three graph pairs, but a single small case and these variable same-worker controls do not
justify a general/default promotion. Cooling32 worsens in median. Null runs were separate and
later, not a pointwise correction or an attribution of all variation. No solver or cross-backend
speedup is claimed. Full solver times and all row-level observations remain in the archive.

A separate **perturbed** blast64 API trace shows direct `cuLaunchKernel` calls falling from
2,847 to 583, with 569 `cudaGraphLaunch` calls. Runtime `cudaLaunchKernel` counts are 93/99;
these API categories are not summed as a physical-kernel count. Actual graph dispatch works,
but fewer direct driver launches alone do not establish lower complete process cost.

## Independent checks and scope

All 72 timed executions (36 comparisons, 36 same-worker controls) have identical numerical files
per case across repetitions, variants and controls. The independent audit rereads 756 numerical
file instances / {v['numericalBytesVerified']:,} bytes, checks executed-worker/support/source hashes,
input files before/after, dt length/sum, reported clocks/cache paths and result hashes. Every
case also matches 36 retained historical CUDA rows; this is repeated CUDA parity, not a new
physical validation or training-data admission. All five timed process groups independently
have no live non-zombie members after completion.

The diagnostic additionally completes six successful runs (two traced, four one-/two-axis
controls) with exact paired files/dt. The one-axis case starts at an odd global step with an
eight-step startup ramp. Four expected fatal/step-limit runs refuse completion and write no
output; both candidate failures demonstrably replay a graph before refusing. Dynamic cooling,
cut-cell terrain, startup/batch and buffer/axis parity retain their existing semantics in the
tested cases. The diagnostic is outside timing. No failed/contended timing attempt was discarded.

All profiles use the existing shared GPU lease. There are {samples} periodic pre/during/post
resource/lease samples. Every resolved compute process in the non-pilot profiles belongs to
the owned profiler group; {unknown} process observation(s) exited before group resolution.
The pilot records lease/device/process observations without group resolution. These samples
are not proof of laboratory exclusivity. Owned PC build/test/archiving workloads do not overlap GPU timing;
independent hashing/packaging follows the completed diagnostics. No clock/service/default,
precision, mask, phase, tolerance or training-index change.

`metadata.tar.gz` contains 159 independently hash-verified metadata/trace files: exact workers,
profiler/support/source, job identities/hashes, every result JSON, raw logs/samples, diagnostic job specifications and compressed API traces. `metadata-files.json` binds the archive.
Large numerical arrays remain at their receipted PC paths under `~/bombcad-graphs-01a15d45`,
with original inputs retained under the earlier control-study root. The archive omits those
arrays rather than claiming to contain them. Exact monitor versions and reproduction scripts
are retained; `manifest.json` binds this published artifact set.

emmettl/bombcad-work#71 is the completed bounded graph experiment. emmettl/bombcad-work#60 and
emmettl/bombcad-work#59 remain open. emmettl/bombcad-work#47 generation and
emmettl/bombcad-work#62 / emmettl/bombcad-work#63 numerical admission remain gated;
emmettl/bombcad-work#64 reboot/clock persistence remains separate.
'''
(dest/'summary.md').write_text(summary)
manifest=dict(status='complete',issue='emmettl/bombcad-work#71',decision='no adoption',producingBaseRevision='d4cc8555eab24dcaba879c277afad78756dbd291',productionWorkerUnchanged=True,workerSHA256=v['workerSHA256'],sourceSHA256=v['sourceSHA256'],timedRuns=72,diagnosticSuccessfulRuns=6,expectedFailureRuns=4,numericalFileInstances=v['numericalFileInstances'],numericalBytesVerified=v['numericalBytesVerified'],metadataArchiveFilesVerified=159,followup='emmettl/bombcad-work#72',artifactsSHA256={p.name:sha(p) for p in sorted(dest.iterdir()) if p.is_file() and p.name!='manifest.json'})
(dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print('Packaged',len(manifest['artifactsSHA256']),'published files;',samples,'samples;',unknown,'process observation races')
