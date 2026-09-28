#!/usr/bin/env python3
"""Procedural Paintbot maps.

Every map is written in the engine's own terms (examples/paintbot/sim.nim, topography.nim,
mechanics.nim under rules 40): centimetre heights over the rules-22 span
[-4800, 11200] x [-2800, 6800], an island margin that blocks cogs below Radius div 3 + 40,
shallow water below RiverWaterHeight (-162) that quarters walking speed, round cover
(Cover.h == 0, w = diameter), 280 x 280 trenches, and the rules-40 item set: 2 home + 8
neutral control hearts in mirrored pairs, 4 grenades, 2 sprays, 2 armors, 4 medkits,
2 uniforms. Maps are exact under the rules-35 half turn about (3200, 2000).

    python3 mapgen.py --out maps            # the ten catalogue maps
    python3 mapgen.py --out maps --only crater --seed 7
"""
from __future__ import annotations

import argparse
import base64
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from scipy import ndimage
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import dijkstra

# ---- engine constants ------------------------------------------------------------------
MIN_X, MIN_Z, MAX_X, MAX_Z = -4800, -2800, 11200, 6800
CX, CZ = 3200, 2000  # half-turn centre: mirror(x, z) = (6400 - x, 4000 - z)
STEP = 50
NX = (MAX_X - MIN_X) // STEP + 1  # 321
NZ = (MAX_Z - MIN_Z) // STEP + 1  # 193
RADIUS = 55  # cog radius
MARGIN_BLOCK = RADIUS // 3 + 40  # islandMargin below this is off the island
WATER = -162  # RiverWaterHeight
BED = -200  # RiverBedHeight
HIGH = 216  # HighGroundHeight
CLIFF = 25 / 20  # traversable(): > 25 cm per 20 cm sample is a wall
TRENCH = 280

XS = MIN_X + STEP * np.arange(NX)
ZS = MIN_Z + STEP * np.arange(NZ)
X, Z = np.meshgrid(XS.astype(float), ZS.astype(float))


def mirror(p):
    return (2 * CX - p[0], 2 * CZ - p[1])


def rot(a):
    return a[::-1, ::-1]


def sym(a):
    return 0.5 * (a + rot(a))


def cell(p):
    return (int(round((p[1] - MIN_Z) / STEP)), int(round((p[0] - MIN_X) / STEP)))


def first_half(p):
    """One representative of each mirrored pair (the half turn swaps the halves)."""
    return p[1] < CZ or (p[1] == CZ and p[0] < CX)


# ---- terrain primitives (all return full-grid arrays) ----------------------------------
def fbm(rng, octaves=4, base=6, persistence=0.5):
    out = np.zeros((NZ, NX))
    amp, total = 1.0, 0.0
    for o in range(octaves):
        n = base * 2**o
        coarse = rng.standard_normal((max(2, int(n * NZ / NX)) + 1, n + 1))
        out += amp * ndimage.zoom(coarse, (NZ / coarse.shape[0], NX / coarse.shape[1]), order=3)[:NZ, :NX]
        total += amp
        amp *= persistence
    out /= total
    return sym(out) / (out.std() + 1e-9)


def superellipse(cx, cz, ax, az, p=4.0):
    return (np.abs(X - cx) / ax) ** p + (np.abs(Z - cz) / az) ** p


def bump(cx, cz, r, h):
    d = np.hypot(X - cx, Z - cz) / r
    return np.where(d < 1, h * 0.5 * (1 + np.cos(np.pi * np.minimum(d, 1))), 0.0)


def dome(cx, cz, r, h, core=0.45):
    """A hill with a flat crown (usable ground on top) and a smooth cosine skirt."""
    d = np.clip((np.hypot(X - cx, Z - cz) / r - core) / (1 - core), 0, 1)
    return h * 0.5 * (1 + np.cos(np.pi * d))


def seg_dist(ax, az, bx, bz):
    vx, vz = bx - ax, bz - az
    t = np.clip(((X - ax) * vx + (Z - az) * vz) / max(vx * vx + vz * vz, 1e-9), 0, 1)
    return np.hypot(X - ax - t * vx, Z - az - t * vz)


def poly_dist(points):
    d = np.full((NZ, NX), np.inf)
    for a, b in zip(points, points[1:]):
        d = np.minimum(d, seg_dist(a[0], a[1], b[0], b[1]))
    return d


def plateau(cx, cz, rx, rz, h, ramps, ramp_len=None, ramp_w=380, p=3.0):
    """Flat-topped mesa with cliff sides and walkable ramps (angle in degrees)."""
    ramp_len = ramp_len or max(420, int(h / 0.6))
    s = superellipse(cx, cz, rx, rz, p)
    out = np.where(s <= 1, float(h), 0.0)
    for ang in ramps:
        dx, dz = math.cos(math.radians(ang)), math.sin(math.radians(ang))
        # edge point along the ray
        t = 1 / (((abs(dx) / rx) ** p + (abs(dz) / rz) ** p) ** (1 / p))
        ex, ez = cx + dx * t, cz + dz * t
        along = (X - ex) * dx + (Z - ez) * dz
        across = np.abs(-(X - ex) * dz + (Z - ez) * dx)
        ramp = np.where((along >= -60) & (along <= ramp_len) & (across <= ramp_w / 2),
                        h * (1 - np.clip(along, 0, ramp_len) / ramp_len), 0.0)
        out = np.maximum(out, ramp)
    return out


def carve(h, d, bank, bed=BED):
    """Lower h toward bed within `bank` of a channel; smoothstep banks stay walkable."""
    t = np.clip(d / bank, 0, 1)
    return np.minimum(h, bed + (h - bed) * t * t * (3 - 2 * t))


def mirrored(fn, *args, **kw):
    """A feature and its half-turn image; ramps rotate by 180 degrees."""
    a = fn(*args, **kw)
    return np.maximum(a, rot(a))


# ---- the map --------------------------------------------------------------------------
@dataclass
class Cover:
    x: float
    z: float
    r: float
    kind: str  # tree | house | prop | rock


@dataclass
class Map:
    name: str
    title: str
    archetype: str
    blurb: str
    seed: int
    height: np.ndarray = None
    land: np.ndarray = None  # coast potential; islandMargin = land * 1000
    home: tuple = (1000, 2000)
    cover: list = field(default_factory=list)
    hearts: list = field(default_factory=list)  # (x, z, owner, role)
    pickups: list = field(default_factory=list)  # (x, z, kind, role)
    trenches: list = field(default_factory=list)  # (x, z) centres
    forest: np.ndarray = None  # 0..1 tree density field
    village: list = field(default_factory=list)  # village centres (first half)
    rocks: float = 0.0
    lanes: list = field(default_factory=list)


def island(rng, ax=6200, az=3700, wobble=0.06, p=4.0):
    return 1 - superellipse(CX, CZ, ax, az, p) ** (1 / p) + wobble * fbm(rng, 3, 3)


def finish_terrain(m: Map, h, land):
    """Coast clamp from topography.nim: height <= (margin - 35) * 5."""
    margin = land * 1000
    h = np.minimum(h, (margin - 35) * 5)
    h = np.maximum(h, -600)
    m.height = np.rint(sym(h)).astype(np.int16)
    m.land = sym(land)


# ---- archetypes -----------------------------------------------------------------------
def a_mesas(m, rng):
    land = island(rng, 6000, 3500)
    h = 40 * fbm(rng, 4, 5)
    h = np.maximum(h, mirrored(plateau, 2300, 900, 900, 650, 250, [100, 200, 330]))
    h = np.maximum(h, mirrored(plateau, 4400, 1500, 500, 420, 250, [180, 20]))
    lake = superellipse(CX, CZ, 700, 450, 2) ** 0.5
    h = np.minimum(h, np.where(lake < 1, BED + (lake ** 3) * 260, 1e9))
    m.forest = np.clip(fbm(rng, 3, 4) - 0.2, 0, 1) * (np.abs(X - CX) > 1400)
    m.village = [(900, 3300)]
    m.home = (700, 2000)
    finish_terrain(m, h, land)


def a_archipelago(m, rng):
    blobs = [(900, 2000, 1900, 1500), (CX, CZ, 1100, 1500), (2400, -700, 1300, 950), (-2300, 3900, 1200, 1000)]
    land = np.full((NZ, NX), -1.0)
    for bx, bz, rx, rz in blobs:
        for q in [(bx, bz), mirror((bx, bz))]:
            land = np.maximum(land, 1 - superellipse(q[0], q[1], rx, rz, 2.4) ** (1 / 2.4))
    land += 0.07 * fbm(rng, 3, 5)
    h = 60 + 25 * fbm(rng, 3, 4)
    for bx, bz, rx, rz in blobs:
        h = np.maximum(h, mirrored(dome, bx, bz, 1.1 * min(rx, rz), 160))
    # Wading sandbars between islands: dry land potential, water-deep heights that
    # shelve gently up onto each island's beach.
    bars = [((900, 2000), (CX, CZ)), ((900, 2000), (2400, -700)), ((2400, -700), (CX, CZ)),
            ((900, 2000), (-2300, 3900)), ((2400, -700), mirror((-2300, 3900)))]
    island_land = land.copy()
    for a, b in bars:
        for aa, bb in [(a, b), (mirror(a), mirror(b))]:
            d = seg_dist(aa[0], aa[1], bb[0], bb[1])
            land = np.maximum(land, np.where(d < 260, 0.16, -1))
            shelf = -185 + 1400 * np.clip(island_land, 0, 1)
            h = np.where(d < 260, np.minimum(h, shelf), h)
    m.forest = np.clip(fbm(rng, 3, 5) + 0.4, 0, 1)
    m.home = (800, 2000)
    finish_terrain(m, h, land)


def a_river(m, rng):
    land = island(rng, 6400, 3800)
    h = 70 + 55 * fbm(rng, 4, 5)
    # An S-shaped river through the centre: odd under the half turn by construction.
    pts = []
    for t in np.linspace(-1, 1, 60):
        z = CZ + t * 5200
        x = CX + 1100 * math.sin(t * math.pi * 1.5) + 180 * math.sin(t * 9.1)
        pts.append((x, z))
    d = poly_dist(pts)
    bank = 700
    h = carve(h, d, bank)
    # Fords: dry gravel crossings.
    for fz in [CZ - 1500, CZ, CZ + 1500]:
        i = int(np.argmin([abs(p[1] - fz) for p in pts]))
        fx = pts[i][0]
        dd = np.hypot(X - fx, Z - fz)
        h = np.where(d < bank + 80, np.maximum(h, -100 - 100 * np.clip((dd - 260) / 140, 0, 1.5)), h)
    m.forest = np.clip(1.6 - d / 1100, 0, 1) * 0.8 + np.clip(fbm(rng, 3, 4) - 0.2, 0, 1)
    m.village = [(1300, 800)]
    m.home = (500, 2000)
    finish_terrain(m, h, land)


def a_crater(m, rng):
    land = island(rng, 6200, 3600, p=3.0)
    h = 30 * fbm(rng, 4, 5)
    r = np.hypot((X - CX) / 1.25, Z - CZ)
    ang = np.degrees(np.arctan2(Z - CZ, X - CX)) % 360
    near = lambda g, w: np.abs((ang - g + 180) % 360 - 180) < w
    rim = (r > 1150) & (r < 1650)
    for g in [0, 70, 180, 250]:  # breaches at ground level
        rim &= ~near(g, 9)
    h = np.maximum(h, np.where(rim, 260.0, 0.0))
    for g in [40, 220, 125, 305]:  # ramps up the outer and inner faces
        h = np.maximum(h, np.where(near(g, 8) & (r >= 1600) & (r < 2150), 260 * (2150 - r) / 550, 0))
        h = np.maximum(h, np.where(near(g, 8) & (r > 600) & (r <= 1200), 260 * (r - 600) / 600, 0))
    pond = np.hypot((X - CX) / 1.3, Z - CZ)
    h = np.where(pond < 520, np.minimum(h, BED + (pond / 520) ** 2 * 230), h)
    m.forest = np.clip(fbm(rng, 3, 4), 0, 1) * (r > 2100)
    m.rocks = 0.4
    m.home = (700, 2000)
    finish_terrain(m, h, land)


def a_terraces(m, rng):
    land = island(rng, 6000, 3600)
    h = 25 * fbm(rng, 4, 6)
    for lvl, (rx, rz) in enumerate([(2600, 1800), (1700, 1200), (850, 650)]):
        ramps = [30 + 120 * lvl, 150 + 120 * lvl]
        top = 120 * (lvl + 1)
        a = plateau(CX, CZ, rx, rz, top, [], p=2.4)
        # Ramps from the level below.
        for ang in ramps + [g + 180 for g in ramps]:
            dx, dz = math.cos(math.radians(ang)), math.sin(math.radians(ang))
            t = 1 / (((abs(dx) / rx) ** 2.4 + (abs(dz) / rz) ** 2.4) ** (1 / 2.4))
            ex, ez = CX + dx * t, CZ + dz * t
            along = (X - ex) * dx + (Z - ez) * dz
            across = np.abs(-(X - ex) * dz + (Z - ez) * dx)
            a = np.maximum(a, np.where((along >= -60) & (along <= 260) & (across <= 210),
                                       120 * lvl + 120 * (1 - np.clip(along, 0, 260) / 260), 0))
        h = np.maximum(h, a)
    m.forest = np.clip(fbm(rng, 3, 5) - 0.3, 0, 1) * 0.6
    m.rocks = 0.25
    m.home = (600, 2000)
    finish_terrain(m, h, land)


def a_forest(m, rng):
    land = island(rng, 6600, 3900, wobble=0.09)
    h = 110 * fbm(rng, 4, 4)
    m.forest = np.clip(0.9 + 0.5 * fbm(rng, 3, 6), 0, 1)
    brook = poly_dist([(CX - 3000, CZ + 2600), (CX - 900, CZ + 500), (CX + 900, CZ - 500), (CX + 3000, CZ - 2600)])
    h = carve(h, brook, 520)
    m.home = (800, 2000)
    m.village = [(2200, 3000)]
    finish_terrain(m, h, land)


def a_badlands(m, rng):
    land = island(rng, 6200, 3700, wobble=0.1, p=3)
    h = 40 * fbm(rng, 4, 5)
    walls = [((1500, 700), (2700, 1300)), ((2000, 2700), (3000, 3300)), ((3900, 300), (4600, 1100)),
             ((600, 3300), (1500, 3900)), ((-400, 800), (600, 400)), ((3400, 1600), (3400, 1000)),
             ((5200, -600), (6400, -200))]
    for a, b in walls:
        for aa, bb in [(a, b), (mirror(a), mirror(b))]:
            d = seg_dist(aa[0], aa[1], bb[0], bb[1])
            h = np.maximum(h, np.where(d < 160, 340.0, 0.0))
    # A few mesas with ramps for high ground over the corridors.
    h = np.maximum(h, mirrored(plateau, 2500, 2000 - 1100, 420, 300, 250, [270]))
    m.rocks = 1.0
    m.forest = np.clip(fbm(rng, 3, 5) - 0.9, 0, 1) * 0.3
    m.home = (500, 2000)
    finish_terrain(m, h, land)


def a_atoll(m, rng):
    r = superellipse(CX, CZ, 6000, 3600, 2.6) ** (1 / 2.6)
    land = np.minimum(1 - r, r - 0.42) + 0.05 * fbm(rng, 3, 5)
    h = 60 + 30 * fbm(rng, 3, 5)
    h = np.maximum(h, mirrored(dome, 3200, -900, 900, 200))
    # The lagoon is shallow: a slow wading shortcut across the middle.
    lagoon = r < 0.5
    land = np.where(lagoon, np.maximum(land, 0.2), land)
    h = np.where(lagoon, -190 + 15 * fbm(rng, 3, 7), h)
    h = np.where((r >= 0.5) & (r < 0.56), np.minimum(h, -190 + (r - 0.5) / 0.06 * 250), h)
    # Central sand spit with the prize heart.
    spit = np.hypot((X - CX) / 1.5, Z - CZ)
    h = np.where(spit < 420, np.maximum(h, 30 - 180 * np.clip((spit - 250) / 170, 0, 1) ** 2), h)
    m.forest = np.clip(fbm(rng, 3, 5), 0, 1) * (~lagoon)
    m.home = (-1300, 2000)
    finish_terrain(m, h, land)


def a_highlands(m, rng):
    land = island(rng, 6400, 3800)
    h = 40 + 90 * fbm(rng, 3, 2) + 25 * fbm(rng, 3, 5)
    for c in [(1900, 700, 1300, 260), (-800, 3500, 1500, 300), (4200, 2800, 1100, 220), (2600, -1600, 1400, 280)]:
        h = h + mirrored(dome, *c)
    m.forest = np.clip(fbm(rng, 3, 4) - 0.1, 0, 1) * 0.7
    m.village = [(-600, 900)]
    m.home = (100, 2000)
    finish_terrain(m, h, land)


def a_delta(m, rng):
    land = island(rng, 6400, 3700, wobble=0.08)
    h = 60 + 40 * fbm(rng, 4, 5)
    for base in [-500, 1200]:
        pts = [(base + 260 * math.sin(z / 900), z) for z in np.linspace(-3200, 7200, 70)]
        for pp in [pts, [mirror(p) for p in pts]]:
            d = poly_dist(pp)
            h = carve(h, d, 560)
            for fz in [300, 2000, 3700]:
                fx = min(pp, key=lambda p: abs(p[1] - fz))[0]
                dd = np.hypot(X - fx, Z - fz)
                h = np.where(d < 620, np.maximum(h, -90 - 110 * np.clip((dd - 240) / 140, 0, 1.5)), h)
    marsh = np.clip(fbm(rng, 3, 6) - 0.4, 0, 1)
    m.forest = marsh * 0.8
    m.village = [(2600, 700)]
    m.home = (-1800, 2000)
    finish_terrain(m, h, land)


CATALOGUE = [
    ("twin-mesas", "Twin Mesas", a_mesas, "Two ramped mesas overlook a central pond; high ground is the prize."),
    ("archipelago", "Archipelago", a_archipelago, "Five islands joined by slow wading sandbars."),
    ("serpent-river", "Serpent River", a_river, "An S-bend river splits the field; three dry fords."),
    ("crater", "Crater", a_crater, "A ringed caldera with four breaches around a central pond."),
    ("terraces", "Terraces", a_terraces, "Three stepped terraces climb to a king-of-the-hill crown."),
    ("deep-forest", "Deep Forest", a_forest, "Dense woodland with trails and a diagonal brook."),
    ("badlands", "Badlands", a_badlands, "Cliff walls carve corridors; rocks for cover."),
    ("atoll", "Atoll", a_atoll, "A ring island around a wadeable lagoon with a central spit."),
    ("highlands", "Highlands", a_highlands, "Rolling hills with many contested hilltops."),
    ("delta", "Delta", a_delta, "Four channels cut the map into bands; fords are chokepoints."),
]


# ---- analysis -------------------------------------------------------------------------
N8 = [(0, 1), (1, 0), (1, 1), (1, -1)]


def passable_cells(m: Map):
    ok = m.land * 1000 >= MARGIN_BLOCK
    for c in m.cover:
        r = c.r + RADIUS
        i0, j0 = cell((c.x - r, c.z - r))
        i1, j1 = cell((c.x + r, c.z + r))
        i0, j0, i1, j1 = max(i0, 0), max(j0, 0), min(i1 + 1, NZ), min(j1 + 1, NX)
        sub = np.hypot(X[i0:i1, j0:j1] - c.x, Z[i0:i1, j0:j1] - c.z) < r
        ok[i0:i1, j0:j1] &= ~sub
    return ok


def distances(m: Map, sources):
    ok = passable_cells(m)
    h = m.height.astype(float)
    idx = np.arange(NZ * NX).reshape(NZ, NX)
    rows, cols, w = [], [], []
    for di, dj in N8:
        a = (slice(0, NZ - di), slice(max(0, -dj), NX - max(0, dj)))
        b = (slice(di, NZ), slice(max(0, dj), NX + min(0, dj)))
        length = STEP * math.hypot(di, dj)
        good = ok[a] & ok[b] & (np.abs(h[a] - h[b]) <= CLIFF * length)
        # Water quarters speed: weight wading edges by 4.
        wet = (h[a] < WATER) | (h[b] < WATER)
        cost = np.where(wet, 4 * length, length)
        rows.append(idx[a][good]); cols.append(idx[b][good]); w.append(cost[good])
    rows, cols, w = map(np.concatenate, (rows, cols, w))
    g = coo_matrix((w, (rows, cols)), shape=(NZ * NX, NZ * NX)).tocsr()
    src = [idx[cell(s)] for s in sources]
    d = dijkstra(g, directed=False, indices=src)
    return d.reshape(len(sources), NZ, NX), ok


def local_range(a, radius):
    k = int(math.ceil(radius / STEP))
    return ndimage.maximum_filter(a, 2 * k + 1) - ndimage.minimum_filter(a, 2 * k + 1)


def cover_density(m: Map, radius=600):
    img = np.zeros((NZ, NX))
    for c in m.cover:
        i, j = cell((c.x, c.z))
        if 0 <= i < NZ and 0 <= j < NX:
            img[i, j] += (c.r / 70) ** 2
    k = int(radius / STEP)
    yy, xx = np.mgrid[-k:k + 1, -k:k + 1]
    disk = (xx * xx + yy * yy <= k * k).astype(float)
    return ndimage.convolve(img, disk, mode="constant")


# ---- placement ------------------------------------------------------------------------
class Placer:
    def __init__(self, m: Map, rng):
        self.m, self.rng = m, rng
        h = m.height.astype(float)
        self.flat = local_range(h, 160) <= 70
        self.pad = local_range(h, 220) <= 100
        self.dry = ndimage.minimum_filter(h, 7) >= -140
        self.inland = ndimage.minimum_filter(m.land * 1000, 7) >= 140
        self.taken = []  # (x, z, radius)

    def refresh(self):
        self.dist, self.ok = distances(self.m, [self.m.home, mirror(self.m.home)])
        dA, dB = self.dist
        with np.errstate(invalid="ignore", divide="ignore"):
            self.ratio = dA / (dA + dB)
        self.density = cover_density(self.m)
        self.clear = ~ndimage.binary_dilation(~self.ok, iterations=2)

    def free(self, p, r):
        return all(math.hypot(p[0] - q[0], p[1] - q[1]) >= r + qr for q in self.taken for qr in [q[2]])

    def pick(self, lo, hi, score, sep=450, self_sep=900, need_pad=False, area=None):
        # Spacing relaxes in two steps before a map is rejected.
        for k in (1.0, 0.8, 0.65):
            try:
                return self._pick(lo, hi, score, sep * k, self_sep * k, need_pad, area)
            except RuntimeError as e:
                err = e
        raise err

    def _pick(self, lo, hi, score, sep, self_sep, need_pad, area):
        base = (self.ok & self.clear & self.flat & self.dry & self.inland & np.isfinite(self.ratio)
                & (self.ratio >= lo) & (self.ratio <= hi))
        if need_pad:
            base &= self.pad
        if area is not None:
            base &= area
        s = np.where(base, score, -np.inf)
        order = np.argsort(s, axis=None)[::-1]
        for flat in order[:8000]:
            i, j = divmod(int(flat), NX)
            if not np.isfinite(s[i, j]):
                break
            p = (int(XS[j]), int(ZS[i]))
            if not first_half(p):
                p = mirror(p)
            q = mirror(p)
            if math.hypot(p[0] - q[0], p[1] - q[1]) < self_sep:
                continue
            if not (self.free(p, sep) and self.free(q, sep)):
                continue
            self.taken += [(p[0], p[1], 0), (q[0], q[1], 0)]
            return p
        parts = dict(ok=self.ok, clear=self.clear, flat=self.flat, dry=self.dry, inland=self.inland, pad=self.pad,
                     band=np.isfinite(self.ratio) & (self.ratio >= lo) & (self.ratio <= hi))
        raise RuntimeError(f"no spot for ratio {lo}-{hi}: base={int(np.isfinite(s).sum())} " +
                           " ".join(f"{k}={int((v & parts['band']).sum())}" for k, v in parts.items()))

    def noise(self, amp=0.15):
        return amp * self.rng.random((NZ, NX))


def place_homes(m: Map, P: Placer):
    hx, hz = m.home
    best = None
    for dx in range(-600, 601, 100):
        for dz in range(-500, 501, 100):
            p = (hx + dx, hz + dz)
            i, j = cell(p)
            if P.pad[i, j] and P.dry[i, j] and P.inland[i, j]:
                score = -abs(dz) - abs(dx) * 0.5
                if best is None or score > best[0]:
                    best = (score, p)
    if best is None:
        raise RuntimeError("no flat home")
    m.home = best[1]
    P.taken += [(m.home[0], m.home[1], 400), (*mirror(m.home), 400)]


def place_cover(m: Map, rng, P: Placer, lanes):
    h = m.height.astype(float)
    steep = local_range(h, 120) > 50
    near_water = ndimage.minimum_filter(h, 5) < -120
    lane = np.full((NZ, NX), np.inf)
    for a, b in lanes:
        lane = np.minimum(lane, seg_dist(a[0], a[1], b[0], b[1]))
    ok = (m.land * 1000 > 160) & ~steep & ~near_water & (lane > 230)
    for (x, z, r) in P.taken:
        ok &= np.hypot(X - x, Z - z) > max(r, 330)
    placed = []

    def add(x, z, r, kind):
        p = (x, z)
        if not first_half(p):
            p = mirror(p)
            x, z = p
        q = mirror(p)
        if math.hypot(p[0] - q[0], p[1] - q[1]) < 2 * r + 120:
            return False
        for c in placed:
            if math.hypot(c.x - x, c.z - z) < c.r + r + 110 or math.hypot(c.x - q[0], c.z - q[1]) < c.r + r + 110:
                return False
        placed.append(Cover(x, z, r, kind))
        placed.append(Cover(q[0], q[1], r, kind))
        return True

    # Villages: a few houses and props around each centre.
    for vx, vz in m.village:
        for k in range(14):
            a, d = rng.uniform(0, 2 * math.pi), rng.uniform(250, 900)
            x, z = int(vx + d * math.cos(a)), int(vz + d * math.sin(a))
            i, j = cell((x, z))
            if 0 <= i < NZ and 0 <= j < NX and ok[i, j]:
                if k < 5:
                    add(x, z, int(rng.uniform(210, 240)), "house")
                else:
                    add(x, z, int(rng.uniform(80, 110)), "prop")
    # Forest groves on a jittered grid, thinned by the density field.
    for z in range(MIN_Z + 200, CZ + 1, 230):
        for x in range(MIN_X + 200, MAX_X, 230):
            px, pz = x + rng.integers(-80, 81), z + rng.integers(-80, 81)
            i, j = cell((px, pz))
            if not (0 <= i < NZ and 0 <= j < NX) or not ok[i, j]:
                continue
            if rng.random() < min(1.0, m.forest[i, j] * 1.2):
                add(int(px), int(pz), int(rng.uniform(55, 85)), "tree")
            elif rng.random() < m.rocks * 0.06:
                add(int(px), int(pz), int(rng.uniform(90, 150)), "rock")
    m.cover = placed


def build(name, title, fn, blurb, seed) -> Map:
    for attempt in range(12):
        rng = np.random.default_rng(seed * 101 + attempt)
        m = Map(name, title, fn.__name__[2:], blurb, seed * 101 + attempt)
        fn(m, rng)
        try:
            populate(m, rng)
            problems = validate(m)
        except RuntimeError as e:
            problems = [str(e)]
        if not problems:
            return m
        print(f"  {name} attempt {attempt}: {problems[:3]}", file=sys.stderr)
    raise SystemExit(f"{name}: no valid map")


def populate(m: Map, rng):
    P = Placer(m, rng)
    place_homes(m, P)
    P.refresh()
    if not np.isfinite(P.dist[0][cell(mirror(m.home))]):
        raise RuntimeError("homes disconnected by terrain")
    h = m.height.astype(float)
    n = P.noise
    hearts = [(m.home[0], m.home[1], 0, "home"), (*mirror(m.home), 1, "home")]
    d_c = np.hypot(X - CX, Z - CZ)
    roles = [
        ("center", 0.42, 0.58, -d_c / 800 + h / 300 + n(), 1100),
        ("forward", 0.30, 0.42, np.abs(Z - CZ) / -1500 + n(0.5), 1300),
        ("flank", 0.36, 0.64, np.abs(Z - CZ) / 1000 + n(), 1300),
        ("prize", 0.34, 0.66, h / 150 + np.hypot(X - CX, Z - CZ) / 3000 + n(), 1300),
    ]
    for role, lo, hi, score, sep in roles:
        p = P.pick(lo, hi, score, sep=sep, self_sep=1000 if role == "center" else 1400, need_pad=True)
        hearts += [(p[0], p[1], -1, role), (*mirror(p), -1, role)]
    m.hearts = hearts
    for x, z, _, _ in hearts:
        P.taken.append((x, z, 300))
    lanes = []
    for x, z, _, _ in hearts[2:]:
        lanes += [(m.home, (x, z)), (mirror(m.home), (x, z))]
    lanes.append((m.home, mirror(m.home)))
    m.lanes = lanes
    place_cover(m, rng, P, lanes)
    P.refresh()
    dens = P.density
    openness = -dens
    spec = [
        ("grenade", 0.10, 0.30, dens / 8 + n(), "near home, behind cover"),
        ("grenade", 0.10, 0.34, dens / 8 + np.abs(Z - CZ) / 2000 + n(), "near home, flank"),
        ("uniform", 0.30, 0.44, dens / 6 + n(), "midfield, in cover"),
        ("spray", 0.32, 0.48, dens / 3 + n(0.05), "close quarters"),
        ("armor", 0.38, 0.50, h / 120 + openness / 20 + n(), "exposed high ground"),
        ("medkit", 0.42, 0.58, dens / 10 - d_c / 3000 + n(), "centre, near cover"),
        ("medkit", 0.26, 0.46, np.abs(Z - CZ) / 1500 + dens / 12 + n(), "flank"),
    ]
    for kind, lo, hi, score, role in spec:
        p = P.pick(lo, hi, score, sep=380, self_sep=700)
        m.pickups += [(p[0], p[1], kind, role), (*mirror(p), kind, role)]
    for k in range(3):
        p = P.pick(0.22, 0.48, openness / 4 + n(0.3), sep=520, self_sep=900, need_pad=True)
        m.trenches += [p, mirror(p)]


# ---- validation -----------------------------------------------------------------------
def validate(m: Map):
    bad = []
    if not np.array_equal(m.height, rot(m.height)):
        bad.append("heights not half-turn symmetric")
    kinds = {}
    for _, _, k, _ in m.pickups:
        kinds[k] = kinds.get(k, 0) + 1
    want = {"grenade": 4, "spray": 2, "armor": 2, "medkit": 4, "uniform": 2}
    if kinds != want:
        bad.append(f"pickup counts {kinds}")
    if len(m.hearts) != 10 or len(m.trenches) != 6:
        bad.append("heart/trench counts")
    for seq in (m.hearts, m.pickups, [(x, z) for x, z in m.trenches], [(c.x, c.z) for c in m.cover]):
        for a, b in zip(seq[0::2], seq[1::2]):
            if (b[0], b[1]) != mirror(a[:2]):
                bad.append(f"unmirrored pair {a[:2]} {b[:2]}")
    dist, ok = distances(m, [m.home, mirror(m.home)])
    h = m.height
    pts = [(x, z, f"heart:{r}") for x, z, _, r in m.hearts] + [(x, z, k) for x, z, k, _ in m.pickups] + \
          [(x, z, "trench") for x, z in m.trenches]
    for x, z, what in pts:
        i, j = cell((x, z))
        if not ok[i, j]:
            bad.append(f"{what} at {(x, z)} blocked")
        if not (np.isfinite(dist[0][i, j]) and np.isfinite(dist[1][i, j])):
            bad.append(f"{what} at {(x, z)} unreachable")
        if h[i, j] < WATER:
            bad.append(f"{what} at {(x, z)} in water")
        for c in m.cover:
            if math.hypot(c.x - x, c.z - z) < c.r + (150 if what == "trench" else 90):
                bad.append(f"{what} at {(x, z)} inside cover")
                break
    for x, z in m.trenches:
        i0, j0 = cell((x - TRENCH / 2, z - TRENCH / 2))
        i1, j1 = cell((x + TRENCH / 2, z + TRENCH / 2))
        patch = h[i0:i1 + 1, j0:j1 + 1]
        if patch.max() - patch.min() > 60 or patch.min() < WATER:
            bad.append(f"trench at {(x, z)} not flat/dry")
    return bad


def stats(m: Map):
    dist, ok = distances(m, [m.home, mirror(m.home)])
    h = m.height.astype(float)
    land = m.land * 1000 >= MARGIN_BLOCK
    gy, gx = np.gradient(h, STEP)
    cliff = land & (np.hypot(gx, gy) > CLIFF)
    area = land.sum()
    return {
        "homeToHome": int(dist[0][cell(mirror(m.home))]),
        "landM2": int(area * STEP * STEP / 10000),
        "waterPct": round(100 * float((land & (h < WATER)).sum()) / area, 1),
        "highGroundPct": round(100 * float((land & (h >= HIGH)).sum()) / area, 1),
        "cliffPct": round(100 * float(cliff.sum()) / area, 1),
        "reachablePct": round(100 * float((np.isfinite(dist[0]) & ok).sum()) / max(ok.sum(), 1), 1),
        "cover": {k: sum(1 for c in m.cover if c.kind == k) for k in ["tree", "house", "prop", "rock"]},
    }


# ---- output ---------------------------------------------------------------------------
def to_json(m: Map):
    b64 = lambda a: base64.b64encode(np.ascontiguousarray(a).astype("<i2").tobytes()).decode()
    margin = np.clip(np.rint(m.land * 1000), -32000, 32000).astype(np.int16)
    return {
        "format": "paintbot-map/1",
        "name": m.name, "title": m.title, "archetype": m.archetype, "description": m.blurb, "seed": m.seed,
        "rulesBase": 40, "symmetry": "halfTurn", "centre": [CX, CZ],
        "bounds": [MIN_X, MIN_Z, MAX_X, MAX_Z],
        "grid": {"x0": MIN_X, "z0": MIN_Z, "step": STEP, "nx": NX, "nz": NZ, "encoding": "base64 int16le, row-major z then x",
                 "height": b64(m.height), "margin": b64(margin)},
        "homes": [list(m.home), list(mirror(m.home))],
        "controlHearts": [{"x": x, "z": z, "owner": o, "role": r} for x, z, o, r in m.hearts],
        "pickups": [{"x": x, "z": z, "kind": k, "role": r} for x, z, k, r in m.pickups],
        "trenches": [{"x": x - TRENCH // 2, "z": z - TRENCH // 2, "w": TRENCH, "h": TRENCH} for x, z in m.trenches],
        "cover": [{"x": int(c.x - c.r), "z": int(c.z - c.r), "w": int(2 * c.r), "h": 0, "kind": c.kind} for c in m.cover],
        "stats": stats(m),
    }


PICKUP_KINDS = ["grenade", "spray", "medkit", "armor", "uniform"]  # sim.nim PickupKind order
COVER_KINDS = ["tree", "house", "prop", "rock"]


def to_binary(m: Map) -> bytes:
    """The engine's embedded form (examples/paintbot/maps.nim): little-endian int32 header and
    records around two int16 grids."""
    head = [NX, NZ, MIN_X, MIN_Z, STEP, m.home[0], m.home[1],
            len(m.hearts), len(m.pickups), len(m.trenches), len(m.cover)]
    margin = np.clip(np.rint(m.land * 1000), -32000, 32000).astype("<i2")
    out = [b"PBMAP001", np.array(head, "<i4").tobytes(), m.height.astype("<i2").tobytes(), margin.tobytes()]
    rec = []
    rec += [(x, z, o) for x, z, o, _ in m.hearts]
    rec += [(x, z, PICKUP_KINDS.index(k)) for x, z, k, _ in m.pickups]
    rec += [(x - TRENCH // 2, z - TRENCH // 2, TRENCH, TRENCH) for x, z in m.trenches]
    rec += [(int(c.x - c.r), int(c.z - c.r), int(2 * c.r), COVER_KINDS.index(c.kind)) for c in m.cover]
    out += [np.array(r, "<i4").tobytes() for r in rec]
    return b"".join(out)


def render(m: Map, path: Path, scale=10):
    from PIL import Image, ImageDraw
    h = m.height.astype(float)
    W, H = (MAX_X - MIN_X) // scale, (MAX_Z - MIN_Z) // scale
    up = ndimage.zoom(h, (H / NZ, W / NX), order=1)
    lm = ndimage.zoom(m.land * 1000, (H / NZ, W / NX), order=1)
    gy, gx = np.gradient(up, scale)
    shade = np.clip(0.75 + 0.9 * (-gx - gy) / math.sqrt(2), 0.35, 1.25)
    t = np.clip((up + 50) / 450, 0, 1)[..., None]
    low, high = np.array([118, 158, 84]), np.array([206, 186, 128])
    rgb = (low * (1 - t) + high * t) * shade[..., None]
    rgb = np.where((up >= HIGH)[..., None], rgb * np.array([1.05, 1.0, 0.92]), rgb)
    cliff = np.hypot(gx, gy) > CLIFF
    rgb = np.where(cliff[..., None], np.array([88, 72, 58]), rgb)
    rgb = np.where((up < WATER)[..., None], np.array([92, 170, 190]) * (0.85 + 0.15 * shade[..., None]), rgb)
    sea = lm < MARGIN_BLOCK
    rgb = np.where(sea[..., None], np.array([44, 104, 130]), rgb)
    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8)[::1], "RGB")
    d = ImageDraw.Draw(img)
    P = lambda x, z: ((x - MIN_X) / scale, (z - MIN_Z) / scale)
    for x, z in m.trenches:
        a, b = P(x - TRENCH / 2, z - TRENCH / 2), P(x + TRENCH / 2, z + TRENCH / 2)
        d.rectangle([a, b], fill=(96, 78, 52), outline=(50, 40, 28), width=2)
    colors = {"tree": (38, 88, 44), "house": (150, 92, 60), "prop": (126, 104, 82), "rock": (120, 120, 116)}
    for c in m.cover:
        x, z = P(c.x, c.z)
        r = c.r / scale
        d.ellipse([x - r, z - r, x + r, z + r], fill=colors[c.kind], outline=(20, 30, 20))
    icon = {"grenade": ((70, 70, 70), "G"), "spray": ((150, 60, 200), "S"), "armor": ((90, 120, 160), "A"),
            "medkit": ((240, 240, 240), "+"), "uniform": ((230, 180, 40), "U")}
    for x, z, k, _ in m.pickups:
        px, pz = P(x, z)
        col, ch = icon[k]
        d.rectangle([px - 13, pz - 13, px + 13, pz + 13], fill=col, outline=(0, 0, 0), width=2)
        d.text((px - 4, pz - 7), ch, fill=(0, 0, 0) if k in ("medkit", "uniform") else (255, 255, 255))
    for x, z, o, _ in m.hearts:
        px, pz = P(x, z)
        col = {0: (224, 84, 52), 1: (60, 120, 230), -1: (250, 240, 245)}[o]
        r = 24 if o >= 0 else 18
        d.ellipse([px - r, pz - r, px + r, pz + r], fill=col, outline=(40, 0, 20), width=3)
        d.text((px - 3, pz - 7), "♥" if False else "H", fill=(40, 0, 20))
    img.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="maps")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--only")
    ap.add_argument("--no-png", action="store_true")
    ap.add_argument("--engine", help="also write <name>.pbmap files here (examples/paintbot/maps)")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    index = []
    for i, (name, title, fn, blurb) in enumerate(CATALOGUE):
        if args.only and args.only != name:
            continue
        m = build(name, title, fn, blurb, args.seed * 1000 + i)
        doc = to_json(m)
        (out / f"{name}.json").write_text(json.dumps(doc, separators=(",", ":")))
        if not args.no_png:
            render(m, out / f"{name}.png")
        if args.engine:
            Path(args.engine).mkdir(parents=True, exist_ok=True)
            (Path(args.engine) / f"{name}.pbmap").write_bytes(to_binary(m))
        index.append({k: doc[k] for k in ("name", "title", "archetype", "description", "seed", "stats")})
        print(f"{name}: {doc['stats']}")
    if not args.only:
        (out / "index.json").write_text(json.dumps(index, indent=1))


if __name__ == "__main__":
    main()
