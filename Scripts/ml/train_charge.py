#!/usr/bin/env python3
"""Train the network that reads the charge back from marked damage (emmettl/bombcad-work#116).

    python train_charge.py --data DATASET --out OUT [--holdout made-mixed-s7] [--steps 20000]
        [--model surfaces|pooled] [--surfaces 2] [--bins 32]
        [--batch 512] [--lr 2e-3] [--phi 128,128] [--rho 256,256] [--grid 32] [--half-width 500]
        [--place-radius 500] [--max-marks 64] [--val-cases 2000] [--eval-every 1000]
        [--time-limit 40m] [--device auto] [--seed 1]

DATASET holds chance tables (*.bcct), each written by `blastmodel charge-from-damage table`: the
quick estimate's chances that each of a district's chosen buildings has its glass broken and its
walls damaged moderately or heavily (and, where the table has them, as 0.5 m masonry), for charges on
a grid of places about a reference point and at a ladder of yields (docs/charge-inference.md, "The
charge from marked damage, learned").

Every batch is drawn afresh from one table (the tables in turn), by the rules
`ChargeFromDamage.ChanceTable.drawCase` states in Swift (Sources/BlastModel/ChargeFromDamage+Table.swift),
so there is no fixed training set to overfit: a charge uniform over the disc of cells and in log
yield, 1-64 buildings chosen about a focus that knows nothing of the charge, what was seen of each
drawn from its chances (interpolated as the table interpolates them), and the eight turns and flips
of the square applied at random. Districts named by --holdout are never trained on, only judged.

Two set encoders (--model):

- `surfaces` (the default): each mark's 15 features through `phi` (dense layers, SiLU after each)
  and a linear head to, for each of --surfaces terms, an offset a and a slope b on every cell of a
  --grid square of half side --half-width m about the reference (cells beyond --place-radius left
  out); the term's log likelihood at a standardised log yield t is log sigmoid(a + b t), on --bins
  bins of the log yield. The marks' terms are summed (the marks are independent given the charge)
  and the posterior is the sum's softmax over the cells and bins.
- `pooled`: the marks' `phi` outputs' mean and maximum and ln(n + 1) / ln 65 through `rho`, whose
  last layer gives each cell's logit, and there the mean and the log standard deviation of the log
  yield.

The loss is the negative log of the posterior's density at the truth.

Writes OUT/best.pt (least loss on the trained districts' validation cases), OUT/checkpoint.pt,
OUT/history.jsonl, OUT/metrics.json (each district's coverage of its 50% and 90% place regions and
yield intervals, the median found over true yield, at the best epoch) and OUT/charge-net.bccd, the
weights in float16 for `ChargeFromDamage.Network`, with four cases' outputs for the Swift test.
"""
import argparse
import hashlib
import json
import math
import os
import struct
import sys
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

GLASS_MISREAD = 0.04
WALLS_MISREAD = 0.06
FEATURES = 15
STATIC = FEATURES - 4  # the features beside the place: x, y, r and ln r left out


def duration(text):
    units = {"s": 1, "m": 60, "h": 3600}
    return float(text[:-1]) * units[text[-1]] if text[-1] in units else float(text)


class Table:
    """A chance table on the device: its buildings and its chances."""

    def __init__(self, path, device):
        data = open(path, "rb").read()
        assert data[:8] == b"BCCT0001", path
        length = struct.unpack("<I", data[8:12])[0]
        self.header = h = json.loads(data[12:12 + length])
        start = (12 + length + 15) // 16 * 16
        self.name = h["district"]
        self.columns, self.rows = h["columns"], h["rows"]
        self.origin = h["origin"]
        self.spacing = h["spacingM"]
        self.yields = h["yieldsKg"]
        self.channels = len(h["channels"])
        self.masonry = self.channels >= 5
        b = h["buildings"]
        self.B = len(b)
        self.Y = len(self.yields)
        values = np.frombuffer(data[start:], dtype=np.uint8)
        assert values.size == h["nodeCount"] * self.Y * self.B * self.channels
        self.values = torch.from_numpy(values.copy()).to(device)
        f = lambda key: torch.tensor([x[key] for x in b], dtype=torch.float32, device=device)
        self.east, self.north = f("east"), f("north")
        self.height, self.footprint, self.built = f("heightM"), f("footprintM2"), f("builtShare")
        self.walls = torch.tensor([x["walls"] for x in b], dtype=torch.long, device=device)
        self.glazed = torch.tensor([bool(x["glazed"]) for x in b], dtype=torch.bool, device=device)
        # The buildings whose masonry channels were worked out (all, where the header names none).
        judged = torch.zeros(self.B, dtype=torch.bool, device=device)
        if self.masonry:
            if h.get("masonryBuildings") is None:
                judged[:] = True
            else:
                judged[torch.tensor(h["masonryBuildings"], dtype=torch.long, device=device)] = True
        self.judges_masonry = judged
        self.device = device

    def chance(self, building, channel, px, py, logmass):
        """Each (building, channel) chance at places (px, py) and ln mass, as Swift's `chance`."""
        x = (px - self.origin[0]) / self.spacing
        y = (py - self.origin[1]) / self.spacing
        i = torch.clamp(torch.floor(x), 0, self.columns - 2).long()
        j = torch.clamp(torch.floor(y), 0, self.rows - 2).long()
        s = torch.clamp(x - i, 0, 1)
        t = torch.clamp(y - j, 0, 1)
        low = math.log(self.yields[0])
        step = (math.log(self.yields[-1]) - low) / (self.Y - 1)
        q = torch.clamp((logmass - low) / step, 0, self.Y - 1)
        k = torch.clamp(q.long(), max=self.Y - 2)
        u = q - k
        total = torch.zeros_like(px)
        for di, dj, w in [(0, 0, (1 - s) * (1 - t)), (1, 0, s * (1 - t)), (0, 1, (1 - s) * t), (1, 1, s * t)]:
            node = (j + dj) * self.columns + (i + di)
            for dk, wk in [(0, 1 - u), (1, u)]:
                index = (((node * self.Y + k + dk) * self.B + building) * self.channels + channel)
                total = total + w * wk * self.values[index].float() / 255
        return total


def disc_cells(grid, half, radius, device):
    size = 2 * half / grid
    c = torch.arange(grid * grid, device=device)
    mx = -half + (c % grid + 0.5) * size
    my = -half + (c // grid + 0.5) * size
    return (mx * mx + my * my).sqrt() <= radius, mx, my


def draw_cases(table, n, gen, args, mark_count=None, augment=False):
    """`n` cases from `table` by `drawCase`'s rules: the marks' features [n, M, 15], their mask
    [n, M], the true cell and log mass, and the marks' (building, masonry, glass, walls) codes."""
    d = table.device
    G, half, R, M = args.grid, args.half_width, args.place_radius, args.max_marks
    size = 2 * half / G
    inside, mx, my = disc_cells(G, half, R, d)
    cells = torch.nonzero(inside).squeeze(1)
    U = lambda *shape: torch.rand(*shape, generator=gen, device=d)
    cell = cells[torch.clamp((U(n) * len(cells)).long(), max=len(cells) - 1)]
    px = mx[cell] + size * (U(n) - 0.5)
    py = my[cell] + size * (U(n) - 0.5)
    low, high = math.log(table.yields[0]), math.log(table.yields[-1])
    logmass = low + U(n) * (high - low)
    if mark_count is None:
        count = torch.clamp(torch.exp(U(n) * math.log(65.0)).long(), 1, M)
    else:
        count = torch.full((n,), mark_count, device=d, dtype=torch.long)
    count = torch.clamp(count, max=min(M, table.B))
    angle = 2 * math.pi * U(n)
    radius = 1000 * U(n).sqrt()
    fx, fy = radius * torch.cos(angle), radius * torch.sin(angle)
    length = torch.exp(math.log(100.0) + U(n) * (math.log(1500.0) - math.log(100.0)))
    dist = torch.sqrt((table.east[None] - fx[:, None]) ** 2 + (table.north[None] - fy[:, None]) ** 2)
    weight = torch.exp(-dist / length[:, None])
    keys = -torch.log(torch.clamp(U(n, table.B), min=1e-30)) / torch.clamp(weight, min=1e-300)
    keys = torch.where(weight > 0, keys, torch.full_like(keys, float("inf")))
    width = min(M, table.B)
    chosen = torch.topk(keys, width, dim=1, largest=False).indices  # [n, width], nearest first
    mask = torch.arange(width, device=d)[None] < count[:, None]
    b = chosen
    glazed = table.glazed[b]
    u = U(n, width)
    glass_seen = glazed & (u < 0.75)
    walls_seen = (~glazed) | (u < 0.45) | (u >= 0.75)
    kind = table.walls[b]
    if table.masonry:
        masonry = table.judges_masonry[b] & ((kind == 1) | ((kind == 0) & (U(n, width) < 0.3)))
    else:
        masonry = torch.zeros_like(glass_seen)
    P = lambda channel: table.chance(b, channel, px[:, None].expand_as(u), py[:, None].expand_as(u),
                                     logmass[:, None].expand_as(u))
    pg = P(0)
    moderate = torch.where(masonry, P(3), P(1)) if table.masonry else P(1)
    heavy = torch.where(masonry, P(4), P(2)) if table.masonry else P(2)
    q_whole = (1 - GLASS_MISREAD) * (1 - pg) + GLASS_MISREAD / 2
    broken = U(n, width) >= q_whole
    pm = moderate.clamp(0, 1)
    ph = torch.minimum(heavy.clamp(0, 1), pm)
    q_und = (1 - WALLS_MISREAD) * (1 - pm) + WALLS_MISREAD / 3
    q_dam = (1 - WALLS_MISREAD) * (pm - 0.5 * ph) + WALLS_MISREAD / 3
    v = U(n, width)
    walls_code = torch.where(v < q_und, 1, torch.where(v < q_und + q_dam, 2, 3))
    glass_code = torch.where(glass_seen, torch.where(broken, 2, 1), 0)
    walls_code = torch.where(walls_seen, walls_code, 0)
    kind_seen = torch.where(masonry, torch.ones_like(kind), kind)
    x = table.east[b] / 1000
    y = table.north[b] / 1000
    cx, cy = px, py
    if augment:
        turn = torch.randint(0, 8, (n,), generator=gen, device=d)
        swap = (turn & 4) > 0
        sx = torch.where((turn & 1) > 0, -1.0, 1.0)
        sy = torch.where((turn & 2) > 0, -1.0, 1.0)
        x, y = torch.where(swap[:, None], y, x), torch.where(swap[:, None], x, y)
        x, y = x * sx[:, None], y * sy[:, None]
        cx, cy = torch.where(swap, cy, cx), torch.where(swap, cx, cy)
        cx, cy = cx * sx, cy * sy
    features = marks_features(x, y, table.height[b], table.footprint[b], table.built[b], kind_seen, glass_code,
                              walls_code)
    i = torch.clamp(torch.floor((cx + half) / size), 0, G - 1).long()
    j = torch.clamp(torch.floor((cy + half) / size), 0, G - 1).long()
    label = j * G + i
    codes = {"building": b, "masonry": masonry, "glass": glass_code, "walls": walls_code}
    return features, mask, label, logmass, codes


def marks_features(x, y, height, footprint, built, kind, glass, walls):
    """As `ChargeFromDamage.Network.features`: x, y (km about the reference), r, ln(r + 0.025),
    ln(height / 10), ln(footprint / 200), built share, walls one hot (3), glass (whole, broken),
    walls seen (undamaged, damaged, heavy)."""
    r = torch.sqrt(x * x + y * y)
    parts = [x, y, r, torch.log(r + 0.025), torch.log(torch.clamp(height, min=1) / 10),
             torch.log(torch.clamp(footprint, min=4) / 200), built]
    parts += [(kind == k).float() for k in range(3)]
    parts += [(glass == k).float() for k in (1, 2)]
    parts += [(walls == k).float() for k in (1, 2, 3)]
    return torch.stack(parts, dim=-1)


class Network(nn.Module):
    def __init__(self, phi, rho, grid, inside, mid, scale):
        super().__init__()
        widths = [FEATURES] + phi
        self.phi = nn.ModuleList([nn.Linear(a, b) for a, b in zip(widths, widths[1:])])
        widths = [2 * phi[-1] + 1] + rho + [3 * grid * grid]
        self.rho = nn.ModuleList([nn.Linear(a, b) for a, b in zip(widths, widths[1:])])
        self.cells = grid * grid
        self.register_buffer("inside", inside)
        self.mid, self.scale = mid, scale

    def forward(self, features, mask):
        h = features
        for k, layer in enumerate(self.phi):
            h = layer(h)
            if k < len(self.phi) - 1:
                h = F.silu(h)
        m = mask[..., None].float()
        count = m.sum(1).clamp(min=1)
        mean = (h * m).sum(1) / count
        most = torch.where(mask[..., None], h, torch.full_like(h, -1e30)).max(1).values
        most = torch.where(count > 0, most, torch.zeros_like(most))
        g = torch.cat([mean, most, torch.log(mask.float().sum(1, keepdim=True) + 1) / math.log(65.0)], dim=1)
        for k, layer in enumerate(self.rho):
            g = layer(g)
            if k < len(self.rho) - 1:
                g = F.silu(g)
        c = self.cells
        logits = g[:, :c].masked_fill(~self.inside[None], float("-inf"))
        mu = self.mid + self.scale * g[:, c:2 * c]
        sigma = self.scale * torch.exp(torch.clamp(g[:, 2 * c:], -7, 3))
        return logits, mu, sigma

    def nll(self, features, mask, label, logmass):
        logits, mu, sigma = self(features, mask)
        place = F.cross_entropy(logits, label, reduction="none")
        m = mu.gather(1, label[:, None]).squeeze(1)
        s = sigma.gather(1, label[:, None]).squeeze(1)
        return place + 0.5 * ((logmass - m) / s) ** 2 + torch.log(s) + 0.5 * math.log(2 * math.pi), logits

    def marginals(self, features, mask, grid_y):
        logits, mu, sigma = self(features, mask)
        p = torch.softmax(logits, 1)
        density = torch.exp(-0.5 * ((grid_y[None, None] - mu[..., None]) / sigma[..., None]) ** 2)
        density = density / density.sum(-1, keepdim=True).clamp(min=1e-30)
        return p, (p[..., None] * density).sum(1)


class Distance(nn.Module):
    """Each mark's own likelihood as a function of its distance from the cell, summed over the
    marks: a network `hidden` wide of the mark's 11 features beside its place (its size, the share
    built round it, its walls and what was seen) and of the distance r (ln((r + 10 m) / 1 km) and
    r / 1 km) gives two offsets and slopes, and the likelihood at standardised log yield t is
    floor + (1 - floor) sigmoid(a1 + b1 t) sigmoid(a2 + b2 t). The network is evaluated at 96
    distances from 1 m to 8 km, evenly in ln r, and read linearly in ln r between them for each
    cell, as the app reads it; the posterior is the summed log likelihood's softmax over the disc's
    cells and the yield's bins. It knows each mark only by its distance from the charge, so it is
    the same at any place, in any district, about any reference."""

    NODES = 96
    LOW, HIGH = 1.0, 8000.0

    def __init__(self, hidden, grid, inside, low, high, bins, half, floor=0.02):
        super().__init__()
        widths = [STATIC + 2] + hidden + [4]
        self.mlp = nn.ModuleList([nn.Linear(a, b) for a, b in zip(widths, widths[1:])])
        self.cells, self.bins, self.low, self.high = grid * grid, bins, low, high
        self.width = (high - low) / bins
        self.floor = floor
        size = 2 * half / grid
        c = torch.arange(grid * grid)
        self.register_buffer("mx", -half + (c % grid + 0.5) * size)
        self.register_buffer("my", -half + (c // grid + 0.5) * size)
        self.register_buffer("inside", inside)
        self.register_buffer("t", torch.linspace(-1 + 1 / bins, 1 - 1 / bins, bins))
        r = torch.exp(torch.linspace(math.log(self.LOW), math.log(self.HIGH), self.NODES))
        self.register_buffer("rnodes", torch.stack([torch.log((r + 10) / 1000), r / 1000], 1))

    def table(self, static):
        n, M, _ = static.shape
        x = torch.cat([static[:, :, None, :].expand(n, M, self.NODES, STATIC),
                       self.rnodes[None, None].expand(n, M, self.NODES, 2)], -1)
        for k, layer in enumerate(self.mlp):
            x = layer(x)
            if k < len(self.mlp) - 1:
                x = F.silu(x)
        return x  # n, M, nodes, 4

    def forward(self, features, mask):
        n, M, _ = features.shape
        tab = self.table(features[..., 4:])
        ex, ny = features[..., 0] * 1000, features[..., 1] * 1000
        r = torch.sqrt((ex[..., None] - self.mx) ** 2 + (ny[..., None] - self.my) ** 2)  # n, M, cells
        step = (math.log(self.HIGH) - math.log(self.LOW)) / (self.NODES - 1)
        q = torch.clamp((torch.log(torch.clamp(r, min=self.LOW)) - math.log(self.LOW)) / step, 0, self.NODES - 1)
        i = torch.clamp(q.long(), max=self.NODES - 2)
        f = (q - i)[..., None]
        index = i[..., None].expand(n, M, self.cells, 4)
        lower = tab.gather(2, index)
        upper = tab.gather(2, index + 1)
        abc = lower + f * (upper - lower)  # n, M, cells, 4
        t = self.t
        s1 = torch.sigmoid(abc[..., 0:1] + abc[..., 1:2] * t)
        s2 = torch.sigmoid(abc[..., 2:3] + abc[..., 3:4] * t)
        ll = torch.log(self.floor + (1 - self.floor) * s1 * s2)  # n, M, cells, bins
        joint = (ll * mask[:, :, None, None].float()).sum(1)
        return joint.masked_fill(~self.inside[None, :, None], float("-inf"))

    nll = None
    marginals = None


class Surfaces(nn.Module):
    """Each mark's own log likelihood over the cells and the yield, summed over the marks: through
    `phi` (SiLU after every layer) and a linear head, for each of `surfaces` terms a map over the
    cells of an offset a and a slope b, the term's log likelihood at standardised log yield t being
    log sigmoid(a + b t). The posterior is the sum's softmax over the disc's cells and the yield's
    `bins` (the prior uniform in both), so any number of marks is weighed alike, as independent
    evidence given the charge."""

    def __init__(self, phi, grid, inside, low, high, bins, surfaces):
        super().__init__()
        widths = [FEATURES] + phi
        self.phi = nn.ModuleList([nn.Linear(a, b) for a, b in zip(widths, widths[1:])])
        self.head = nn.Linear(phi[-1], 2 * surfaces * grid * grid)
        self.cells, self.surfaces, self.bins = grid * grid, surfaces, bins
        self.low, self.high = low, high
        self.width = (high - low) / bins
        self.register_buffer("inside", inside)
        self.register_buffer("t", torch.linspace(-1 + 1 / bins, 1 - 1 / bins, bins))

    def forward(self, features, mask):
        n, M, _ = features.shape
        h = features
        for layer in self.phi:
            h = F.silu(layer(h))
        out = self.head(h).view(n, M, self.surfaces, 2, self.cells)
        a, b = out[:, :, :, 0], out[:, :, :, 1]
        terms = F.logsigmoid(a[..., None] + b[..., None] * self.t)  # n, M, S, cells, bins
        joint = (terms.sum(2) * mask[:, :, None, None].float()).sum(1)  # n, cells, bins
        return joint.masked_fill(~self.inside[None, :, None], float("-inf"))

    def nll(self, features, mask, label, logmass):
        joint = self(features, mask)
        logp = joint.flatten(1) - torch.logsumexp(joint.flatten(1), 1, keepdim=True)
        k = torch.clamp(((logmass - self.low) / self.width).long(), 0, self.bins - 1)
        return -logp.gather(1, (label * self.bins + k)[:, None]).squeeze(1) + math.log(self.width), joint

    def marginals(self, features, mask, grid_y):
        """The cells' probabilities and the yield's marginal on `grid_y`, its density flat in each bin."""
        joint = self(features, mask)
        p = torch.softmax(joint.flatten(1), 1).view_as(joint)
        cells = p.sum(2)
        bins = p.sum(1)
        k = torch.clamp(((grid_y - self.low) / self.width).long(), 0, self.bins - 1)
        marginal = bins[:, k]
        return cells, marginal / marginal.sum(1, keepdim=True).clamp(min=1e-30)


Distance.nll = Surfaces.nll
Distance.marginals = Surfaces.marginals


@torch.no_grad()
def judge(model, sets, args):
    """Each district's held-out cases: the loss, the truth in the 50% and 90% place regions and
    yield intervals, and the median found (the yield's median) over true."""
    out = {}
    low, high = math.log(args.yield_range[0]), math.log(args.yield_range[1])
    grid_y = None
    for name, (features, mask, label, logmass, _) in sets.items():
        losses, in50, in90, y50, y90, ratios, radius90 = [], [], [], [], [], [], []
        for start in range(0, len(label), 250):
            sl = slice(start, start + 250)
            loss, _ = model.nll(features[sl], mask[sl], label[sl], logmass[sl])
            losses.append(loss)
            if grid_y is None:
                grid_y = torch.linspace(low, high, 241, device=label.device)
            p, marginal = model.marginals(features[sl], mask[sl], grid_y)
            order = torch.argsort(p, 1, descending=True)
            cumulative = p.gather(1, order).cumsum(1)
            rank = torch.argsort(order, 1).gather(1, label[sl][:, None]).squeeze(1)
            before = torch.where(rank > 0, cumulative.gather(1, (rank - 1).clamp(min=0)[:, None]).squeeze(1),
                                 torch.zeros_like(rank, dtype=p.dtype))
            in50.append(before < 0.5)
            in90.append(before < 0.9)
            radius90.append(((cumulative < 0.9).sum(1) + 1).float())
            cdf = marginal.cumsum(1)
            at = torch.searchsorted(grid_y, logmass[sl].contiguous()).clamp(max=240)
            u = cdf.gather(1, at[:, None]).squeeze(1)
            y50.append((u >= 0.25) & (u <= 0.75))
            y90.append((u >= 0.05) & (u <= 0.95))
            median = grid_y[torch.searchsorted(cdf, torch.full_like(u[:, None], 0.5)).clamp(max=240).squeeze(1)]
            ratios.append(torch.exp(median - logmass[sl]))
        cat = lambda v: torch.cat(v).float()
        cell = 2 * args.half_width / args.grid
        out[name] = {
            "loss": cat(losses).mean().item(), "placeIn50": cat(in50).mean().item(), "placeIn90": cat(in90).mean().item(),
            "yieldIn50": cat(y50).mean().item(), "yieldIn90": cat(y90).mean().item(),
            "medianYieldRatio": cat(ratios).median().item(),
            "medianPlaceRadius90M": (cat(radius90) * cell * cell / math.pi).sqrt().median().item(),
        }
    return out


def export(model, path, args, tables, trained, references, source):
    """The weights in float16 after a JSON header, as `ChargeFromDamage.Network` reads them."""
    tensors, blobs, offset = [], [], 0
    if args.model == "distance":
        groups = [("mlp", model.mlp)]
    else:
        groups = [("phi", model.phi)] + ([("rho", model.rho)] if args.model == "pooled" else [("head", [model.head])])
    for prefix, layers in groups:
        for k, layer in enumerate(layers):
            for kind in ("weight", "bias"):
                value = getattr(layer, kind).detach().float().cpu().numpy().astype(np.float16)
                tensors.append({"name": "%s.%d.%s" % (prefix, k, kind), "shape": list(value.shape), "offset": offset})
                blobs.append(value.ravel())
                offset += value.size
    header = {
        "format": "BCCD0001", "name": args.name, "kind": args.model, "inputs": FEATURES, "phi": args.phi,
        "rho": args.rho if args.model == "pooled" else [], "grid": args.grid, "halfWidthM": args.half_width,
        "placeRadiusM": args.place_radius, "yieldRangeKg": list(args.yield_range),
        "logYieldMid": 0.5 * (math.log(args.yield_range[0]) + math.log(args.yield_range[1])),
        "logYieldScale": 0.5 * (math.log(args.yield_range[1]) - math.log(args.yield_range[0])),
        "maxMarks": args.max_marks if args.model == "pooled" else 100000, "surfaces": args.surfaces,
        "distanceNodes": Distance.NODES, "distanceRangeM": [Distance.LOW, Distance.HIGH], "floor": 0.02,
        "yieldBins": args.bins, "trainedOn": trained, "source": source, "tensors": tensors, "references": references,
    }
    body = json.dumps(header).encode()
    with open(path, "wb") as f:
        f.write(b"BCCD0001")
        f.write(struct.pack("<I", len(body)))
        f.write(body)
        f.write(b"\0" * ((12 + len(body) + 7) // 8 * 8 - 12 - len(body)))
        f.write(np.concatenate(blobs).astype("<f2").tobytes())


def build(args, inside, device):
    low, high = math.log(args.yield_range[0]), math.log(args.yield_range[1])
    if args.model == "surfaces":
        return Surfaces(args.phi, args.grid, inside, low, high, args.bins, args.surfaces).to(device)
    if args.model == "distance":
        return Distance(args.phi, args.grid, inside, low, high, args.bins, args.half_width).to(device)
    return Network(args.phi, args.rho, args.grid, inside, 0.5 * (low + high), 0.5 * (high - low)).to(device)


def reference_cases(model, table, args, device):
    """Four cases' marks (as Swift's `Mark` decodes them) and the float16 network's outputs: for the
    pooled model its logits, log-yield means and log standard deviations; for the surfaces, the
    joint log likelihood over cells and bins (in `logits`, cell by cell, bin by bin)."""
    gen = torch.Generator(device=device)
    gen.manual_seed(4242)
    features, mask, _, _, codes = draw_cases(table, 4, gen, args, mark_count=12)
    half = build(args, model.inside, device)
    half.load_state_dict(model.state_dict())
    for p in half.parameters():
        p.data = p.data.half().float()
    refs = []
    with torch.no_grad():
        outputs = half(features, mask)
    for n in range(4):
        marks = []
        for k in range(int(mask[n].sum())):
            b = int(codes["building"][n, k])
            x = table.header["buildings"][b]
            mark = {"building": {"east": x["east"], "north": x["north"], "heightM": x["heightM"],
                                 "footprintM2": x["footprintM2"], "builtShare": x["builtShare"],
                                 "walls": 1 if bool(codes["masonry"][n, k]) else x["walls"], "glazed": x["glazed"]}}
            if int(codes["glass"][n, k]):
                mark["glass"] = int(codes["glass"][n, k])
            if int(codes["walls"][n, k]):
                mark["walls"] = int(codes["walls"][n, k])
            marks.append(mark)
        finite = lambda v: [float(x) if math.isfinite(x) else 0.0 for x in v]
        if args.model in ("surfaces", "distance"):
            # 64 of the disc's cells, evenly, each with all its bins.
            cells = torch.nonzero(model.inside).squeeze(1)
            cells = cells[torch.linspace(0, len(cells) - 1, 64).long()]
            refs.append({"marks": marks, "cells": [int(c) for c in cells],
                         "logits": finite(outputs[n][cells].flatten().cpu().double().numpy()),
                         "mu": [], "logSigma": []})
        else:
            logits, mu, sigma = outputs
            refs.append({"marks": marks, "logits": finite(logits[n].cpu().double().numpy()),
                         "mu": [float(v) for v in mu[n].cpu().double().numpy()],
                         "logSigma": [float(math.log(v)) for v in sigma[n].cpu().double().numpy()]})
    return refs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--holdout", default="made-mixed-s7")
    ap.add_argument("--steps", type=int, default=20000)
    ap.add_argument("--batch", type=int, default=512)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--phi", default="128,128")
    ap.add_argument("--rho", default="256,256")
    ap.add_argument("--grid", type=int, default=32)
    ap.add_argument("--half-width", type=float, default=500)
    ap.add_argument("--place-radius", type=float, default=500)
    ap.add_argument("--max-marks", type=int, default=64)
    ap.add_argument("--val-cases", type=int, default=2000)
    ap.add_argument("--eval-every", type=int, default=1000)
    ap.add_argument("--time-limit", default="40m")
    ap.add_argument("--device", default="auto")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--name", default="charge-net-1")
    ap.add_argument("--model", choices=["pooled", "surfaces", "distance"], default="distance")
    ap.add_argument("--surfaces", type=int, default=2)
    ap.add_argument("--bins", type=int, default=32)
    args = ap.parse_args()
    args.phi = [int(v) for v in args.phi.split(",")]
    args.rho = [int(v) for v in args.rho.split(",")]
    device = ("cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu") \
        if args.device == "auto" else args.device
    os.makedirs(args.out, exist_ok=True)
    started = time.time()
    limit = duration(args.time_limit)
    torch.manual_seed(args.seed)
    paths = sorted(os.path.join(args.data, f) for f in os.listdir(args.data) if f.endswith(".bcct"))
    tables = [Table(p, device) for p in paths]
    held = set(args.holdout.split(",")) if args.holdout else set()
    trained = [t for t in tables if t.name not in held]
    print("device %s%s; tables: %s" % (device, " (%s)" % torch.cuda.get_device_name() if device == "cuda" else "",
                                        ", ".join("%s (%d buildings%s%s)" % (t.name, t.B, ", masonry" if t.masonry else "",
                                                                             ", held out" if t.name in held else "")
                                                  for t in tables)), flush=True)
    ladders = {(t.yields[0], t.yields[-1]) for t in tables}
    assert len(ladders) == 1, "every table on the same yields"
    args.yield_range = ladders.pop()
    inside, _, _ = disc_cells(args.grid, args.half_width, args.place_radius, device)
    model = build(args, inside, device)
    print("parameters: %d" % sum(p.numel() for p in model.parameters()), flush=True)
    gen = torch.Generator(device=device)
    gen.manual_seed(1000 + args.seed)
    vgen = torch.Generator(device=device)
    vgen.manual_seed(9_000_001)
    val = {t.name: draw_cases(t, args.val_cases, vgen, args) for t in tables}
    optimiser = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    schedule = torch.optim.lr_scheduler.OneCycleLR(optimiser, max_lr=args.lr, total_steps=args.steps, pct_start=0.05)
    history = open(os.path.join(args.out, "history.jsonl"), "w")
    best, best_metrics, running = float("inf"), None, []
    step = 0
    for step in range(1, args.steps + 1):
        table = trained[step % len(trained)]
        features, mask, label, logmass, _ = draw_cases(table, args.batch, gen, args, augment=True)
        loss, _ = model.nll(features, mask, label, logmass)
        loss = loss.mean()
        optimiser.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 5.0)
        optimiser.step()
        schedule.step()
        running.append(loss.item())
        out_of_time = time.time() - started > limit
        if step % args.eval_every == 0 or step == args.steps or out_of_time:
            model.eval()
            metrics = judge(model, val, args)
            model.train()
            score = float(np.mean([metrics[t.name]["loss"] for t in trained]))
            record = {"step": step, "seconds": round(time.time() - started, 1), "train": float(np.mean(running)),
                      "validation": score, "districts": metrics}
            history.write(json.dumps(record) + "\n")
            history.flush()
            print("step %6d  %6.0f s  train %.3f  validation %.3f  " % (step, record["seconds"], record["train"], score)
                  + "  ".join("%s: place %.2f/%.2f yield %.2f/%.2f ratio %.2f" % (
                      n, m["placeIn50"], m["placeIn90"], m["yieldIn50"], m["yieldIn90"], m["medianYieldRatio"])
                      for n, m in metrics.items()), flush=True)
            running = []
            torch.save({"model": model.state_dict(), "step": step, "args": vars(args)},
                       os.path.join(args.out, "checkpoint.pt"))
            if score < best:
                best, best_metrics = score, record
                torch.save({"model": model.state_dict(), "step": step, "args": vars(args)},
                           os.path.join(args.out, "best.pt"))
        if out_of_time:
            print("stopped at the time limit", flush=True)
            break
    state = torch.load(os.path.join(args.out, "best.pt"), map_location=device)
    model.load_state_dict(state["model"])
    model.eval()
    source = hashlib.sha256(open(os.path.join(args.out, "best.pt"), "rb").read()).hexdigest()
    references = reference_cases(model, trained[0], args, device)
    export(model, os.path.join(args.out, "charge-net.bccd"), args, tables, [t.name for t in trained], references,
           "best.pt step %d, sha256 %s" % (state["step"], source))
    json.dump({"best": best_metrics, "steps": step, "seconds": round(time.time() - started, 1),
               "device": device, "gpu": torch.cuda.get_device_name() if device == "cuda" else None,
               "trainedOn": [t.name for t in trained], "heldOut": sorted(held)},
              open(os.path.join(args.out, "metrics.json"), "w"), indent=1)
    print("best at step %d (validation %.3f); wrote charge-net.bccd in %.0f s" % (state["step"], best,
                                                                                  time.time() - started), flush=True)


if __name__ == "__main__":
    main()
