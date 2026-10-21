"""Package an audited launch-size result and separately labelled CPU-only followup proposal."""
from pathlib import Path
import json,hashlib,shutil
root=Path('/private/tmp/bombcad-launch-blocks');data=root/'collected';dest=Path('Benchmarks/HeterogeneousCompute/2026-10-21-launch-blocks');dest.mkdir(exist_ok=True)
a=json.loads((data/'analysis.json').read_text());v=json.loads((data/'verification.json').read_text());decision=json.loads((root/'decision.json').read_text());assert a['status']==v['status']=='complete' and decision['decision']=='no adoption'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
assert sha(Path('Scripts/cuda/run.py'))==v['workerSHA256']['baseline']
for name in ['metadata.tar.gz','metadata-files.json','metadata-audit.json']:shutil.copy2(root/name,dest/name)
for name in ['analysis.json','verification.json','inputs.json','preflight.json','sources.json','block64.patch','block256.patch']:shutil.copy2(data/name,dest/name)
for name in ['baseline.py','block64.py','block256.py','profile-worker.py','verify.py','analyse.py','diagnose.py','supervise.py','campaign.py','preflight.py','setup.py','setup-local.py']:shutil.copy2(data/name,dest/(name+'.txt'))
shutil.copy2(data/'diagnostic/diagnostic.json',dest/'diagnostic.json');shutil.copy2(root/'decision.json',dest/'decision.json');shutil.copy2(root/'package-local.py',dest/'package-local.py')
proposal=Path('/private/tmp/bombcad-prepare-uniforms');followup=dest/'followup-prepare';followup.mkdir(exist_ok=True)
for source,target in [('summary.md','summary.md'),('prepare.py','prepare.py.txt'),('baseline.py','baseline.py.txt'),('candidate.py','candidate.py.txt'),('candidate.patch','candidate.patch'),('byte-identity.json','byte-identity.json'),('byte-identity.log','byte-identity.log'),('device-prepare-contract.txt','device-prepare-contract.txt')]:shutil.copy2(proposal/source,followup/target)
rows=[]
for row in a['rows']:
 x=row['block64'];y=row['block256'];n=row['sameWorkerLabels']
 rows.append(f"| {row['job']} | {x['medianProcessSeconds']['baseline']:.3f} / {x['medianProcessSeconds']['candidate']:.3f} | {x['medianProcessRatioPercent']:+.2f}% | {y['medianProcessSeconds']['baseline']:.3f} / {y['medianProcessSeconds']['candidate']:.3f} | {y['medianProcessRatioPercent']:+.2f}% | {n['medianProcessSeconds']['baseline']:.3f} / {n['medianProcessSeconds']['candidate']:.3f} |")
samples=sum(r['samples'] for r in v['reports']);unknown=sum(r['exitedBeforeResolution'] for r in v['reports']);archive=json.loads((root/'metadata-audit.json').read_text())
summary=f'''# CUDA launch block sizes — 21 October 2026

**Decision: no adoption.** {decision['rationale']}
The production worker remains byte-identical to the measured 128-thread baseline at producing
base `17bbe21c82f0a8beb676c1e632f56d5217535fa3`. This completes the bounded experiment in
emmettl/bombcad-work#72; broader emmettl/bombcad-work#60 remains open.

## One launch-geometry change at a time

The isolated candidates change only the launch ceiling/divisor and threads per block together,
from 128 to 64 or 256. Generated numerical source, exact cell work, host controls, prepare
allocation, startup, cooling and precision are unchanged; no graphs are used. The preflight
loads both precise cut-cell PTX variants and queries all ten entry functions (20 records),
including supported block limits, registers, shared/local storage. Both candidates fit every
queried limit. Both PTX variants are explicitly primed before timing. Function-specific limits
are described by [NVIDIA's driver API](https://docs.nvidia.com/cuda/cuda-driver-api/cuda_driver_api/group__CUDA__EXEC.html);
legal launch sizes are not automatically efficient ones. Register/storage observations are
retained without attributing timing changes to an unmeasured occupancy mechanism.

## Fresh-worker observations

RTX 3080 Ti / driver 617.42 / PyTorch 2.11.0+cu128 / CUDA 12.8. For each size and case there are
three alternating fresh-process pairs with the current 128-thread worker, equal primed PTX
caches and the corrected drained-stdout/EOF observer. Another three pairs/case run the exact
same baseline file under both labels. Seconds are Linux CLOCK_MONOTONIC_RAW and include
compile/setup/output/teardown, while deployment/retrieval are outside timing.

| Case | Matched 128 / 64 median, s | 64 ratio | Matched 128 / 256 median, s | 256 ratio | Same-worker label medians, s |
|---|---:|---:|---:|---:|---:|
{chr(10).join(rows)}

Negative ratios mean a shorter candidate process. Each candidate size has its **own matched
128 baseline**; raw medians across the separate size batches are not a direct 64-versus-256
comparison. Null controls are later separate observations, not a pointwise correction. Full
paired process/solver observations and win counts are in `analysis.json`. Three repetitions
and observed ranges are not confidence intervals, error bounds or a universal optimal size.
No solver/cross-backend speedup or cost-model promotion is claimed.

## Independent controls and provenance

All {v['timedRuns']} timed runs (72 candidate/baseline executions, 36 identical-worker executions) retain every case's
numerical files/dt across variants, repetitions and labels. The independent audit rereads
{v['numericalFileInstances']} numerical-file instances / {v['numericalBytesVerified']:,} bytes,
checks executed-worker/support/source/input/result hashes, dt length/sum and clocks/cache
routing, and matches all 72 rows of the earlier CUDA graph study. This repeats six retained
CUDA cases; it is not new physical validation, diverse generation or dataset admission.

Separate perturbed instrumentation forwards actual driver calls while checking recorded grid,
block, shared-memory and useful-count fields. All ten entries execute under each size across
blast, cooling and cut-cell terrain controls. Eighteen diagnostic runs succeed with exact
paired outputs/dt; six expected fatal/step-limit runs refuse without completed output. Tail
controls use 31-cubed, 31-by-31-by-1 and 31-by-1-by-1 grids, covering non-multiple launch counts,
single/two/three axes and an odd global start with an eight-step ramp. Tiny control kernels
retain their one-useful-thread guards. No tolerance, mask, label or precision is relaxed.

All profiles use the existing PC GPU lease and retain {samples} periodic resource/ownership
samples. Every resolved compute group is owned; {unknown} observation(s) are unresolved at
group read, and all resource queries succeed. These observations are not proof of laboratory
exclusivity. All six timed process groups independently have no live non-zombie members after
completion. Owned PC builds/checks/archiving are outside timing; diagnostics and independent
hashing follow the timed campaign. No observation or failed attempt is silently discarded.

`metadata.tar.gz` contains {archive['fileInstancesVerified']} independently verified metadata files:
exact workers/support/source, actual command/state/resource logs, all result JSONs, inputs and
hashes, loaded-kernel attributes, driver geometry and diagnostic specifications. The large
numerical arrays stay at their receipted paths under `~/bombcad-blocks-01a15d45`; original job
inputs remain in the earlier control roots. The archive does not claim to contain those arrays.
`metadata-files.json` binds it, and `manifest.json` binds this published artifact set.

## Separate next experiment: repeated prepare uploads

emmettl/bombcad-work#75 tracks a [CPU-only proposal](followup-prepare/summary.md) to cache the
immediately previous complete prepared byte sequence and reuse an immutable GPU buffer only
on exact equality. The original graph trace retained 590 pageable HtoD transfers including
setup/control traffic; per-iteration prepare allocation remained. Byte identity is checked on
this Mac for six 276-byte job configurations and 1005 additional CFL bit patterns. That is
feasibility only: no GPU execution, lifetime proof or performance claim for this proposal, and
its candidate is not mixed into these launch-size measurements or installed in production.

emmettl/bombcad-work#60 and emmettl/bombcad-work#59 remain open; emmettl/bombcad-work#75 is the
separate followup. emmettl/bombcad-work#47 generation and emmettl/bombcad-work#62 /
emmettl/bombcad-work#63 numerical admission remain gated, and emmettl/bombcad-work#64 reboot/clock
persistence remains separate. No host-service, clock, training-index or production default change.
'''
(dest/'summary.md').write_text(summary)
m=dict(status='complete',issue='emmettl/bombcad-work#72',decision=decision,producingBaseRevision='17bbe21c82f0a8beb676c1e632f56d5217535fa3',productionWorkerUnchanged=True,sourceSHA256=v['sourceSHA256'],workerSHA256=v['workerSHA256'],timedRuns=v['timedRuns'],diagnosticSuccesses=v['diagnosticSuccesses'],expectedFailures=v['expectedFailures'],numericalFileInstances=v['numericalFileInstances'],numericalBytesVerified=v['numericalBytesVerified'],metadataArchiveFilesVerified=archive['fileInstancesVerified'],followup='emmettl/bombcad-work#75',artifactsSHA256={str(p.relative_to(dest)):sha(p) for p in sorted(dest.rglob('*')) if p.is_file() and p.name!='manifest.json'})
(dest/'manifest.json').write_text(json.dumps(m,indent=2)+'\n');print('Packaged',len(m['artifactsSHA256']),'published files')
