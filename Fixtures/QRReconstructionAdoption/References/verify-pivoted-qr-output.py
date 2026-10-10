#!/usr/bin/env python3
"""Independent exact-native least-squares, pivot-policy and complete-factor references."""
import argparse, hashlib, importlib.util, json, math, struct, sys
from fractions import Fraction as F
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('original', Path(__file__).with_name('verify-weighted-qr-audit.py'))
original = importlib.util.module_from_spec(spec); spec.loader.exec_module(original)
EPS = 2**-52
POLICY_CACHE = {}
UPPER_CACHE = {}

def need(ok, message):
    if not ok: raise ValueError(message)
scalar, vector, matrix = original.scalar, original.vector, original.matrix

def normalized(values):
    largest = max(map(abs, values), default=0)
    exponent = math.frexp(largest)[1]-1 if largest else 0
    scaled = []
    for value in values:
        try: s = math.ldexp(value, -exponent); restored = math.ldexp(s, exponent)
        except OverflowError: return None
        if not math.isfinite(s) or restored != value or value != 0 and s == 0: return None
        scaled.append(s)
    return scaled, exponent

def exact_pivot_rank(a, tolerance):
    key = (tuple(map(tuple, a)), tolerance)
    if key in POLICY_CACHE: return POLICY_CACHE[key]
    n = len(a[0]); columns = [[F.from_float(row[j]) for row in a] for j in range(n)]
    g = [[sum(x*y for x,y in zip(c,d)) for d in columns] for c in columns]
    initial = max(g[j][j] for j in range(n)); floor = F.from_float(tolerance)**2 * initial
    rank = 0
    # Exact pivoted Schur complements give squared orthogonal residual norms.
    # No Householder vectors or floating QR code participates in this reference.
    for k in range(n):
        p = max(range(k,n), key=lambda j:g[j][j])
        if g[p][p] <= floor: break
        g[k], g[p] = g[p], g[k]
        for row in g: row[k], row[p] = row[p], row[k]
        pivot = g[k][k]
        for i in range(k+1,n):
            for j in range(k+1,n): g[i][j] -= g[i][k]*g[k][j]/pivot
        rank += 1
    POLICY_CACHE[key] = rank
    return rank

def sqrt_fraction(value):
    if value == 0: return 0.
    exponent = value.numerator.bit_length()-value.denominator.bit_length()
    even = 2*(exponent//2)
    return math.ldexp(math.sqrt(float(value/F(2)**even)),even//2)

def exact_ls(a, b):
    rank, reference = original.exact_factor(a)
    need(rank == len(a[0]), 'supported exact-native full rank')
    columns, inverse = reference
    projected = [sum(v*F.from_float(w) for v,w in zip(col,b)) for col in columns]
    x = [sum(v*w for v,w in zip(row,projected)) for row in inverse]
    residual = [F.from_float(y)-sum(F.from_float(v)*w for v,w in zip(row,x)) for row,y in zip(a,b)]
    norm_a = math.sqrt(sum(v*v for row in a for v in row))
    inverse_trace = sum(inverse[j][j] for j in range(len(inverse)))
    condition = norm_a * sqrt_fraction(inverse_trace)
    return x, residual, norm_a, condition

def upper_condition(r):
    key=tuple(map(tuple,r))
    if key in UPPER_CACHE: return UPPER_CACHE[key]
    n = len(r); a = [[F.from_float(v) for v in row] for row in r]
    norm = max(sum(abs(a[i][j]) for i in range(j+1)) for j in range(n))
    inverse_norm = F(0)
    for j in range(n):
        x = [F(0)]*n
        for i in reversed(range(n)):
            x[i] = (F(i==j)-sum(a[i][k]*x[k] for k in range(i+1,n)))/a[i][i]
        inverse_norm = max(inverse_norm, sum(map(abs,x)))
    result=float(1/(norm*inverse_norm));UPPER_CACHE[key]=result;return result

def extra_inputs():
    cases = {}
    for width in [1,2,3,9,16]:
        for exponent in [-1074,-1022,-1000,-600,-100,0,100,600,1000,1023]:
            scale = math.ldexp(1.,exponent)
            a = [[(float(i==j) if i<width else (((i-width+1)*(j+2))%7-3)/8)*scale for j in range(width)] for i in range(width+3)]
            coeff = [(1 if j%2==0 else -1)*(j+1)/32 for j in range(width)]
            b = [sum(v*w for v,w in zip(row,coeff)) for row in a]
            cases[f'scale/{width}/{exponent}'] = (a,b,1e-10)
    for ti,t in enumerate([EPS,1e-14,1e-10,1e-6,.5]):
        for di,d in enumerate([0.,2**-50,2**-40,2**-34,2**-33,2**-20,.5,1.,t]):
            cases[f'rank/{ti}/{di}'] = ([[1.,0.],[0.,d]],[.25,d/4],t)
    h = sys.float_info.max; tiny = math.ulp(0.)
    cases.update({
        'extreme/greatest':([[h],[-h],[h/2]],[h/2,-h/2,h/4],1e-10),
        'extreme/normalization-A':([[tiny],[h]],[0.,1.],1e-10),
        'extreme/normalization-b':([[1.],[1.]],[tiny,h],1e-10),
        'extreme/solution-overflow':([[tiny]],[1.],1e-10),
        'extreme/solution-underflow':([[h]],[tiny],1e-10),
        'dimension/64':([[float(i==j) for j in range(64)] for i in range(64)],[j/128 for j in range(64)],1e-10),
        'failure/empty':([],[],1e-10), 'failure/no-columns':([[]],[0.],1e-10),
        'failure/ragged':([[1.],[1.,2.]],[1.,2.],1e-10),
        'failure/too-many-columns':([[1.]*65 for _ in range(65)],[1.]*65,1e-10),
        'failure/nan-A':([[math.nan]],[1.],1e-10), 'failure/inf-A':([[math.inf]],[1.],1e-10),
        'failure/nan-b':([[1.]],[math.nan],1e-10), 'failure/inf-b':([[1.]],[math.inf],1e-10),
    })
    hadamard=[[(-1. if bin(i&j).count('1')%2 else 1.)/8 for j in range(64)] for i in range(64)]
    coefficients=[(1 if j%2==0 else -1)*(j+1)/128 for j in range(64)]
    cases['dimension/64-hadamard']=(hadamard,[sum(v*w for v,w in zip(row,coefficients)) for row in hadamard],1e-10)
    tall=hadamard+[[float(i==j)/2 for j in range(64)] for i in range(16)]
    cases['dimension/64-hadamard-tall-noisy']=(tall,[sum(v*w for v,w in zip(row,coefficients))+((i*11)%7-3)/1024 for i,row in enumerate(tall)],1e-10)
    for i,t in enumerate([0.,-1.,math.nan,math.inf,1.,EPS/2]): cases[f'failure/tolerance/{i}'] = ([[1.]],[1.],t)
    return cases

def expected_inputs(raw):
    cases = {'audit/'+r['id']:(matrix(r['rows']),vector(r['rhs']),1e-10) for r in raw['direct']}
    for r in raw['geometry']:
        for key in ['quadraticFactor','linearFactor']:
            factor = r[key]; cases['audit/'+r['id']+'/'+key] = (matrix(factor['rows']),vector(factor['rhs']),1e-10)
    cases.update(extra_inputs())
    return cases

def expected_factor_error(a, tolerance):
    m = len(a); n = len(a[0]) if m else 0
    if not n or m<n or any(len(row)!=n for row in a): return 'invalidDimensions'
    if n>64 or m>1_048_576//n: return 'allocationLimit'
    if not math.isfinite(tolerance) or tolerance<EPS or tolerance>=1: return 'invalidRankTolerance'
    if not all(math.isfinite(v) for row in a for v in row): return 'nonFiniteInput'
    norm = normalized([v for row in a for v in row])
    if norm is None: return 'unrepresentableNormalization'
    an = [norm[0][i*n:(i+1)*n] for i in range(m)]
    if exact_pivot_rank(an,tolerance)<n: return 'rankDeficient'
    return None

def verify_records(records, raw):
    expected = expected_inputs(raw)
    need(len(records)==741 and len({r['id'] for r in records})==741 and {r['id'] for r in records}==set(expected),'complete unique 741-case tree')
    counts = {'factorAccepted':0,'factorRejected':0,'solvesAccepted':0,'solvesRejected':0}
    findings = []; worst_orthogonal = worst_reconstruction = worst_coefficient_fraction = 0.
    for row in records:
        a = matrix(row['rows']); b = vector(row['primaryRHS']); t = scalar(row['tolerance'])
        ea,eb,et = expected[row['id']]
        need(len(a)==len(ea),'native matrix input dimension')
        for actual,wanted in zip(a,ea): original.same(actual,wanted)
        original.same(b,eb); need(t==et or math.isnan(t) and math.isnan(et),'rank tolerance identity')
        error = expected_factor_error(a,t)
        if error:
            need(row.get('factorError')==error,'independent factor rejection '+row['id']); counts['factorRejected']+=1
            need('solves' not in row and 'orthogonalColumns' not in row,'rejected factor construction boundary')
            continue
        need('factorError' not in row,'unexpected rejected supported matrix '+row['id']); counts['factorAccepted']+=1
        m,n = len(a),len(a[0]); normalized_a,ae = normalized([v for values in a for v in values]); an = [normalized_a[i*n:(i+1)*n] for i in range(m)]
        need(row['rowCount']==m and row['columnCount']==n and row['matrixScaleExponent']==ae,'factor dimensions/scaling')
        q = matrix(row['orthogonalColumns']); r = matrix(row['scaledUpperTriangular']); p = row['permutation']
        need(len(q)==n and all(len(c)==m for c in q) and len(r)==n and all(len(c)==n for c in r),'full thin Q and R coverage')
        need(sorted(p)==list(range(n)) and all(math.isfinite(v) for values in q+r for v in values),'finite factor/permutation')
        need(all(r[i][j]==0 for i in range(n) for j in range(i)) and all(r[i][i]!=0 for i in range(n)),'triangular factor')
        orthogonal = max(abs(sum(x*y for x,y in zip(q[i],q[j]))-float(i==j)) for i in range(n) for j in range(n))
        scale = max(abs(v) for values in an for v in values)
        reconstruction = max(abs(sum(q[k][i]*r[k][j] for k in range(n))-an[i][p[j]])/scale for i in range(m) for j in range(n))
        bound = 256*EPS*max(m,n)
        need(orthogonal<=bound and reconstruction<=bound,'orthogonality/reconstruction '+row['id'])
        worst_orthogonal=max(worst_orthogonal,orthogonal); worst_reconstruction=max(worst_reconstruction,reconstruction)
        rc = scalar(row['reciprocalConditionEstimate']); reference_rc = upper_condition(r)
        need(0<=rc<=1 and abs(rc-reference_rc)<=max(8*math.ulp(reference_rc),1024*EPS*n*reference_rc),'independent triangular condition diagnostic')
        need(row['repeatPrimaryIdentical'] is True,'reused factor repeated solve identity')
        solves = row['solves']; need(len(solves)==3 and [s['id'] for s in solves]==['primary','alternate','zero'],'complete distinct repeated RHS tree')
        alternate = [sum(v*((-1 if j%2==0 else 1)*(j+1)/32) for j,v in enumerate(values)) for values in a]
        for result,expected_b in zip(solves,[b,alternate,[0.]*m]):
            rhs = vector(result['rhs']); original.same(rhs,expected_b)
            solve_error = 'invalidDimensions' if len(rhs)!=m else 'nonFiniteInput' if not all(math.isfinite(v) for v in rhs) else None
            normalized_b = normalized(rhs) if solve_error is None else None
            if solve_error is None and normalized_b is None: solve_error='unrepresentableNormalization'
            if solve_error:
                need(result.get('error')==solve_error,'complete RHS error '+row['id']); counts['solvesRejected']+=1; continue
            bn,be = normalized_b
            ref_x,ref_residual,norm_a,condition = exact_ls(an,bn)
            physical = [x*F(2)**(be-ae) for x in ref_x]
            def representable(x):
                try: v=float(x)
                except OverflowError: return False
                return math.isfinite(v) and (x==0 or v!=0)
            if not all(map(representable,physical)):
                need(result.get('error')=='unrepresentableSolution','coefficient representability error'); counts['solvesRejected']+=1; continue
            need('error' not in result,'unexpected unsupported solve '+row['id']); counts['solvesAccepted']+=1
            coeff = vector(result['coefficients']); need(len(coeff)==n and all(map(math.isfinite,coeff)),'finite original-order coefficients')
            beta = [F.from_float(v)*F(2)**(ae-be) for v in coeff]
            norm_x = sqrt_fraction(sum(v*v for v in ref_x)); norm_b = math.hypot(*bn)
            residual = sqrt_fraction(sum(v*v for v in ref_residual))
            coefficient_bound = 64*EPS*max(m,n)*condition*(norm_x+condition*residual/norm_a)
            coefficient_error = sqrt_fraction(sum((v-w)**2 for v,w in zip(beta,ref_x)))
            floor = max((8*math.ulp(float(x)) for x in ref_x),default=0.)
            need(coefficient_error<=max(floor,coefficient_bound),'conditioning-aware coefficient reference '+row['id'])
            fraction = coefficient_error/max(floor,coefficient_bound) if max(floor,coefficient_bound) else 0
            worst_coefficient_fraction=max(worst_coefficient_fraction,fraction)
            actual_residual = [F.from_float(y)-sum(F.from_float(v)*w for v,w in zip(values,beta)) for values,y in zip(an,bn)]
            gradient = [sum(F.from_float(values[j])*rr for values,rr in zip(an,actual_residual)) for j in range(n)]
            gradient_norm = sqrt_fraction(sum(v*v for v in gradient))
            beta_norm = sqrt_fraction(sum(v*v for v in beta))
            need(gradient_norm<=256*EPS*max(m,n)*norm_a*(norm_a*beta_norm+norm_b),'independent normal-equation residual')
            diagnostic = scalar(result['scaledResidualNorm'])
            need(result['rhsScaleExponent']==be and diagnostic>=0 and math.isfinite(diagnostic),'RHS scaling/residual representation')
            residual_bound = 128*EPS*max(m,n)*(norm_b+norm_a*norm_x)
            need(abs(diagnostic-residual)<=max(8*math.ulp(residual),residual_bound),'independent optimal residual diagnostic')
            predictions = vector(result['predictions']); need(len(predictions)==m,'complete row prediction tree')
            for values,v in zip(a,predictions):
                wanted=sum(x*y for x,y in zip(values,coeff))
                need(v==wanted or math.isnan(v) and math.isnan(wanted),'native consumer diagnostic prediction')
            if result['id']=='zero':need(all(v==0 for v in coeff) and diagnostic==0,'exact zero RHS')
            findings.append({'id':row['id']+'/'+result['id'],'conditionFrobenius':condition,'coefficientError':coefficient_error,'coefficientBound':coefficient_bound,'normalEquationResidual':gradient_norm,'scaledOptimalResidual':residual})
    return {'schemaVersion':1,'cases':741,'counts':counts,'worstOrthogonality':worst_orthogonal,'worstRelativeReconstruction':worst_reconstruction,'worstCoefficientBoundFraction':worst_coefficient_fraction,'findings':findings,'scope':'chosen native cohort; conditioning-dependent coefficient diagnostics are not a universal forward-error theorem'}

def verify_source(root):
    root=Path(root);env=json.loads((root/'environment.json').read_text())
    need(env['schemaVersion']==1 and env['workingTreeDirty'] is False and env['flags']==['-c','release','-Xswiftc','-warnings-as-errors'],'clean optimized Git consumer provenance')
    need(len(env['candidateRevision'])==40 and all(v in '0123456789abcdef' for v in env['candidateRevision']),'candidate revision')
    sources=root/'reference-sources';files={str(p.relative_to(sources)):p for p in sources.rglob('*') if p.is_file()}
    need(set(files)==set(env['sourceHashes']),'complete source/reference/fixture identities')
    for name,p in files.items():need(hashlib.sha256(p.read_bytes()).hexdigest()==env['sourceHashes'][name],'recorded source hash')
    pinned=json.loads((root/'consumer-Package.resolved').read_text());pins=pinned['pins']
    need(len(pins)==1 and pins[0]['identity']=='continuumkit' and pins[0]['state']['revision']==env['candidateRevision'],'public consumer exact Git pin')
    if env['candidateVersion']:need(pins[0]['state']['version']==env['candidateVersion'],'public consumer exact version')
    original_env=json.loads((root/'original-audit/environment.json').read_text())
    need(original_env['producerRevision']==env['candidateRevision'] and original_env['hardware']==env['hardware'],'protected original arithmetic producer/hardware binding')
    need(not any('/'+f+'.framework/' in (root/'linkage.txt').read_text() for f in ['Metal','MetalKit','AppKit','SwiftUI','Accelerate']),'CPU-only numerical dependency boundary')
    print('PASS clean source identities and optimized public Git consumer pin')

def verify(root):
    root=Path(root); verify_source(root); original.verify(root/'original-audit')
    data=json.loads((root/'results.json').read_text()); need(set(data)=={'schemaVersion','records','limits'} and data['schemaVersion']==1,'consumer schema')
    need(data['limits']['columns']==64 and data['limits']['elements']==1_048_576 and scalar(data['limits']['defaultTolerance'])==1e-10,'public allocation/default policy')
    raw=json.loads((root/'original-audit/original.json').read_text()); report=verify_records(data['records'],raw)
    (root/'conformance.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    print('PASS independent pivoted QR factors/rank/conditioning/repeated RHS:',report['counts'])
    return report

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('root',type=Path);a=p.parse_args();verify(a.root)
