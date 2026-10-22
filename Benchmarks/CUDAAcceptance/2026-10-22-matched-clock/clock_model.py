"""Written scalar Float32 batch/clip model; device ledger remains the acceptance gate."""
import math
import struct

TICKS = 2**40


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def word(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def origin_ticks(start):
    if not math.isfinite(start) or start < 0:
        raise ValueError('finite nonnegative initial epoch required')
    return math.floor(start * TICKS + .5)


def simulate(history, duration):
    history = list(map(f32, history))
    if not history or not all(math.isfinite(x) and x > 0 for x in history):
        raise ValueError('nonempty finite positive Float32 schedule required')
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError('finite positive duration required')
    actual, events = [], []
    batch, index, limit, clock, stopped = 0., 0, f32(duration), 0, 0
    for iteration in range(len(history) + 100):
        if len(actual) >= len(history):
            break
        proposed = history[len(actual)]
        dt, stopped = proposed, 0
        if index == 0:
            if dt >= limit:
                dt, stopped = max(limit, 0.), 2
        elif f32(batch + dt) >= f32(f32(.9999) * limit):
            dt, stopped = 0., 1
        batch = f32(batch + dt)
        clock += int(f32(max(dt, 0.) * TICKS))
        index += 1
        events.append(dict(dt=dt, dtWord=word(dt), stopped=stopped, stepIndex=index,
                           batchTime=batch, clockTicks=clock))
        if dt > 0:
            actual.append(dt)
        if stopped == 2:
            break
        if stopped == 1:
            index, batch, limit = 0, 0., f32(max(duration - sum(actual), 0.))
    different = [i for i, (a, b) in enumerate(zip(actual, history)) if word(a) != word(b)]
    return dict(realized=actual, events=events, stopped=stopped, differentIndices=different,
                exact=len(actual) == len(history) and not different and stopped == 2)
