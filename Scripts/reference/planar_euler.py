"""Independent 1-D ideal-gas MUSCL-Hancock/HLLC precision reference.

Only a rigid left wall and copied right outflow are supported. This is a numerical
reference, not the Metal solver or an exact Euler solution. NumPy Float32 operations
are separate array operations; no claim about GPU fused instruction selection.
"""
import numpy as np


def primitive(state, gamma):
    g = state.dtype.type(gamma)
    rho, momentum, energy = state.T
    velocity = momentum / rho
    pressure = (g - 1) * (energy - .5 * momentum * velocity)
    if not np.isfinite(state).all() or np.any(rho <= 0) or np.any(pressure <= 0):
        raise ValueError('non-finite or non-positive Euler state; no floor applied')
    return np.stack((rho, velocity, pressure), axis=1)


def conserved(w, gamma):
    rho, velocity, pressure = w.T
    g = w.dtype.type(gamma)
    return np.stack((rho, rho * velocity, pressure / (g - 1) + .5 * rho * velocity * velocity), axis=1)


def flux(left, right, gamma):
    g = left.dtype.type(gamma)
    rl, ul, pl = left.T
    rr, ur, pr = right.T
    el = pl / (g - 1) + .5 * rl * ul * ul
    er = pr / (g - 1) + .5 * rr * ur * ur
    cl, cr = np.sqrt(g * pl / rl), np.sqrt(g * pr / rr)
    sl, sr = np.sqrt(rl), np.sqrt(rr)
    inv = 1 / (sl + sr)
    roe_u = (sl * ul + sr * ur) * inv
    roe_h = (sl * (el + pl) / rl + sr * (er + pr) / rr) * inv
    roe_c = np.sqrt(np.maximum((g - 1) * (roe_h - .5 * roe_u * roe_u), 1e-12))
    wave_l = np.minimum(ul - cl, roe_u - roe_c)
    wave_r = np.maximum(ur + cr, roe_u + roe_c)
    fl = np.stack((rl * ul, rl * ul * ul + pl, (el + pl) * ul), axis=1)
    fr = np.stack((rr * ur, rr * ur * ur + pr, (er + pr) * ur), axis=1)
    ml, mr = rl * (wave_l - ul), rr * (wave_r - ur)
    star = (pr - pl + ul * ml - ur * mr) / (ml - mr)
    dl, dr = ml / (wave_l - star), mr / (wave_r - star)
    esl = dl * (el / rl + (star - ul) * (star + pl / ml))
    esr = dr * (er / rr + (star - ur) * (star + pr / mr))
    usl = np.stack((dl, dl * star, esl), axis=1)
    usr = np.stack((dr, dr * star, esr), axis=1)
    ql = np.stack((rl, rl * ul, el), axis=1)
    qr = np.stack((rr, rr * ur, er), axis=1)
    middle = np.where((star >= 0)[:, None], fl + wave_l[:, None] * (usl - ql), fr + wave_r[:, None] * (usr - qr))
    return np.where((wave_l >= 0)[:, None], fl, np.where((wave_r <= 0)[:, None], fr, middle))


def advance(state, dt, dx, gamma):
    """One conservative step; diagnostics report increments absorbed by state rounding."""
    cast = state.dtype.type
    lam = cast(dt) / cast(dx)
    w = primitive(state, gamma)
    ghosts = np.concatenate((w[1::-1].copy(), w, np.repeat(w[-1:], 2, axis=0)))
    ghosts[:2, 1] *= -1
    a = ghosts[1:-1] - ghosts[:-2]
    b = ghosts[2:] - ghosts[1:-1]
    magnitude = np.minimum(1.5 * np.abs(a), np.minimum(.5 * np.abs(a + b), 1.5 * np.abs(b)))
    slope = np.where(((a > 0) & (b > 0)) | ((a < 0) & (b < 0)), np.copysign(magnitude, a), 0)
    mid = ghosts[1:-1]
    rho, velocity, pressure = mid.T
    dr, du, dp = slope.T
    half = .5 * lam
    predicted = np.stack((rho - half * (velocity * dr + rho * du), velocity - half * (velocity * du + dp / rho), pressure - half * (velocity * dp + cast(gamma) * pressure * du)), axis=1)
    low, high = predicted - .5 * slope, predicted + .5 * slope
    valid = (np.minimum(low[:, 0], high[:, 0]) > 1e-6) & (np.minimum(low[:, 2], high[:, 2]) > 1e-3)
    low = np.where(valid[:, None], low, mid)
    high = np.where(valid[:, None], high, mid)
    faces = flux(high[:-1], low[1:], gamma)
    delta = lam * (faces[1:] - faces[:-1])
    updated = state - delta
    primitive(updated, gamma)  # Fail visibly; never silently floor a state.
    nonzero = delta != 0
    lost = nonzero & (updated == state)
    stats = dict(nonzero=np.count_nonzero(nonzero, axis=0), absorbed=np.count_nonzero(lost, axis=0), absIncrement=np.sum(np.abs(delta), axis=0, dtype=np.float64), absAbsorbed=np.sum(np.where(lost, np.abs(delta), 0), axis=0, dtype=np.float64), boundaryFlux=(faces[-1].astype(np.float64)-faces[0].astype(np.float64))*float(cast(dt)), reconstructionFallback=int(np.count_nonzero(~valid)))
    assert updated.dtype == state.dtype and faces.dtype == state.dtype
    return updated, stats
