"""Complete-worker observations with a predeclared independent 12-pair small-family confirmation."""
from pathlib import Path
import json,statistics
root=Path(__file__).resolve().parent
labels=['small','full','null-small','null-districts','confirm-small-v2','null-confirm-v2'];profiles={n:json.loads((root/n/'profile.json').read_text()) for n in labels}
def collect(profile,job):
 ids=sorted({r['repetition'] for r in profile['rows'] if r['job']==job});pairs={i:{r['worker']:r for r in profile['rows'] if r['job']==job and r['repetition']==i} for i in ids}
 med={w:statistics.median(p[w]['totalSeconds'] for p in pairs.values()) for w in ['baseline','candidate']};solve={w:statistics.median(p[w]['solverSeconds'] for p in pairs.values()) for w in ['baseline','candidate']}
 return dict(pairs=len(pairs),medianProcessSeconds=med,medianSolverSeconds=solve,medianProcessRatioPercent=(med['candidate']/med['baseline']-1)*100,pairedProcessChangePercent=[(p['candidate']['totalSeconds']/p['baseline']['totalSeconds']-1)*100 for p in pairs.values()],pairedSolverChangePercent=[(p['candidate']['solverSeconds']/p['baseline']['solverSeconds']-1)*100 for p in pairs.values()],candidateFasterPairs=sum(p['candidate']['totalSeconds']<p['baseline']['totalSeconds'] for p in pairs.values()))
rows=[]
for job in ['blast64','cooling32','cooling64','terrain256','flat512','beirut512']:
 group='full' if job.endswith('512') else 'small';r=dict(job=job,initial=collect(profiles[group],job),initialNull=collect(profiles['null-districts' if group=='full' else 'null-small'],job))
 if group=='small':r.update(confirmation=collect(profiles['confirm-small-v2'],job),confirmationNull=collect(profiles['null-confirm-v2'],job))
 rows.append(r)
d=json.loads((root/'diagnostic/diagnostic.json').read_text());transfer=[dict(worker=r['worker'],events={e['name']:e['count'] for e in r['events'] if any(s in e['name'].lower() for s in ['memcpy','aten::empty','aten::to'])}) for r in d['trace']]
report=dict(status='complete',scope=__doc__,rows=rows,traceCounts=transfer,cacheControls=[dict(case=c['case'],rows=[r['cache'] for r in c['rows']]) for c in d['pairs']],limits='Initial and confirmation cohorts are separate and all retained. Same-source controls are not a pointwise correction or a confidence bound. Transfer/solver reductions alone do not establish complete-worker benefit; promotion requires explicit review of these observations and all correctness/lifetime gates.')
(root/'analysis.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
