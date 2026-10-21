"""Package bounded source reuse evidence; full source trees remain on the PC, not in this archive."""
import hashlib,json,re,shutil,tarfile,io
from pathlib import Path
root=Path('/private/tmp/bombcad-source-reuse');dest=Path('Benchmarks/HeterogeneousCompute/2026-10-21-source-reuse');dest.mkdir(exist_ok=True)
r=json.loads((root/'study.json').read_text());audit=json.loads((root/'remote-audit.json').read_text());assert r['status']==audit['status']=='complete'
assert hashlib.sha256(Path('Scripts/remote-sweep.py').read_bytes()).hexdigest()==r['finalRunnerSHA256']==audit['records'][-1]['runnerSHA256']
control=json.loads((root/'cleanup-race-controls.json').read_text());assert control['productionRunnerSHA256']==r['finalRunnerSHA256'];assert control['testsSHA256']==hashlib.sha256(Path('Scripts/test-remote-sweep.py').read_bytes()).hexdigest()
rows=[]
for label,name in [('full reference','full-transfer.log'),('A: changed worktree plus new asset','a-transfer.log'),('B: byte and mode changes','b-transfer.log'),('C: unchanged source; invalid output path','c-transfer.log')]:
 text=(root/name).read_text();rows.append(dict(label=label,sourceBytes=int(re.search(r'Total file size: (\d+)',text)[1]),transferredFileBytes=int(re.search(r'Total transferred file size: (\d+)',text)[1]),totalSentBytes=int(re.search(r'Total sent: (\d+)',text)[1])))
(root/'transfer-table.json').write_text(json.dumps(rows,indent=2)+'\n')
# Read every archived receipt, and verify each requested invocation has all four records.
with tarfile.open(root/'stage-receipts.tar.gz') as archive:
 names=archive.getnames();expected={o['invocation']+'/'+n for o in r['invocations'] for n in ['manifest.json','request.json','started.json','completion.json']};assert set(names)==expected
 for member in archive.getmembers():json.loads(archive.extractfile(member).read())
(root/'archive-audit.json').write_text(json.dumps(dict(status='complete',stageReceiptRecordsVerified=len(expected)),indent=2)+'\n')
shutil.copy2(root/'source/Scripts/remote-sweep.py',root/'protocol-measured.py.txt');shutil.copy2('Scripts/remote-sweep.py',root/'protocol-final.py.txt');shutil.copy2('Scripts/test-remote-sweep.py',root/'tests-final.py.txt')
files=[p for p in sorted(root.iterdir()) if p.is_file() and p.name not in {'issue-59.json','open-issues.json','sync-tracker.py'} and p.suffix in ['.py','.json','.log','.txt','.gz']]
files+=sorted(p for p in (root/'retrieved').rglob('*') if p.is_file())
files+=sorted(p for p in (root/'dist').rglob('*') if p.is_file())
record={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
with tarfile.open(dest/'state.tar.gz','w:gz') as archive:
 for p in files:archive.add(p,arcname=str(p.relative_to(root)),recursive=False)
with tarfile.open(dest/'state.tar.gz') as archive:
 for name,sha in record.items():assert hashlib.sha256(archive.extractfile(name).read()).hexdigest()==sha
(dest/'archive-files.json').write_text(json.dumps(record,indent=2)+'\n')
for name in ['study.json','remote-audit.json','baseline-audit.json','transfer-table.json','openrsync-mode-control.json','protocol-final.py.txt','tests-final.py.txt','check-final.log','check-publish.log','linux-final-controls.log','linux-cleanup-race-controls.log','cleanup-race-controls.json','unit-final.log','package.py']:shutil.copy2(root/name,dest/name)
summary='''# CPU source snapshot reuse — 21 October 2026

Implemented emmettl/bombcad-work#70 while retaining emmettl/bombcad-work#68's private staging,
lease-protected build checkout, payload verification and cached recovery. A new invocation
selects a verified, completed source stage, builds a private hard-link view of files with the
requested SHA-256 **and permissions**, and sends source with checksummed rsync `--link-dest`.
It never links the mutable build checkout. Directories, symlinks, tools and inputs transfer
normally. Missing/corrupt optional basis data falls back; incomplete source cannot execute.
All source/fixture/benchmark assets remain represented, with the previous source-only exclusions.

## Bounded PC evidence

The source was frozen from worktree base `34c280084c62b101139b446d56ea7ec592e7a61b` plus the
retained measured candidate. A generated 4 MiB source control asset and one-byte/mode controls
were added. Full reference and A have identical verified source manifests. All numbers below
are rsync **source file data**, with metadata traffic shown separately in `transfer-table.json`.

| Transfer | Source tree bytes | Transferred file bytes |
|---|---:|---:|
| Full destination control | 247,180,592 | 247,180,592 |
| A: changed worktree and new control asset | 247,180,592 | 5,274,307 |
| B: same-size/same-mtime byte edit and permission edit | 247,180,592 | 5 |
| C: unchanged source | 247,180,592 | 0 |

A reused the previous completed protocol-validation stage. B and C reused A and B. B's old/new
byte and permission values remain distinct; all three share the unchanged 4 MiB file's inode.
The three source trees represent 741,541,776 logical file bytes using 247,180,597 unique-inode
logical bytes (253,407,232 allocated bytes including block rounding). This proves storage
sharing among these trees; it is not a whole-disk accounting or solver-speed claim. File-list,
checksum and helper work remain. For C, the sender still sent 284,383 bytes of metadata/protocol
traffic. Transfer timing is printed but is not an isolated end-to-end scheduling benchmark.

The first run request C failed because its nested output parent did not exist. Its failure,
case log, receipt and cached exit 1 are preserved; it was not replayed or rewritten. A fresh
supported output path succeeded in D. D/E validate the final helper revision, which additionally
skips malformed optional basis metadata: 69,926 source file bytes transferred for two changed
scripts in D, then zero source file bytes in E from a 242,986,841-byte source tree. The temporary
source controls are absent from D/E. They remain intact in A/B/C after later builds.

Normal test lanes A/B/E each passed the three receiver-fixture tests. B/E cached test recovery
and D cached run recovery passed without rebuilding/reexecuting. D's receiver results agree
exactly as JSON with the earlier PC study; its declared `dist/__pycache__` input tree retains
full payload identity. Host/local retrieval manifests verify. This repeats fixture evidence,
not an independent physics experiment. All five source/input/tool/request snapshots and their
completed result trees, including C's failure, independently verify. The sampled build-cache
file has a separate inode from the staged source and identical expected contents.

## Controls and validation

All 23 controller tests pass on Mac through final `make check-affected` and directly on Linux
from E's final source. A final test-only extension removes a selected basis during actual link
preparation; all 23 tests pass again on Mac and in an isolated owned Linux control root with
the unchanged final production helper. The final test-file hash and both supplemental logs
are retained. The controls include prior concurrency/stale-owner/interruption/recovery controls,
real rsync unchanged-file inode sharing, same-size/mtime edits, mode isolation, mutable-cache
independence, missing basis, corrupt/wrong-identity/malformed metadata and uncompleted-stage
refusal. The affected checks pass lint and the script/docs suite, including 71 CUDA/queue tests
(four local Torch skips). The final evidence-set check also passes the strict build with no
warnings, 44 selected Mac tests and 68 PC tests in 15 suites. No Swift model or solver code changes.

A direct unfiltered `--link-dest` control reproduces an openrsync permission issue on Mac:
requested mode 0700 yielded a linked 0644 destination. The final implementation filters basis
file records before rsync, so a mode change transfers separately; this passes on Mac and Linux.
The reproduction, exact measured/final helpers, scripts, raw logs, all 20 staged metadata
records, result/retrieval data and per-file archive hashes are retained in `state.tar.gz`.
The archive omits full source trees; their verified manifests and retained PC stages bind them.

There is no automatic stage garbage collector. Retained views share file allocations, and
cleanup must preserve active or recoverable snapshots. Old clients still require updating.
No GPU reservation, solver/default/phase/mask/tolerance/index/host-service change.
emmettl/bombcad-work#59 remains open for broader distributed integration;
emmettl/bombcad-work#62 and emmettl/bombcad-work#63 numerical admission remain open,
and emmettl/bombcad-work#47 generation remains gated. See [Linux runner use](../../../docs/linux.md).
'''
(dest/'summary.md').write_text(summary)
manifest=dict(status='complete',issue='emmettl/bombcad-work#70',baseRevision=r['baseRevision'],finalRunnerSHA256=r['finalRunnerSHA256'],finalInvocations=[x['invocation'] for x in r['invocations'][-2:]],archiveFilesVerified=len(record),stageReceiptRecordsVerified=len(expected),failedAttemptRetained=True,validation='Final make check-affected passed (covered): strict build without warnings, lint/scripts/docs, 71 CUDA/queue tests (4 local Torch skips), 44 Mac and 68 PC tests; supplemental current 23 controls Mac/Linux including cleanup race; real CPU run/test and cached success/failure recovery; all stage/result manifests verified',artifactsSHA256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(dest.iterdir()) if p.is_file() and p.name!='manifest.json'})
(dest/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n');print(json.dumps(dict(archiveFilesVerified=len(record),archiveBytes=(dest/'state.tar.gz').stat().st_size),indent=2))
