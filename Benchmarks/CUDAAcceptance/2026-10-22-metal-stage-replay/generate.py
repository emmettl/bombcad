"""Append a fixed captured-local sibling; keep frozen production helpers intact."""
import json
from pathlib import Path
import sys


def build(source,kernel):
    start=source.index('static inline void stencilFluxes(');end=source.index('\n}',start)+2
    original=source[start:end]
    def replace(text,old,new):
        assert text.count(old)==1,old
        return text.replace(old,new)
    function=replace(original,'stencilFluxes(','stencilFluxesObserved(')
    function=replace(function,'thread Flux &low, thread Flux &high) {',
                     'thread Flux &low, thread Flux &high, device float *observed, uint base) {')
    slope_specs=[('dM1','slope(wM2, wM1, w0, theta)'),('dC','slope(wM1, w0, wP1, theta)'),('dP1','slope(w0, wP1, wP2, theta)')]
    for name,expression in slope_specs:function=replace(function,expression,name)
    function=replace(function,'    float theta = u.limiterTheta;',
        '    float theta = u.limiterTheta;\n'+'\n'.join('    Prim '+n+' = '+e+';' for n,e in slope_specs))
    fields=['low.mass','low.mx','low.my','low.mz','low.energy','high.mass','high.mx','high.my','high.mz','high.energy']
    expressions=[]
    attributes=[('rho','rho'),('vx','v.x'),('vy','v.y'),('vz','v.z'),('p','p'),('g','g')]
    for name,var in [('M2','wM2'),('M1','wM1'),('C','w0'),('P1','wP1'),('P2','wP2')]:
        for label,member in attributes:fields.append('primitive.'+name+'.'+label);expressions.append(var+'.'+member)
    for name,var in [('M1','dM1'),('C','dC'),('P1','dP1')]:
        for label,member in attributes[:-1]:fields.append('slope.'+name+'.'+label);expressions.append(var+'.'+member)
    for name,var in [('M1.lo','facesM1.lo'),('M1.hi','facesM1.hi'),('C.lo','faces0.lo'),('C.hi','faces0.hi'),('P1.lo','facesP1.lo'),('P1.hi','facesP1.hi')]:
        for label,member in attributes:fields.append('face.'+name+'.'+label);expressions.append(var+'.'+member)
    assert len(fields)==91 and len(set(fields))==91 and len(expressions)==81
    stores='\n'.join('    observed[base + '+str(i+10)+'] = '+e+';' for i,e in enumerate(expressions))
    function=replace(function,'    high = riemannFlux(faces0.hi, facesP1.lo, u);',
                     '    high = riemannFlux(faces0.hi, facesP1.lo, u);\n'+stores)
    kernel=replace(kernel,'stencilFluxes(w[0], w[1], w[2], w[3], w[4], lambdas[tid], u, low, high);',
                   'stencilFluxesObserved(w[0], w[1], w[2], w[3], w[4], lambdas[tid], u, low, high, output, tid * 91);')
    assert kernel.count('tid * 10')==10
    kernel=kernel.replace('tid * 10','tid * 91')
    return source+'\n'+function+'\n'+kernel,fields


if __name__=='__main__':
    source,kernel,out,layout=map(Path,sys.argv[1:]);text,fields=build(source.read_text(),kernel.read_text())
    with out.open('x') as f:f.write(text)
    with layout.open('x') as f:json.dump(dict(format='bombcad-replay-stages-1',fields=fields,words=91,scope='Actual locals in a separate replay; no production-intermediate attestation'),f,indent=2);f.write('\n')
