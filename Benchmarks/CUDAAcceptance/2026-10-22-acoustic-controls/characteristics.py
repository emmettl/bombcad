"""Double linear characteristic transport of a declared uniform-centre initial interpolant.

Clamp beyond end centres to the ambient boundary state; reflect the left-going pressure
characteristic at x=0. This solves linear acoustics, not nonlinear Euler.
"""
import math

def interpolate(values, dx, x):
    q = x / dx - .5
    if q <= 0: return values[0]
    if q >= len(values)-1: return values[-1]
    i = math.floor(q); w = q-i
    return values[i]*(1-w)+values[i+1]*w

def split(pressure, velocity, density, sound_speed):
    assert len(pressure)==len(velocity) and len(pressure)>1
    return ([(p-density*sound_speed*u)*.5 for p,u in zip(pressure,velocity)],
            [(p+density*sound_speed*u)*.5 for p,u in zip(pressure,velocity)])

def pressure_at(parts, dx, sound_speed, x, time):
    left,right = parts; ct = sound_speed*time
    incident = interpolate(left,dx,x+ct)
    arriving = interpolate(right,dx,x-ct) if x>=ct else interpolate(left,dx,ct-x)
    return incident+arriving
