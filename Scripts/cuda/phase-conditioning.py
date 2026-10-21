#!/usr/bin/env python3
"""Offline sensitivity sweep of the existing phase recorder's closing threshold.

Uses pressure traces only, never production recorder-only traces. Candidate
negative deadbands are multiples of float32 ambient-pressure spacing. This
preselected discrepancy subset is exploratory, not held-out or physical
validation, and the script does not select or change a production rule.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import struct


def module(path,name):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value)
    return value


def f32(value):return struct.unpack('<f',struct.pack('<f',value))[0]


def pressure_spacing(ambient):
    if not math.isfinite(ambient) or ambient<=0:raise ValueError('positive finite ambient pressure required')
    ambient=f32(ambient);bits=struct.unpack('<I',struct.pack('<f',ambient))[0]
    higher=struct.unpack('<f',struct.pack('<I',bits+1))[0]
    spacing=higher-ambient
    if not math.isfinite(spacing) or spacing<=0:raise ValueError('finite float32 pressure spacing required')
    return ambient,spacing


def replay(meta,data,q,deadband):
    columns=len(meta['columns']);initial=data[q*8:q*8+8]
    peak,all_impulse,first,phase_peak=initial[1:5];opened=initial[5];closings=[]
    for sample in range(1,len(meta['times'])):
        r=data[(sample*columns+q)*8:(sample*columns+q+1)*8];p,dt=r[0],r[6]
        if dt<=0:continue
        all_impulse=f32(all_impulse+f32(max(p,0.)*dt));peak=max(peak,p)
        if opened:
            if p < -deadband:opened=0.;closings.append(sample)
            elif p>=0:first=all_impulse;phase_peak=max(phase_peak,p)
        if p>0 and phase_peak<.5*peak:first=all_impulse;phase_peak=p;opened=1.
    return {'firstPhaseImpulse':first,'closingSamples':closings,
            'closingTimes':[meta['times'][i] for i in closings]}


def analytic_controls(spacing,multipliers):
    controls=[]
    # Two positive phases separated by a sustained, genuine 5%-of-peak negative interval.
    # These are analytic histories, not CFD validation or measured blast records.
    for amplitude in (1.,10.,100.):
        pressure=[0.,amplitude,.6*amplitude,-.05*amplitude,-.05*amplitude,
                  .8*amplitude,.4*amplitude,-.5*amplitude]
        meta={'columns':[0],'times':[i*.01 for i in range(len(pressure))]}
        data=[]
        for i,p in enumerate(pressure):data.extend([f32(p),0.,0.,0.,0.,0.,f32(.01) if i else 0.,0.])
        outcomes={str(m):replay(meta,data,0,m*spacing)['firstPhaseImpulse'] for m in multipliers}
        controls.append({'peakPa':amplitude,'negativeIntervalPa':-.05*amplitude,
            'negativeDurationS':.02,'exactFirstPositiveImpulsePaS':.016*amplitude,
            'candidateFirstPhaseImpulsePaS':outcomes})
    return {'scope':'Analytic counterexamples, not CFD or measured-data validation. A pressure-only band may merge two genuine positive phases despite a sustained negative interval.',
            'histories':controls}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--groups',type=Path,required=True,help='JSON: case name -> backend name -> pressure-trace directory')
    p.add_argument('--ambient-pressure',type=float,required=True)
    p.add_argument('--spacing-multipliers',default='0,1,2,4,8,16')
    p.add_argument('--out',type=Path,required=True)
    a=p.parse_args()
    try:
        ambient,spacing=pressure_spacing(a.ambient_pressure)
        multipliers=[int(v) for v in a.spacing_multipliers.split(',')]
        if not multipliers or min(multipliers)<0 or len(set(multipliers))!=len(multipliers) or 0 not in multipliers:
            raise ValueError('distinct nonnegative multipliers including zero required')
    except (ValueError,OverflowError) as error:p.error(str(error))
    if a.out.exists():p.error('output must be new')
    loader=module(Path(__file__).with_name('diagnose-phase.py'),'conditioning_pressure_traces')
    groups=json.loads(a.groups.read_text());report={}
    inputs={}
    for case,backends in groups.items():
        if len(backends)<2:raise ValueError('at least two arithmetic/backend traces per group required')
        loaded={}
        for name,text in backends.items():
            folder=Path(text)
            if not folder.is_absolute():folder=(a.groups.parent/folder).resolve()
            meta,data=loader.load(folder);loaded[name]=(meta,data)
            inputs[case+'/'+name]={path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in folder.iterdir()
                                      if path.name in ('trace.json','trace.npy','trace.bin','trace-f32.bin.gz')}
        columns=next(iter(loaded.values()))[0]['columns']
        if any(m['columns']!=columns for m,_ in loaded.values()):raise ValueError('column sets/order differ')
        rows=[]
        for q,column in enumerate(columns):
            outcomes={}
            baseline_actual={name:data[((len(meta['times'])-1)*len(columns)+q)*8+3] for name,(meta,data) in loaded.items()}
            for multiple in multipliers:
                results={name:replay(meta,data,q,spacing*multiple) for name,(meta,data) in loaded.items()}
                values=[r['firstPhaseImpulse'] for r in results.values()]
                outcomes[str(multiple)]={'deadbandPa':spacing*multiple,'backends':results,
                    'rangePaS':max(values)-min(values),
                    'relativeRange':(max(values)-min(values))/max(max(abs(v) for v in values),1e-30),
                    'changeFromRecordedBaseline':{name:r['firstPhaseImpulse']-baseline_actual[name] for name,r in results.items()}}
            rows.append({'column':column,'actualRecordedFirstPhase':baseline_actual,'candidates':outcomes})
        report[case]=rows
    result={'format':'bombcad-phase-conditioning-study-1','ambientPressurePa':ambient,'float32AmbientSpacingPa':spacing,
            'spacingMultipliers':multipliers,'analyticControls':analytic_controls(spacing,multipliers),'inputSHA256':inputs,'groups':report,
            'scope':'Offline replay of preselected discrepancy columns; not held-out/full-field/physical validation. Negative band keeps a phase open but adds no negative impulse. No production rule or tolerance changes and no winning policy selected.',
            'replayScope':'Unfused float32 accumulation; zero-band replay error against each recorded backend is reported, not assumed zero for fused arithmetic',
            'qualification':'Ambient float32 spacing is a probe scale, not a total error bound. Columns were preselected for disagreement; reduction here does not select a valid threshold.',
            'groupsSHA256':hashlib.sha256(a.groups.read_bytes()).hexdigest(),
            'runnerSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    with a.out.open('x') as f:json.dump(result,f,indent=2);f.write('\n')


if __name__=='__main__':main()
