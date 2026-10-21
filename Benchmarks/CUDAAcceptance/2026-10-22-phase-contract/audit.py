"""CPU-only definition audit. Same signed bin means feed both algorithms; no policy or data admission."""
from pathlib import Path
import csv,hashlib,importlib.util,json,math,os,sys
repo=Path.cwd();here=Path(__file__).resolve().parent
sys.path.insert(0,str(repo/'Scripts/cuda'));spec=importlib.util.spec_from_file_location('phase',repo/'Scripts/cuda/diagnose-phase.py');phase=importlib.util.module_from_spec(spec);spec.loader.exec_module(phase)
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def whole(values,dt):
 peak=max(values,default=0)
 if peak<=0:return dict(impulse=0.,peak=peak,closingSample=None)
 impulse=0.;risen=False;closing=None
 for i,p in enumerate(values):
  if p>=.5*peak:risen=True
  if risen and p<0:closing=i;break
  impulse+=max(p,0.)*dt
 return dict(impulse=impulse,peak=peak,closingSample=closing)
def streaming(values,dt,precision='double'):
 cast=float if precision=='double' else phase.f32;dt=cast(dt);peak=total=first=phase_peak=0.;opened=False;closing=None;openings=[]
 for i,value in enumerate(values):
  p=cast(value)
  total=phase.fused_sum(max(p,0.),dt,total) if precision=='float32-fused' else cast(total+cast(max(p,0.)*dt))
  peak=max(peak,p)
  if opened:
   if p<0:opened=False;closing=i
   else:first=total;phase_peak=max(phase_peak,p)
  if p>0 and phase_peak<cast(.5*peak):first=total;phase_peak=p;opened=True;closing=None;openings.append(i)
 return dict(impulse=first,peak=peak,closingSample=closing,openingSamples=openings)
def bin_means(times,pressures,width):
 # Exact trapezoidal area of the declared piecewise-linear interpolant per uniform bin.
 count=round((times[-1]-times[0])/width)
 if not count or abs(count*width-(times[-1]-times[0]))>1e-12:raise ValueError('window must contain whole declared bins')
 result=[];segment=0
 for index in range(count):
  a=times[0]+index*width;b=min(times[-1],times[0]+(index+1)*width);parts=[];x=a
  while x<b:
   while segment+1<len(times)-1 and times[segment+1]<=x:segment+=1
   end=min(b,times[segment+1]);span=times[segment+1]-times[segment]
   if span<=0 or end<=x:raise ValueError('strictly increasing pressure sample times required')
   p0=pressures[segment]+(pressures[segment+1]-pressures[segment])*(x-times[segment])/span
   p1=pressures[segment]+(pressures[segment+1]-pressures[segment])*(end-times[segment])/span
   parts.append((p0+p1)*.5*(end-x));x=end
  result.append(math.fsum(parts)/(b-a))
 original=math.fsum((pressures[i]+pressures[i+1])*.5*(times[i+1]-times[i]) for i in range(len(times)-1))
 l1=math.fsum(abs((pressures[i]+pressures[i+1])*.5*(times[i+1]-times[i])) for i in range(len(times)-1))
 widths=[min(times[-1],times[0]+(i+1)*width)-(times[0]+i*width) for i in range(count)]
 reconstructed=math.fsum(p*w for p,w in zip(result,widths))
 error=abs(original-reconstructed);bound=64*sys.float_info.epsilon*l1
 assert error<=bound,(error,bound)
 return result,dict(originalSignedArea=original,reconstructedSignedArea=reconstructed,error=error,doubleRoundoffBound=bound,finalEndpointAdjustment=times[0]+count*width-times[-1])
# Independent linear interpolation/integration control, including a non-exact final timestamp.
probe,probe_area=bin_means([0,.3,.7,1-1e-16],[-1,-.4,.4,1-2e-16],.25)
assert all(abs(a-b)<=16*sys.float_info.epsilon for a,b in zip(probe,[-.75,-.25,.25,.75]))
fixtures=json.loads((here/'fixtures.json').read_text());controls=[]
for row in fixtures['fixtures']:
 a=whole(row['pressurePa'],row['binS']);b=streaming(row['pressurePa'],row['binS'])
 for actual,expected in [(a['impulse'],row['expectedWholeHistoryImpulse']),(b['impulse'],row['expectedStreamingImpulse'])]:assert abs(actual-expected)<=16*sys.float_info.epsilon*max(1,abs(expected))
 controls.append(dict(name=row['name'],wholeHistory=a,streaming=b,semanticDifference=b['impulse']-a['impulse'],float32Separate=streaming(row['pressurePa'],row['binS'],'float32-separate'),float32Fused=streaming(row['pressurePa'],row['binS'],'float32-fused')))
assert [c['name'] for c in controls if c['semanticDifference']!=0]==['intermediate-qualifying']
receipt_path=repo/'Benchmarks/open/records/pyro2-ideal-gas-balloon-v1/receipt.json';receipt=json.loads(receipt_path.read_text());root=Path(os.environ.get('BOMBCAD_DATA','/Volumes/StudioData/bombcad'))/'open-benchmark/pyro2-decks/entry-20mm';histories=[];rows=[];binned_controls=[]
for item in receipt['histories']:
 path=root/item['path'];assert sha(path)==item['sha256'];gauges={}
 with path.open() as f:
  for row in csv.DictReader(f):
   assert row['case']==item['case'] and row['run']==item['run'];t=float(row['time_s']);p=float(row['overpressure_Pa']);assert math.isfinite(t) and math.isfinite(p)
   gauge=gauges.setdefault(row['gauge'],dict(times=[],pressures=[]));assert not gauge['times'] or t>gauge['times'][-1];gauge['times'].append(t);gauge['pressures'].append(p)
 histories.append(dict(case=item['case'],run=item['run'],path=str(path),sha256=sha(path),gauges=list(gauges)))
 for name,gauge in gauges.items():
  for dt in [25e-6,50e-6,100e-6]:
   values,area=bin_means(gauge['times'],gauge['pressures'],dt);a=whole(values,dt);b=streaming(values,dt)
   binned_controls.append(dict(name='/'.join([item['case'],item['run'],name,str(dt)]),pressurePa=values,binS=dt,expectedWholeHistoryImpulse=a['impulse'],sourceHistorySHA256=item['sha256']))
   rows.append(dict(case=item['case'],run=item['run'],gauge=name,binS=dt,bins=len(values),sameClosingSample=a['closingSample']==b['closingSample'],signedAreaControl=area,wholeHistory=a,streaming=b,semanticDifference=b['impulse']-a['impulse'],relativeDifference=abs(b['impulse']-a['impulse'])/max(abs(a['impulse']),1e-30),meanValuesSHA256=hashlib.sha256(__import__('struct').pack('<'+'d'*len(values),*values)).hexdigest()))
(here/'binned-fixtures.json').write_text(json.dumps(dict(scope='Derived signed piecewise-linear bin means from the receipted histories, for native offline-function validation; not raw histories or physical truth.',fixtures=binned_controls),separators=(',',':'))+'\n')
source_paths=[repo/'Sources/BlastCore/FirstPhaseColumns.swift',repo/'Sources/BlastCore/Shaders/SolverEnvelopes.metal',repo/'Sources/BlastModel/HybridFarField.swift',repo/'Sources/BlastModel/Studies/SurrogateBench.swift',repo/'Scripts/cuda/diagnose-phase.py',receipt_path,repo/'Tests/BlastModelTests/FirstPhaseDefinitionTests.swift',here/'fixtures.json',here/'binned-fixtures.json',Path(__file__)]
report=dict(status='complete',scope=__doc__,revision=__import__('subprocess').check_output(['git','rev-parse','HEAD'],text=True).strip(),worktreeDirty=bool(__import__('subprocess').check_output(['git','status','--porcelain'],text=True).strip()),sourceSHA256={str(p):sha(p) for p in source_paths},linearBinControl=probe_area,fixtureControls=controls,inputHistories=histories,corpusRows=rows,corpusComparisons=len(rows),corpusDifferentComparisons=sum(r['semanticDifference']!=0 for r in rows),corpusDifferentClosingComparisons=sum(not r['sameClosingSample'] for r in rows),corpusComparisonsClosedWithinWindow=sum(r['wholeHistory']['closingSample'] is not None for r in rows),limits='Analytical controls and independent 1-D strong-wave/room-mean histories; not weak-load, local 3-D reflection, physical validation or a target-definition decision. Double arithmetic isolates semantic choice; Float32 fixture variants are models, not new GPU runs. No policy, mask, tolerance or training-index change.')
assert len(rows)==39 and len(histories)==6
(here/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k not in ['fixtureControls','corpusRows','inputHistories','sourceSHA256']},indent=2))
