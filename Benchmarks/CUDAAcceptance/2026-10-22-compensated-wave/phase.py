"""Pure Double summaries of both existing first-phase definitions; never changes a target."""
import math


def whole(pressure,dt):
    if len(pressure)!=len(dt) or not pressure or not all(math.isfinite(x) for x in [*pressure,*dt]):
        raise ValueError('finite paired pressure/timestep histories required')
    if any(x<0 for x in dt):raise ValueError('negative timestep')
    peak=max([0.,*pressure]);total=0.;risen=False;closing=None
    for i,(p,width) in enumerate(zip(pressure,dt)):
        if peak>0 and p>=.5*peak:risen=True
        if risen and p<0:closing=i;break
        total+=max(p,0)*width
    return dict(impulse=total,closingSample=closing,peak=peak)


def streaming(pressure,dt):
    if len(pressure)!=len(dt) or not pressure or not all(math.isfinite(x) for x in [*pressure,*dt]):
        raise ValueError('finite paired pressure/timestep histories required')
    if any(x<0 for x in dt):raise ValueError('negative timestep')
    peak=total=selected=phase_peak=0.;opened=False;closing=None
    for i,(p,width) in enumerate(zip(pressure,dt)):
        total+=max(p,0)*width;peak=max(peak,p)
        if opened:
            if p<0:opened=False;closing=i
            else:selected=total;phase_peak=max(phase_peak,p)
        if p>0 and phase_peak<.5*peak:
            selected=total;phase_peak=p;opened=True;closing=None
    return dict(impulse=selected,closingSample=closing,open=opened,peak=peak)


if __name__=='__main__':
    p=[0.,1.,0.,-1.];dt=[0.,1.,1.,1.]
    assert whole(p,dt)['impulse']==streaming(p,dt)['impulse']==1
    assert whole(p,dt)['closingSample']==streaming(p,dt)['closingSample']==3
    p=[0.,1.,-1.,1.5,-1.,3.,-1.];dt=[0.,1.,1.,1.,1.,1.,1.]
    assert whole(p,dt)['impulse']==2.5 and whole(p,dt)['closingSample']==4
    assert streaming(p,dt)['impulse']==5.5 and streaming(p,dt)['closingSample']==6
    assert whole([0.,1.],[0.,1.])['closingSample'] is None and streaming([0.,1.],[0.,1.])['open']
    print('Single-phase closure, known semantic divergence and open-window controls pass; no wave execution')
