"""Exact rational rounding of the written scalar Float32 selector and clip order."""
from fractions import Fraction
from exact_division import value,word,rounded


def f32(x):return value(word(x))


def rnd(x):return 0. if x==0 else value(rounded(x))


def evaluate(control,uniform,speed,cf,uf):
    c=lambda k:value(int(control[cf[k]]))
    u=lambda k:value(int(uniform[uf[k]]))
    stopped=int(control[cf['stopped']])
    if int(speed)>=0x7f800000:return dict(dtWord=0,stopped=3,proposalWord=None)
    fastest=max(value(int(speed)),f32(1e-6))
    numerator=rnd(Fraction(u('cfl'))*Fraction(u('dx')))
    dt=rnd(Fraction(numerator)/Fraction(fastest))
    if u('maxStep')>0:dt=min(dt,u('maxStep'))
    if u('forcedStep')>0:dt=u('forcedStep')
    proposal=word(dt)
    if stopped!=0:dt=0.
    elif int(control[cf['stepIndex']])==0:
        if dt>=c('timeLimit'):dt=max(c('timeLimit'),0.);stopped=2
    elif rnd(Fraction(c('batchTime'))+Fraction(dt))>=rnd(Fraction(f32(.9999))*Fraction(c('timeLimit'))):
        dt=0.;stopped=1
    return dict(dtWord=word(dt),stopped=stopped,proposalWord=proposal)
