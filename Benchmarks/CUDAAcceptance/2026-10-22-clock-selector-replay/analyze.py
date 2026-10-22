"""Retain full native selector cross differences and bounded source-order comparisons."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np

from prepare import ROOT,HERE,CAP,load,save,sha
from reference import evaluate
from exact_division import value


def main():
    prep=load(ROOT/'preparation.json');consumed={}
    def pin(p):consumed[str(p)]=sha(p);return p
    receipts={}
    for b in ['metal','cuda']:
        for stage in ['own','cross']:
            r=load(pin(ROOT/(b+'-'+stage)/'receipt.json'));assert r['status']=='complete-all-outcomes';receipts[b,stage]=r
        assert receipts[b,'own']['allOwnWordsExact']
    assert receipts['metal','own']['sourceSHA256']==prep['metalSourceSHA256']==receipts['metal','cross']['sourceSHA256']
    assert receipts['metal','own']['binarySHA256']==receipts['metal','cross']['binarySHA256']
    assert receipts['cuda','own']['compile']==receipts['cuda','cross']['compile']
    assert load(pin(ROOT/'compile.json'))['linkedSDK']=='15.0'
    cf=prep['schemas']['metal']['controlFields'];uf=prep['schemas']['metal']['uniformFields']
    common_names=[n for n,_ in sorted(cf.items(),key=lambda kv:kv[1])]+['speedAfter0','speedAfter1']
    archive=load(HERE.parent/CAP.name/'archive.json')['manifest']
    rows=[];own_words=0
    for name in dict.fromkeys(r['id'] for r in prep['rows']):
        banks={};stats={}
        for origin in ['metal','cuda']:
            item=next(r for r in prep['rows'] if r['id']==name and r['origin']==origin)
            folder=ROOT/item['folder'];n=item['frames']
            def array(key,width):return np.fromfile(pin(folder/(key+'.bin')),dtype='<u4').reshape(n,width)
            c,u,s=array('control',18),array('uniforms',69),array('speed',2)
            expected=np.concatenate([array('expectedControl',18),array('expectedSpeed',2),array('expectedTiles',4)],axis=1)
            outputs={}
            for b,width in [('metal',24),('cuda',20)]:
                stage='own' if b==origin else 'cross';p=ROOT/(b+'-'+stage)/item['label']/'outputs.bin'
                outputs[b]=np.fromfile(pin(p),dtype='<u4').reshape(n,width)
            native=outputs[origin]
            assert np.array_equal(native,expected[:,:native.shape[1]])
            own_words+=native.size
            active=np.flatnonzero(expected[:,0].view('<f4')>0)
            reference=[evaluate(c[i],u[i],s[i,0],cf,uf) for i in range(n)]
            ref=np.array([[r['dtWord'],r['stopped'],r['proposalWord'] or 0] for r in reference],dtype='<u4')
            np.save(ROOT/'banks'/item['label']/'source-order.npy',ref)
            dt_diff=outputs['metal'][:,0]!=outputs['cuda'][:,0]
            word_diffs=outputs['metal'][:,:20]!=outputs['cuda'][:,:20]
            counts={field:int(word_diffs[:,i].sum()) for i,field in enumerate(common_names)}
            stats[origin]=dict(records=n,activeSteps=len(active),sameInputDTWordDifferences=int(dt_diff.sum()),
                sameInputActiveDTWordDifferences=int(dt_diff[active].sum()),
                commonOutputWordDifferences=counts,
                stoppedDecisionDifferences=int(np.count_nonzero(outputs['metal'][:,cf['stopped']]!=outputs['cuda'][:,cf['stopped']])),
                sourceOrderDTWordDifferences={b:int(np.count_nonzero(out[:,0]!=ref[:,0])) for b,out in outputs.items()},
                sourceOrderStoppedDifferences={b:int(np.count_nonzero(out[:,cf['stopped']]!=ref[:,1])) for b,out in outputs.items()},
                metalTileOutputWordDifferences=int(np.count_nonzero(outputs['metal'][:,20:24]!=expected[:,20:24])))
            banks[origin]=dict(c=c,u=u,s=s,outputs=outputs,active=active,ref=ref)
        m,c=banks['metal'],banks['cuda'];assert len(m['active'])==len(c['active'])
        different=np.flatnonzero(m['outputs']['metal'][m['active'],0]!=c['outputs']['cuda'][c['active'],0])
        incoming=[('speed',0)]+[('uniform.'+k,uf[k]) for k in ['cfl','dx','maxStep','forcedStep']]+[('control.'+k,cf[k]) for k in ['batchTime','timeLimit','stepIndex','stopped']]
        def comparison(j):
            im,ic=int(m['active'][j]),int(c['active'][j])
            diff={}
            for key,index in incoming:
                a,b=(int(m['s'][im,index]),int(c['s'][ic,index])) if key=='speed' else ((int(m['u'][im,index]),int(c['u'][ic,index])) if key.startswith('uniform.') else (int(m['c'][im,index]),int(c['c'][ic,index])))
                if a!=b:diff[key]=[a,b]
            matrix={origin:{b:int(bank['outputs'][b][i,0]) for b in ['metal','cuda']}
                for origin,bank,i in [('metal',m,im),('cuda',c,ic)]}
            return dict(activeStep=j+1,metalRow=im,cudaRow=ic,relevantIncomingWordDifferences=diff,
                fastestWords=[int(m['s'][im,0]),int(c['s'][ic,0])],fastest=[value(m['s'][im,0]),value(c['s'][ic,0])],
                dtMatrix=matrix,sourceOrderDTWords=[int(m['ref'][im,0]),int(c['ref'][ic,0])],
                nativeDT=[value(matrix['metal']['metal']),value(matrix['cuda']['cuda'])])
        first=comparison(int(different[0]))
        regions=[]
        if name=='beirut-p0-1':
            pressure={}
            for origin in ['metal','cuda']:
                folder=CAP/('metal' if origin=='metal' else 'capture')/name
                npy=folder/('pressure-trace.npy' if origin=='metal' else 'trace.npy')
                meta=folder/('pressure-trace.json' if origin=='metal' else 'trace.json')
                for p in [npy,meta]:assert sha(pin(p))==archive[str(p.relative_to(CAP))]['sha256']
                pressure[origin]=(np.load(npy),load(meta))
            for step in [2,3,826,827,828,899,900,901]:
                r=comparison(step-1);r['recordedNativeReceiver']={}
                for origin,bank in banks.items():
                    index=step if origin=='metal' else 1+int(bank['active'][step-1])
                    data,info=pressure[origin]
                    r['recordedNativeReceiver'][origin]=dict(rawTime=info['times'][index],
                        pressure=float(data[index,0,0]),impulse=float(data[index,0,3]),open=float(data[index,0,5]))
                regions.append(r)
        rows.append(dict(id=name,nativeActiveDTWordDifferences=len(different),firstDivergence=first,
            pairedActiveFastestWordDifferences=int(np.count_nonzero(m['s'][m['active'],0]!=c['s'][c['active'],0])),
            sameInputSelectorStatistics=stats,beirutRecordedRegions=regions))
    with (ROOT/'reference-controls.log').open('xb') as f:
        control=subprocess.run([sys.executable,'-B',str(HERE/'check_reference.py')],stdout=f,stderr=subprocess.STDOUT)
    assert control.returncode==0
    for mapping in [prep['pins'],prep['consumed'],consumed]:
        for p,h in mapping.items():assert sha(p)==h,p
    for p in HERE.glob('*.py'):shutil.copyfile(p,ROOT/'analysis'/p.name)
    report=dict(status='complete-all-outcomes',rows=rows,consumed=consumed,allNativeOwnWordsExact=True,
        ownOutputWords=int(own_words),analyticControls=4,sourceSHA256=sha(__file__),
        limits='Conditional independent scalar frame replay; full differences including work counters retained. No new evolved trajectory, instruction or continuum attribution, default policy or admission change. Bulk held.')
    save(ROOT/'results.json',report)
    print(json.dumps({k:v for k,v in report.items() if k not in ['consumed']},indent=2))


if __name__=='__main__':main()
