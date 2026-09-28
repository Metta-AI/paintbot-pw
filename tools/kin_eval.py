#!/usr/bin/env python3
"""Heartland (FFA-kin) kinship evals over the native training library (ctypes, stdlib only).

Plan tasks C3-C5 (docs/plans/2026-09-27-paintbot-ffa-kin.md). Every episode runs in
libpaintbot_pw (pw_set_game_mode 1) with seats driven by BASIC scripts (pw_set_seat_script) or a
neural bundle (pw_set_seat_policy_script + pw_net_infer + pw_step_logits), and reads the kin
counters (pw_pair_stats, pw_kin_seat_stats, pw_scores) at the end.

Suites (--suite, comma-separated, or "all"):
  incentive   C3 gate (always the scripted pair, whatever --policy is): ffa.bas (aware) vs
              ffa_blind.bas (blind, tools/make_ffa_blind.py), half the families each, on the
              fours and pairs layouts; aware minus blind mean kin-weighted R per seat with a
              bootstrap 95% CI; welfare (total raw score) per layout with every seat on ffa.bas.
  hamilton    per r bucket {0, .25, .5, 1}: harm, kills, defend, yield, near, co-capture,
              costly-defend, death-after-defend; slope against r with a bootstrap CI. Strangers
              and clones are the controls. Harm and defend are the headline curves; near and
              yield are mechanically confounded by the territory kin boost (design, Invariant).
  scrambled   families spawn apart, strangers together (pw_set_spawn_grouping); hamilton again,
              plus the same metrics split by spawn group, so the curves can be seen to track r.
  rsweep      a fixed 4x4 grouping with within-family ibd 0, 8, 16, 32 (pw_set_kin_override).
  genes_only  hamilton with pw_set_obs_mask bit 0 (r-to-me zeroed); neural policies only.
  health      kin share of return per layout, the collusion alarm (heart passes between r >= .5
              pairs vs r = 0 pairs, flagged above 3x), episode length and death times.
  selfish     the policy vs --policy2 (a control trained on own score only); "no control" without it.
  gini        within-family Gini of raw score; death hazard against the count of living close kin.
  crossplay   half of every family on --policy2 (default ffa.bas); harm/defend by r split by
              same-policy vs other-policy kin.
  gap         one member per family weakened (damage scale 500, fire period 2); defend toward it
              vs toward a full-strength relative.
  heldout     hamilton on the --layouts given (default cousins), for layouts training excluded.

Output (--out DIR): report.html (self-contained, inline SVG, no network) and results.json
(every reported number). --dump-episodes also writes episodes.jsonl with the raw counters.

    python tools/kin_eval.py --suite incentive --episodes 400 --workers 16 --out tmp/kin-incentive
    python tools/kin_eval.py --suite hamilton,health --policy bundle.zip --episodes 200 --out tmp/kin
    python tools/kin_eval.py --suite all --episodes 2 --ticks 600 --out tmp/kin-smoke   # smoke

The library is built (if --lib is not given and tmp/libpaintbot_pw.<so|dylib> is missing) with
    nim c --app:lib --mm:arc --threads:on -d:pwTraining -d:headless -d:release \\
      -o:tmp/libpaintbot_pw.<so|dylib> examples/paintbot/native_env.nim
Heavy batteries belong on Slurm (tools/slurm/kin_eval.sbatch), not on a shared laptop.
"""

import argparse
import array
import ctypes
import html
import json
import math
import multiprocessing
import os
import random
import subprocess
import sys
import time
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYERS = ROOT / "coworld/paintbot/players"
FFA_BAS = PLAYERS / "ffa.bas"
BLIND_BAS = PLAYERS / "ffa_blind.bas"

SEATS = 16
FFA_TICKS = 8640
TICKS_PER_MINUTE = 1440
OBS_FFA = 101
LOGITS = 82
PAIR_STATS = 13
(VISIBLE, IN_RANGE, DAMAGE, KILLS, DEFEND, DEFEND_OPP, YIELD_OPP, CONTEST, NEAR, CO_CAPTURE,
 COSTLY_DEFEND, DEATH_AFTER_DEFEND, HEART_PASS) = range(PAIR_STATS)
PAIR_STAT_NAMES = ["visible", "in_range", "damage", "kills", "defend", "defend_opp", "yield_opp",
                   "contest", "near", "co_capture", "costly_defend", "death_after_defend", "heart_pass"]
# Pair-aggregate vector: the 13 counters, then pair-episodes, then pair-ticks.
N_PAIRS, PAIR_TICKS = PAIR_STATS, PAIR_STATS + 1
VEC = PAIR_STATS + 2

LAYOUTS = {"fours": 0, "pairs": 1, "trios": 2, "cousins": 3, "strangers": 4, "clones": 5}
LAYOUT_NAMES = {v: k for k, v in LAYOUTS.items()}
KIN_LAYOUTS = ["fours", "pairs", "trios", "cousins"]
ALL_LAYOUTS = KIN_LAYOUTS + ["strangers", "clones"]
R_BUCKETS = [0.0, 0.25, 0.5, 1.0]
SUITES = ["incentive", "hamilton", "scrambled", "rsweep", "genes_only", "health",
          "selfish", "gini", "crossplay", "gap", "heldout"]

# Opportunity-normalised Hamilton metrics: name -> (label, headline, confounded, fn(vector)).
def _ratio(a, b, scale=1.0):
    return scale * a / b if b > 0 else None

METRICS = {
    "harm": ("harm: damage per 1000 in-range ticks", True, False,
             lambda v: _ratio(v[DAMAGE], v[IN_RANGE], 1000)),
    "defend": ("defend: defend damage per 1000 opportunity ticks", True, False,
               lambda v: _ratio(v[DEFEND], v[DEFEND_OPP], 1000)),
    "kills": ("kills per 100 pair-episodes", False, False, lambda v: _ratio(v[KILLS], v[N_PAIRS], 100)),
    "yield": ("yield: 1 - contest / yield opportunity", False, True,
              lambda v: None if v[YIELD_OPP] <= 0 else 1 - v[CONTEST] / v[YIELD_OPP]),
    "near": ("near: fraction of ticks within 400u", False, True, lambda v: _ratio(v[NEAR], v[PAIR_TICKS])),
    "co_capture": ("great-heart co-captures per 100 pair-episodes", False, False,
                   lambda v: _ratio(v[CO_CAPTURE], v[N_PAIRS], 100)),
    "costly_defend": ("costly-defend share of defend damage", False, False,
                      lambda v: _ratio(v[COSTLY_DEFEND], v[DEFEND])),
    "death_after_defend": ("deaths after defending, per 100 pair-episodes", False, False,
                           lambda v: _ratio(v[DEATH_AFTER_DEFEND], v[N_PAIRS], 100)),
}
HEADLINE = ["harm", "defend"]


# ----------------------------------------------------------------------------------------------
# Library
# ----------------------------------------------------------------------------------------------

def default_lib_path() -> Path:
    return ROOT / "tmp" / ("libpaintbot_pw.dylib" if sys.platform == "darwin" else "libpaintbot_pw.so")


def build_lib(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["nim", "c", "--app:lib", "--mm:arc", "--threads:on", "-d:pwTraining", "-d:headless",
                    "-d:release", "--hints:off", f"-o:{path}", "examples/paintbot/native_env.nim"],
                   cwd=ROOT, check=True)


P, I32, F32, U32 = ctypes.c_void_p, ctypes.c_int32, ctypes.c_float, ctypes.c_uint32
PF, PI, PU, PI8 = (ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_int32),
                   ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_int8))
SIGNATURES = {
    "pw_create_observation": ([I32, I32, I32], P), "pw_destroy": ([P], None),
    "pw_reset": ([P, I32, I32], ctypes.c_int), "pw_step": ([P, PI, PF, PF], ctypes.c_int),
    "pw_step_logits": ([P, PI, PF, PF, PF], ctypes.c_int),
    "pw_observe": ([P, PF, PF], ctypes.c_int), "pw_results": ([P, PF], ctypes.c_int),
    "pw_set_seat_script": ([P, ctypes.c_int, ctypes.c_char_p, I32], ctypes.c_int),
    "pw_seat_script_status": ([P, ctypes.c_int, ctypes.c_char_p, I32], ctypes.c_int),
    "pw_set_seat_policy_script": ([P, ctypes.c_int, ctypes.c_char_p, I32, ctypes.c_char_p, I32], ctypes.c_int),
    "pw_set_seat_fire_period": ([P, ctypes.c_int, I32], ctypes.c_int),
    "pw_set_seat_damage_scale": ([P, ctypes.c_int, I32], ctypes.c_int),
    "pw_set_game_mode": ([P, I32], ctypes.c_int), "pw_set_kin_layout": ([P, I32], ctypes.c_int),
    "pw_kin": ([P, PF], ctypes.c_int), "pw_genes": ([P, PU], ctypes.c_int),
    "pw_scores": ([P, PF], ctypes.c_int), "pw_reward_split": ([P, PF], ctypes.c_int),
    "pw_kin_seat_stats": ([P, PF], ctypes.c_int), "pw_pair_stats": ([P, PI], ctypes.c_int),
    "pw_set_spawn_grouping": ([P, PI8], ctypes.c_int),
    "pw_set_kin_override": ([P, PI8, PU, PI8], ctypes.c_int),
    "pw_set_obs_mask": ([P, U32], ctypes.c_int),
    "pw_observation_contract_hash": ([I32, ctypes.c_char_p, I32], ctypes.c_int),
    "pw_net_load": ([ctypes.c_char_p, ctypes.c_int64, ctypes.c_char_p, I32], P),
    "pw_net_info": ([P, ctypes.POINTER(ctypes.c_int64)], ctypes.c_int),
    "pw_net_infer": ([P, PF, PF, PF], ctypes.c_int),
}


def load_lib(path) -> ctypes.CDLL:
    lib = ctypes.CDLL(str(path))
    for name, (args, res) in SIGNATURES.items():
        fn = getattr(lib, name)
        fn.argtypes, fn.restype = args, res
    return lib


# ----------------------------------------------------------------------------------------------
# Policies
# ----------------------------------------------------------------------------------------------

def policy_spec(path) -> dict:
    """A policy argument: a BASIC file (.bas) or a neural bundle (.zip with policy.bas,
    manifest.json, model.bin)."""
    path = Path(path)
    if path.suffix == ".zip":
        with zipfile.ZipFile(path) as z:
            names = set(z.namelist())
            for need in ("policy.bas", "manifest.json", "model.bin"):
                if need not in names:
                    raise SystemExit(f"{path}: neural bundle lacks {need}")
        return {"kind": "neural", "path": str(path.resolve()), "name": path.name}
    if not path.exists():
        raise SystemExit(f"{path}: no such policy")
    return {"kind": "basic", "path": str(path.resolve()), "name": path.name}


_LIB = None
_SOURCES: dict = {}
_NETS: dict = {}


def _worker_init(lib_path):
    global _LIB
    _LIB = load_lib(lib_path)


def _source(spec):
    key = spec["path"]
    if key not in _SOURCES:
        if spec["kind"] == "basic":
            _SOURCES[key] = Path(key).read_bytes()
        else:
            with zipfile.ZipFile(key) as z:
                _SOURCES[key] = (z.read("policy.bas"), z.read("manifest.json"), z.read("model.bin"))
    return _SOURCES[key]


def _net(spec):
    key = spec["path"]
    if key not in _NETS:
        model = _source(spec)[2]
        err = ctypes.create_string_buffer(512)
        net = _LIB.pw_net_load(model, len(model), err, 512)
        if not net:
            raise RuntimeError(f"{spec['name']}: pw_net_load refused the model: {err.value.decode()}")
        info = (ctypes.c_int64 * 8)()
        _LIB.pw_net_info(net, info)
        _NETS[key] = (net, int(info[1]), int(info[2]), int(info[3]))
    return _NETS[key]


# ----------------------------------------------------------------------------------------------
# Kinship helpers
# ----------------------------------------------------------------------------------------------

def families_from_r(r):
    """Families = connected components of r >= 0.5 (siblings share 16 of 32 loci; clones all 32)."""
    parent = list(range(SEATS))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for i in range(SEATS):
        for j in range(i + 1, SEATS):
            if r[i][j] >= 0.5 - 1e-6:
                parent[find(i)] = find(j)
    groups: dict = {}
    for i in range(SEATS):
        groups.setdefault(find(i), []).append(i)
    return sorted(groups.values(), key=lambda g: g[0])


def r_bucket(value):
    return min(R_BUCKETS, key=lambda b: abs(b - value))


def scrambled_grouping(families):
    """Spawn groups with no two relatives together where possible: deal family members
    round-robin, then cut into groups of the largest family's size."""
    size = max(len(f) for f in families)
    if size < 2:
        return [-1] * SEATS
    order = []
    for m in range(size):
        for f in families:
            if m < len(f):
                order.append(f[m])
    group = [-1] * SEATS
    for n, seat in enumerate(order):
        group[seat] = n // size
    return group


def sweep_kinship(ibd_level, seed):
    """rsweep: seats 4f..4f+3 form family f; members share `ibd_level` inherited loci."""
    rng = random.Random(seed * 7919 + ibd_level)
    family = [s // 4 for s in range(SEATS)]
    genes = [0] * SEATS
    for f in range(4):
        ancestor = rng.getrandbits(32)
        shared = rng.sample(range(32), ibd_level)
        mask = sum(1 << b for b in shared)
        for s in range(4 * f, 4 * f + 4):
            genes[s] = (ancestor & mask) | (rng.getrandbits(32) & ~mask & 0xFFFFFFFF)
    ibd = [[32 if i == j else (ibd_level if family[i] == family[j] else 0) for j in range(SEATS)]
           for i in range(SEATS)]
    return family, genes, ibd


# ----------------------------------------------------------------------------------------------
# One episode (runs in a worker process)
# ----------------------------------------------------------------------------------------------

def _assign(rule, families, seed, policies):
    """Seat -> policy name for an assignment rule, given the episode's families. A list is an
    explicit seat -> policy-name assignment."""
    names = [None] * SEATS
    if isinstance(rule, list):
        return list(rule)
    if rule == "all":
        return ["main"] * SEATS
    if rule == "mixed":  # incentive: half the families aware, half blind, randomised per episode
        order = list(range(len(families)))
        random.Random(seed ^ 0x5EED).shuffle(order)
        aware = set(order[:len(order) // 2])
        for n, fam in enumerate(families):
            for s in fam:
                names[s] = "aware" if n in aware else "blind"
        return names
    if rule == "crossplay":  # alternate members of every family between the two policies
        for fam in families:
            for m, s in enumerate(fam):
                names[s] = "main" if m % 2 == 0 else "second"
        return names
    raise ValueError(rule)


def run_episode(job):
    lib = _LIB
    seed, ticks = job["seed"], job["ticks"]
    policies = job["policies"]
    h = lib.pw_create_observation(seed, ticks, OBS_FFA)
    if not h:
        raise RuntimeError("pw_create_observation failed")
    try:
        lib.pw_set_game_mode(h, 1)
        lib.pw_set_kin_layout(h, LAYOUTS[job["layout"]] if job.get("layout") else -1)
        if job.get("override"):
            fam, genes, ibd = job["override"]
            lib.pw_set_kin_override(h, (ctypes.c_int8 * SEATS)(*fam), (ctypes.c_uint32 * SEATS)(*genes),
                                    (ctypes.c_int8 * 256)(*[x for row in ibd for x in row]))
        lib.pw_set_obs_mask(h, job.get("obs_mask", 0))
        if lib.pw_reset(h, seed, ticks) != 0:  # applies mode, layout and override: read the kinship
            raise RuntimeError("pw_reset failed")
        kin = (ctypes.c_float * 256)()
        lib.pw_kin(h, kin)
        r = [[round(kin[16 * i + j], 4) for j in range(SEATS)] for i in range(SEATS)]
        families = ([[s for s in range(SEATS) if job["override"][0][s] == f] for f in sorted(set(job["override"][0]))]
                    if job.get("override") else families_from_r(r))
        group = None
        if job.get("grouping") == "scrambled":
            group = scrambled_grouping(families)
        elif job.get("grouping") == "families":
            group = [-1] * SEATS
            for n, fam in enumerate(families):
                for s in fam:
                    group[s] = n
        if group is not None:
            lib.pw_set_spawn_grouping(h, (ctypes.c_int8 * SEATS)(*group))
        seat_policy = _assign(job["assign"], families, seed, policies)
        weak = []
        if job.get("gap"):
            weak = [fam[0] for fam in families if len(fam) >= 2]
            for s in weak:
                lib.pw_set_seat_damage_scale(h, s, 500)
                lib.pw_set_seat_fire_period(h, s, 2)
        neural_seats = []
        for s in range(SEATS):
            spec = policies[seat_policy[s]]
            if spec["kind"] == "basic":
                src = _source(spec)
                if lib.pw_set_seat_script(h, s, src, len(src)) != 0:
                    raise RuntimeError(f"{spec['name']}: BASIC compile failed")
            else:
                bas, manifest, _ = _source(spec)
                rc = lib.pw_set_seat_policy_script(h, s, bas, len(bas), manifest, len(manifest))
                if rc != 0:
                    msg = ctypes.create_string_buffer(512)
                    lib.pw_seat_script_status(h, s, msg, 512)
                    raise RuntimeError(f"{spec['name']}: policy script rejected ({rc}): {msg.value.decode()}")
                neural_seats.append((s, spec))
        if lib.pw_reset(h, seed, ticks) != 0:  # scripts start fresh; spawn grouping applies
            raise RuntimeError("pw_reset failed")
        lib.pw_kin(h, kin)
        if any(abs(kin[16 * i + j] - r[i][j]) > 1e-3 for i in range(SEATS) for j in range(SEATS)):
            raise RuntimeError("kinship changed between the probe reset and the episode reset")

        actions = (ctypes.c_int32 * (SEATS * 5))()
        rewards = (ctypes.c_float * SEATS)()
        terminals = (ctypes.c_float * SEATS)()
        results = (ctypes.c_float * 8)()
        seat_stats = (ctypes.c_float * 48)()
        played = 0
        if neural_seats:
            nets = {}
            obs_size = None
            for s, spec in neural_seats:
                net, inputs, outputs, state_size = _net(spec)
                if outputs != LOGITS:
                    raise RuntimeError(f"{spec['name']}: model has {outputs} outputs, expected {LOGITS}")
                obs_size = inputs
                nets[s] = (net, (ctypes.c_float * max(1, state_size))())
            obs = (ctypes.c_float * (SEATS * obs_size))()
            resets = (ctypes.c_float * SEATS)()
            logits = (ctypes.c_float * (SEATS * LOGITS))()
            fsize = ctypes.sizeof(ctypes.c_float)
            obs_addr, logit_addr = ctypes.addressof(obs), ctypes.addressof(logits)
            for t in range(ticks):
                lib.pw_observe(h, obs, resets)
                lib.pw_kin_seat_stats(h, seat_stats)
                for s, (net, state) in nets.items():
                    if resets[s] > 0 or t == 0:
                        ctypes.memset(state, 0, ctypes.sizeof(state))
                    if seat_stats[3 * s] >= 0:
                        continue  # out of the match: the host runs no actor for a dead seat
                    rc = lib.pw_net_infer(net, ctypes.cast(obs_addr + s * obs_size * fsize, PF), state,
                                          ctypes.cast(logit_addr + s * LOGITS * fsize, PF))
                    if rc != 0:
                        raise RuntimeError(f"pw_net_infer failed ({rc}) at tick {t}")
                if lib.pw_step_logits(h, actions, logits, rewards, terminals) != 0:
                    raise RuntimeError("pw_step_logits failed")
                played += 1
                lib.pw_results(h, results)
                if results[1] != -1:
                    break
        else:
            for _ in range(ticks):
                if lib.pw_step(h, actions, rewards, terminals) != 0:
                    raise RuntimeError("pw_step failed")
                played += 1
                lib.pw_results(h, results)
                if results[1] != -1:
                    break
        status = []
        for s in range(SEATS):
            status.append(lib.pw_seat_script_status(h, s, None, 0))
        pairs = (ctypes.c_int32 * (SEATS * SEATS * PAIR_STATS))()
        lib.pw_pair_stats(h, pairs)
        lib.pw_kin_seat_stats(h, seat_stats)
        scores = (ctypes.c_float * SEATS)()
        lib.pw_scores(h, scores)
        lib.pw_results(h, results)
        return {
            "suite": job["suite"], "cond": job["cond"], "seed": seed, "layout": job.get("layout"),
            "ticks": played, "r": r, "families": families, "policy": seat_policy, "group": group,
            "weak": weak, "status": status,
            "s": [round(seat_stats[3 * i + 1] * 4320, 2) for i in range(SEATS)],  # own part = r_ii ds_i
            "R": [round(scores[i], 2) for i in range(SEATS)],
            "own": [seat_stats[3 * i + 1] for i in range(SEATS)],
            "kin": [seat_stats[3 * i + 2] for i in range(SEATS)],
            "death": [int(seat_stats[3 * i]) for i in range(SEATS)],
            "results": list(results),
            "pairs": bytes(pairs),  # int32 native order; array("i") in the parent
        }
    finally:
        lib.pw_destroy(h)


# ----------------------------------------------------------------------------------------------
# Statistics (stdlib only)
# ----------------------------------------------------------------------------------------------

def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


def percentile(sorted_xs, q):
    if not sorted_xs:
        return None
    k = (len(sorted_xs) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return sorted_xs[lo] + (sorted_xs[hi] - sorted_xs[lo]) * (k - lo)


def bootstrap(units, stat, reps, seed):
    """Point estimate and 95% percentile CI of stat(units) over resampled units (episodes)."""
    point = stat(units)
    if not units or point is None:
        return {"value": point, "lo": None, "hi": None, "n": len(units)}
    rng = random.Random(seed)
    draws = []
    n = len(units)
    for _ in range(reps):
        v = stat([units[rng.randrange(n)] for _ in range(n)])
        if v is not None:
            draws.append(v)
    draws.sort()
    return {"value": point, "lo": percentile(draws, 0.025), "hi": percentile(draws, 0.975), "n": n}


def slope(points):
    """OLS slope of y on x over (x, y) points with y defined; None with fewer than two x values."""
    pts = [(x, y) for x, y in points if y is not None]
    if len({x for x, _ in pts}) < 2:
        return None
    mx = sum(x for x, _ in pts) / len(pts)
    my = sum(y for _, y in pts) / len(pts)
    den = sum((x - mx) ** 2 for x, _ in pts)
    return sum((x - mx) * (y - my) for x, y in pts) / den


def add_vec(a, b):
    for k in range(VEC):
        a[k] += b[k]


def pair_vectors(ep, key):
    """Per-episode pair aggregates: {key(ep, i, j): vector} over ordered pairs i != j (key None
    drops the pair)."""
    out: dict = {}
    p = ep["pairs"]
    t = ep["ticks"]
    for i in range(SEATS):
        for j in range(SEATS):
            if i == j:
                continue
            k = key(ep, i, j)
            if k is None:
                continue
            v = out.get(k)
            if v is None:
                v = out[k] = [0] * VEC
            base = (16 * i + j) * PAIR_STATS
            for s in range(PAIR_STATS):
                v[s] += p[base + s]
            v[N_PAIRS] += 1
            v[PAIR_TICKS] += t
    return out


def by_r(ep, i, j):
    return r_bucket(ep["r"][i][j])


def summed(units, k):
    tot = [0] * VEC
    for u in units:
        v = u.get(k)
        if v is not None:
            add_vec(tot, v)
    return tot


def curve_table(units, keys, reps, seed, xs=None):
    """For each metric, value + CI per key; with numeric keys xs, the slope against x with a CI.
    One set of episode resamples serves every metric and key (the CIs are jointly drawn)."""
    zero = [0] * VEC
    cols = {k: [u.get(k, zero) for u in units] for k in keys}

    def totals(idx):
        return {k: [sum(c) for c in zip(*[cols[k][i] for i in idx])] if idx else list(zero) for k in keys}
    n = len(units)
    point = totals(list(range(n)))
    rng = random.Random(seed)
    draws = [totals([rng.randrange(n) for _ in range(n)]) for _ in range(reps if n else 0)]
    out = {}
    for m, (_, _, _, fn) in METRICS.items():
        row = {"by": {}}
        for k in keys:
            vals = sorted(v for v in (fn(d[k]) for d in draws) if v is not None)
            row["by"][str(k)] = {"value": fn(point[k]), "lo": percentile(vals, 0.025),
                                 "hi": percentile(vals, 0.975), "n": n, "count": point[k][N_PAIRS]}
        if xs is not None:
            def sl(t):
                return slope([(x, fn(t[k])) for k, x in zip(keys, xs)])
            vals = sorted(v for v in (sl(d) for d in draws) if v is not None)
            row["slope"] = {"value": sl(point), "lo": percentile(vals, 0.025), "hi": percentile(vals, 0.975), "n": n}
        out[m] = row
    return out


# ----------------------------------------------------------------------------------------------
# Suites: jobs, then analysis
# ----------------------------------------------------------------------------------------------

def make_jobs(suite, args, policies):
    """Episode jobs for one suite. Seeds are shared across conditions (paired comparisons)."""
    jobs = []
    base = args.seed * 1_000_003 % 2_000_000_000

    def add(cond, **kw):
        for e in range(args.episodes):
            jobs.append(dict(suite=suite, cond=cond, seed=(base + e) % 2_000_000_000, ticks=args.ticks,
                             policies=policies, **kw))

    main_neural = policies["main"]["kind"] == "neural"
    lay = args.layouts
    if suite == "incentive":
        for layout in lay or ["fours", "pairs"]:
            add({"part": "mixed", "layout": layout}, layout=layout, assign="mixed")
        for layout in ["clones", "fours", "pairs", "strangers"]:
            add({"part": "welfare", "layout": layout}, layout=layout, assign="welfare")
    elif suite in ("hamilton", "health", "heldout", "genes_only", "gini"):
        if suite == "genes_only" and not main_neural:
            return []
        default = {"hamilton": ALL_LAYOUTS, "health": ALL_LAYOUTS, "heldout": ["cousins"],
                   "genes_only": ALL_LAYOUTS, "gini": KIN_LAYOUTS}[suite]
        for layout in lay or default:
            add({"layout": layout}, layout=layout, assign="all", obs_mask=1 if suite == "genes_only" else 0)
    elif suite == "scrambled":
        for layout in lay or ["fours", "pairs"]:
            add({"layout": layout}, layout=layout, assign="all", grouping="scrambled")
    elif suite == "rsweep":
        for level in (0, 8, 16, 32):
            for e in range(args.episodes):
                seed = (base + e) % 2_000_000_000
                jobs.append(dict(suite=suite, cond={"ibd": level}, seed=seed, ticks=args.ticks, policies=policies,
                                 layout="fours", assign="all", grouping="families",
                                 override=sweep_kinship(level, seed)))
    elif suite == "selfish":
        if "second" not in policies:
            return []
        for which in ("main", "second"):
            for layout in lay or ["fours", "pairs"]:
                add({"policy": which, "layout": layout}, layout=layout, assign="self:" + which)
    elif suite == "crossplay":
        for layout in [x for x in (lay or ["fours", "pairs"]) if x in KIN_LAYOUTS or x == "clones"]:
            add({"layout": layout}, layout=layout, assign="crossplay")
    elif suite == "gap":
        add({"layout": "fours"}, layout="fours", assign="all", gap=True)
    return jobs


def _unpack(ep):
    pairs = array.array("i")
    pairs.frombytes(ep["pairs"])
    ep["pairs"] = pairs
    return ep


def run_jobs(jobs, args):
    """Every job in one pool (each worker loads the library and warms its caches once)."""
    if not jobs:
        return []
    started = time.time()
    out = []

    def progress(n):
        if n % max(1, len(jobs) // 20) == 0 or n == len(jobs):
            print(f"  {n}/{len(jobs)} episodes, {time.time() - started:.0f}s", file=sys.stderr)
    if args.workers <= 1:
        _worker_init(args.lib)
        for n, j in enumerate(jobs, 1):
            out.append(_unpack(run_episode(j)))
            progress(n)
    else:
        ctx = multiprocessing.get_context("spawn")
        with ctx.Pool(args.workers, initializer=_worker_init, initargs=(str(args.lib),)) as pool:
            for n, ep in enumerate(pool.imap(run_episode, jobs, chunksize=1), 1):
                out.append(_unpack(ep))
                progress(n)
    return out


def analyse_incentive(eps, args):
    res = {"mixed": {}, "welfare": {}, "gate": {}}
    for layout in sorted({e["cond"]["layout"] for e in eps if e["cond"]["part"] == "mixed"}):
        mixed = [e for e in eps if e["cond"]["part"] == "mixed" and e["cond"]["layout"] == layout]

        def side(e, who):
            return mean([e["R"][s] for s in range(SEATS) if e["policy"][s] == who])
        diffs = [(side(e, "aware"), side(e, "blind")) for e in mixed]
        diffs = [(a, b) for a, b in diffs if a is not None and b is not None]
        res["mixed"][layout] = {
            "aware_R": bootstrap([a for a, _ in diffs], mean, args.bootstrap, 11),
            "blind_R": bootstrap([b for _, b in diffs], mean, args.bootstrap, 12),
            "aware_minus_blind": bootstrap([a - b for a, b in diffs], mean, args.bootstrap, 13),
            "aware_s": mean([mean([e["s"][s] for s in range(SEATS) if e["policy"][s] == "aware"]) for e in mixed]),
            "blind_s": mean([mean([e["s"][s] for s in range(SEATS) if e["policy"][s] == "blind"]) for e in mixed]),
        }
    for layout in ["clones", "fours", "pairs", "strangers"]:
        w = [sum(e["s"]) for e in eps if e["cond"]["part"] == "welfare" and e["cond"]["layout"] == layout]
        res["welfare"][layout] = bootstrap(w, mean, args.bootstrap, 14)
    gate_layouts = {k: (v["aware_minus_blind"]["lo"] is not None and v["aware_minus_blind"]["lo"] > 0)
                    for k, v in res["mixed"].items()}
    cw, sw = res["welfare"]["clones"]["value"], res["welfare"]["strangers"]["value"]
    welfare_ok = cw is not None and sw is not None and cw > sw
    res["gate"] = {"aware_beats_blind": gate_layouts, "clone_welfare_gt_stranger": welfare_ok,
                   "pass": bool(gate_layouts) and all(gate_layouts.values()) and welfare_ok}
    return res


def hamilton_units(eps, key=by_r):
    return [pair_vectors(e, key) for e in eps]


def analyse_hamilton(eps, args):
    """Slope over the kin layouts; strangers (r = 0) and clones (r = 1) reported as controls."""
    res = {"layouts": sorted({e["layout"] for e in eps}, key=ALL_LAYOUTS.index)}
    kin = [e for e in eps if e["layout"] not in ("strangers", "clones")]
    if kin:
        res["curve"] = curve_table(hamilton_units(kin), R_BUCKETS, args.bootstrap, 21, xs=R_BUCKETS)
    for ctl in ("strangers", "clones"):
        c = [e for e in eps if e["layout"] == ctl]
        if c:
            res["control_" + ctl] = curve_table(hamilton_units(c), [0.0 if ctl == "strangers" else 1.0],
                                                args.bootstrap, 22)
    res["per_layout"] = {}
    for layout in res["layouts"]:
        sub = [e for e in eps if e["layout"] == layout]
        res["per_layout"][layout] = curve_table(hamilton_units(sub), R_BUCKETS, args.bootstrap, 23)
    return res


def analyse_scrambled(eps, args):
    res = analyse_hamilton(eps, args)

    def by_group(ep, i, j):
        g = ep["group"]
        return "same group" if g and g[i] >= 0 and g[i] == g[j] else "apart"

    def by_r_group(ep, i, j):
        return f"r={r_bucket(ep['r'][i][j])}/{by_group(ep, i, j)}"
    res["by_group"] = curve_table(hamilton_units(eps, by_group), ["same group", "apart"], args.bootstrap, 31)
    keys = [f"r={b}/{g}" for b in R_BUCKETS for g in ("same group", "apart")]
    res["by_r_group"] = curve_table(hamilton_units(eps, by_r_group), keys, args.bootstrap, 32)
    return res


def analyse_rsweep(eps, args):
    levels = sorted({e["cond"]["ibd"] for e in eps})
    def within(ep, i, j):
        return "within" if any(i in f and j in f for f in ep["families"]) else "across"
    units_by = {lv: hamilton_units([e for e in eps if e["cond"]["ibd"] == lv], within) for lv in levels}
    res = {"levels": levels, "within": {}, "across": {}, "dose_slope": {}}
    for lv in levels:
        t = curve_table(units_by[lv], ["within", "across"], args.bootstrap, 41)
        res["within"][str(lv)] = {m: t[m]["by"]["within"] for m in METRICS}
        res["across"][str(lv)] = {m: t[m]["by"]["across"] for m in METRICS}
    # Dose-response: within-family metric against r = ibd / 32, episodes resampled per level.
    for m, (_, _, _, fn) in METRICS.items():
        pts = [(lv / 32, res["within"][str(lv)][m]["value"]) for lv in levels]
        res["dose_slope"][m] = slope(pts)
    return res


def analyse_health(eps, args):
    res = {"per_layout": {}}
    for layout in sorted({e["layout"] for e in eps}, key=ALL_LAYOUTS.index):
        sub = [e for e in eps if e["layout"] == layout]

        def kin_share(es):
            k = sum(sum(e["kin"]) for e in es)
            o = sum(sum(e["own"]) for e in es)
            return k / (k + o) if (k + o) > 0 else None
        units = hamilton_units(sub, lambda ep, i, j: "hi" if ep["r"][i][j] >= 0.5 else
                               ("zero" if ep["r"][i][j] == 0 else None))

        def pass_rate(us, k):
            v = summed(us, k)
            return v[HEART_PASS] / (v[PAIR_TICKS] / TICKS_PER_MINUTE) if v[PAIR_TICKS] > 0 else None
        hi = pass_rate(units, "hi")
        zero = pass_rate(units, "zero")
        ratio = (hi / zero if zero else (math.inf if hi else None)) if hi is not None and zero is not None else None
        lengths = [e["ticks"] for e in sub]
        deaths = [d for e in sub for d in e["death"] if d >= 0]
        alive_by_minute = []
        for minute in range(0, 7):
            t = minute * TICKS_PER_MINUTE
            alive = [sum(1 for d in e["death"] if d < 0 or d > t) for e in sub if e["ticks"] >= t]
            alive_by_minute.append(mean(alive))
        res["per_layout"][layout] = {
            "kin_share": bootstrap(sub, kin_share, args.bootstrap, 51),
            "heart_pass_per_pair_minute_r_ge_half": hi,
            "heart_pass_per_pair_minute_r_zero": zero,
            "collusion_ratio": None if ratio is None or ratio == math.inf else ratio,
            "collusion_ratio_infinite": ratio == math.inf,
            "collusion_alarm": ratio is not None and ratio > 3,
            "episode_ticks_mean": mean(lengths),
            "episode_ticks_quartiles": [percentile(sorted(lengths), q) for q in (0.25, 0.5, 0.75)],
            "death_tick_mean": mean(deaths),
            "death_tick_quartiles": [percentile(sorted(deaths), q) for q in (0.25, 0.5, 0.75)] if deaths else None,
            "death_histogram_per_minute": [sum(1 for d in deaths if m * TICKS_PER_MINUTE <= d < (m + 1) * TICKS_PER_MINUTE)
                                           for m in range(6)],
            "deaths_per_episode": len(deaths) / len(sub) if sub else None,
            "alive_by_minute": alive_by_minute,
        }
    return res


def analyse_selfish(eps, args, policies):
    if "second" not in policies:
        return {"no_control": True,
                "note": "no control: pass --policy2 (a policy trained with reward = own s_i only)"}
    res = {"no_control": False, "main": policies["main"]["name"], "control": policies["second"]["name"]}
    for which in ("main", "second"):
        sub = [e for e in eps if e["cond"]["policy"] == which]
        kin = [e for e in sub if e["layout"] not in ("strangers", "clones")]
        units = hamilton_units(kin)
        res[which] = {
            "curve": curve_table(units, R_BUCKETS, args.bootstrap, 61, xs=R_BUCKETS),
            "mean_R": bootstrap([mean(e["R"]) for e in sub], mean, args.bootstrap, 62),
            "welfare": bootstrap([sum(e["s"]) for e in sub], mean, args.bootstrap, 63),
        }
    return res


def gini(xs):
    n = len(xs)
    m = sum(xs) / n if n else 0
    if n < 2 or m <= 0:
        return None
    return sum(abs(a - b) for a in xs for b in xs) / (2 * n * n * m)


def analyse_gini(eps, args):
    res = {"per_layout": {}, "hazard": {}}
    for layout in sorted({e["layout"] for e in eps}, key=ALL_LAYOUTS.index):
        sub = [e for e in eps if e["layout"] == layout]
        per_ep = [mean([gini([e["s"][s] for s in f]) for f in e["families"] if len(f) >= 2]) for e in sub]
        res["per_layout"][layout] = bootstrap([g for g in per_ep if g is not None], mean, args.bootstrap, 71)
    # Death hazard per seat-minute against the number of living close kin (r >= .5).
    exposure: dict = {}
    deaths: dict = {}
    by_start: dict = {}
    for e in eps:
        end = e["ticks"]
        d = [x if x >= 0 else end for x in e["death"]]
        for i in range(SEATS):
            close = [j for j in range(SEATS) if j != i and e["r"][i][j] >= 0.5]
            cuts = sorted({0, d[i]} | {d[j] for j in close if d[j] < d[i]})
            for a, b in zip(cuts, cuts[1:]):
                k = min(3, sum(1 for j in close if d[j] > a))
                exposure[k] = exposure.get(k, 0) + (b - a)
            if e["death"][i] >= 0:
                k = min(3, sum(1 for j in close if d[j] > d[i]))
                deaths[k] = deaths.get(k, 0) + 1
            by_start.setdefault(min(3, len(close)), []).append(d[i] / TICKS_PER_MINUTE * 60)
    for k in sorted(exposure):
        minutes = exposure[k] / TICKS_PER_MINUTE
        res["hazard"][str(k)] = {"deaths": deaths.get(k, 0), "seat_minutes": minutes,
                                 "per_minute": deaths.get(k, 0) / minutes if minutes > 0 else None}
    res["survival_seconds_by_close_kin_at_start"] = {str(k): mean(v) for k, v in sorted(by_start.items())}
    return res


def analyse_crossplay(eps, args, policies):
    res = {"second_name": policies.get("second", {}).get("name", "ffa.bas")}
    for focal in ("main", "second"):
        def key(ep, i, j, focal=focal):
            if ep["policy"][i] != focal:
                return None
            same = "same" if ep["policy"][j] == ep["policy"][i] else "other"
            return f"r={r_bucket(ep['r'][i][j])}/{same}"
        keys = [f"r={b}/{s}" for b in R_BUCKETS for s in ("same", "other")]
        units = hamilton_units(eps, key)
        table = curve_table(units, keys, args.bootstrap, 81)
        res[focal] = {m: table[m] for m in HEADLINE}
    return res


def analyse_gap(eps, args):
    def key(ep, i, j):
        if i in ep["weak"]:
            return None
        rb = r_bucket(ep["r"][i][j])
        if rb == 0:
            return "stranger->weak" if j in ep["weak"] else "stranger->full"
        return f"r={rb}/" + ("weak" if j in ep["weak"] else "full")
    units = hamilton_units(eps, key)
    keys = ["r=0.5/weak", "r=0.5/full", "stranger->weak", "stranger->full"]
    table = curve_table(units, keys, args.bootstrap, 91)

    def defend_gap(us):
        a = METRICS["defend"][3](summed(us, "r=0.5/weak"))
        b = METRICS["defend"][3](summed(us, "r=0.5/full"))
        return a - b if a is not None and b is not None else None
    return {"table": {m: table[m] for m in ("defend", "harm", "near")},
            "defend_weak_minus_full": bootstrap(units, defend_gap, args.bootstrap, 92)}


def analyse(suite, eps, args, policies):
    if suite == "genes_only" and policies["main"]["kind"] != "neural":
        return {"skipped": "genes_only needs a neural policy (pw_set_obs_mask zeroes an ffa.v1 "
                           "observation column; BASIC seats do not read observations)"}
    if suite == "selfish" and "second" not in policies:
        return analyse_selfish(eps, args, policies)
    if not eps:
        return {"skipped": "no episodes"}
    if suite == "incentive":
        return analyse_incentive(eps, args)
    if suite in ("hamilton", "heldout", "genes_only"):
        return analyse_hamilton(eps, args)
    if suite in ("selfish", "crossplay"):
        return {"selfish": analyse_selfish, "crossplay": analyse_crossplay}[suite](eps, args, policies)
    return {"scrambled": analyse_scrambled, "rsweep": analyse_rsweep, "health": analyse_health,
            "gini": analyse_gini, "gap": analyse_gap}[suite](eps, args)


# ----------------------------------------------------------------------------------------------
# Report (self-contained HTML, inline SVG)
# ----------------------------------------------------------------------------------------------

CSS = """
:root{--bg:#fbfaf7;--fg:#1d1d1b;--muted:#6b6a64;--line:#dcd9d0;--card:#ffffff;--a:#2f6fb0;--b:#c2562b;
--ok:#2e7d4f;--bad:#b3261e;--ci:rgba(47,111,176,.18)}
@media (prefers-color-scheme: dark){:root{--bg:#171715;--fg:#ecebe6;--muted:#a09e96;--line:#3a3935;
--card:#201f1d;--a:#7fb2e5;--b:#f0936b;--ok:#6fcf97;--bad:#ff8a80;--ci:rgba(127,178,229,.22)}}
body{background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,system-ui,sans-serif;margin:0 auto;
max-width:1100px;padding:24px 16px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:18px;margin:32px 0 8px;border-bottom:1px solid var(--line);
padding-bottom:4px}h3{font-size:15px;margin:18px 0 6px}.muted{color:var(--muted)}
table{border-collapse:collapse;margin:6px 0 14px;font-variant-numeric:tabular-nums;display:block;overflow-x:auto}
th,td{border-bottom:1px solid var(--line);padding:3px 10px;text-align:right;white-space:nowrap}
th:first-child,td:first-child{text-align:left}th{color:var(--muted);font-weight:600}
.charts{display:flex;flex-wrap:wrap;gap:12px}.chart{background:var(--card);border:1px solid var(--line);
border-radius:8px;padding:8px}.chart svg{display:block}.tag{font-size:11px;padding:1px 6px;border-radius:9px;
border:1px solid var(--line);color:var(--muted);margin-left:6px}.pass{color:var(--ok);font-weight:700}
.fail{color:var(--bad);font-weight:700}svg text{fill:var(--fg);font-size:11px}svg .axis{stroke:var(--muted)}
svg .grid{stroke:var(--line)}
"""


def fmt(v, digits=3):
    if v is None:
        return "–"
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, (int,)) and not isinstance(v, bool):
        return str(v)
    if isinstance(v, float) and (math.isinf(v) or math.isnan(v)):
        return "∞" if math.isinf(v) else "–"
    return f"{v:.{digits}g}" if abs(v) >= 1e-3 or v == 0 else f"{v:.2e}"


def ci(b):
    if not isinstance(b, dict):
        return fmt(b)
    if b.get("lo") is None:
        return fmt(b.get("value"))
    return f"{fmt(b['value'])} <span class=muted>[{fmt(b['lo'])}, {fmt(b['hi'])}]</span>"


def svg_curve(title, series, xlabel="r", width=330, height=210, confounded=False, xlabels=None):
    """series: [(label, colour var, [(x, value, lo, hi)])] -> inline SVG line chart with CI bars.
    A label starting with "." draws points only (controls). xlabels: {x: tick text}."""
    pts = [(x, v, lo, hi) for _, _, s in series for x, v, lo, hi in s if v is not None]
    if not pts:
        return f"<div class=chart><b>{html.escape(title)}</b><div class=muted>no data</div></div>"
    ys = [y for _, v, lo, hi in pts for y in (v, lo, hi) if y is not None]
    y0, y1 = min(0.0, min(ys)), max(ys)
    if y1 - y0 < 1e-9:
        y1 = y0 + 1
    xs = [x for x, *_ in pts]
    x0, x1 = (min(xs) - 0.5, max(xs) + 0.5) if xlabels else (min(0.0, min(xs)), max(1.0, max(xs)))
    L, R, T, B = 44, 12, 26, 30

    def X(x):
        return L + (x - x0) / (x1 - x0) * (width - L - R)

    def Y(y):
        return T + (1 - (y - y0) / (y1 - y0)) * (height - T - B)
    out = [f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" '
           f'aria-label="{html.escape(title)}">']
    out.append(f'<text x="{L}" y="14" font-weight="600">{html.escape(title)}'
               + (' (confounded)' if confounded else '') + '</text>')
    for k in range(5):
        y = y0 + (y1 - y0) * k / 4
        out.append(f'<line class=grid x1="{L}" x2="{width - R}" y1="{Y(y):.1f}" y2="{Y(y):.1f}"/>'
                   f'<text x="{L - 4}" y="{Y(y) + 4:.1f}" text-anchor="end">{fmt(y, 2)}</text>')
    for x in sorted(set(xs)):
        tick = xlabels.get(x, "") if xlabels else fmt(x, 2)
        out.append(f'<text x="{X(x):.1f}" y="{height - B + 14}" text-anchor="middle">{html.escape(str(tick))}</text>')
    out.append(f'<text x="{(L + width - R) / 2}" y="{height - 4}" text-anchor="middle" class=muted>{xlabel}</text>')
    out.append(f'<line class=axis x1="{L}" x2="{L}" y1="{T}" y2="{height - B}"/>')
    if y0 < 0 < y1:
        out.append(f'<line class=axis x1="{L}" x2="{width - R}" y1="{Y(0):.1f}" y2="{Y(0):.1f}" stroke-dasharray="3 3"/>')
    for n, (label, colour, s) in enumerate(series):
        s = [p for p in s if p[1] is not None]
        for x, v, lo, hi in s:
            if lo is not None and hi is not None:
                out.append(f'<line x1="{X(x):.1f}" x2="{X(x):.1f}" y1="{Y(lo):.1f}" y2="{Y(hi):.1f}" '
                           f'style="stroke:var({colour})" stroke-width="2" opacity=".5"/>')
        if len(s) > 1 and not label.startswith("."):
            d = " ".join(f"{'M' if k == 0 else 'L'}{X(x):.1f},{Y(v):.1f}" for k, (x, v, _, _) in enumerate(s))
            out.append(f'<path d="{d}" fill="none" style="stroke:var({colour})" stroke-width="2"/>')
        for x, v, _, _ in s:
            out.append(f'<circle cx="{X(x):.1f}" cy="{Y(v):.1f}" r="3.5" style="fill:var({colour})"/>')
        if len(series) > 1:
            out.append(f'<text x="{width - R - 4}" y="{T + 12 + 14 * n}" text-anchor="end" '
                       f'style="fill:var({colour})">{html.escape(label.lstrip("."))}</text>')
    out.append("</svg>")
    return f"<div class=chart>{''.join(out)}</div>"


def svg_bars(title, labels, values, width=330, height=190):
    vals = [v if v is not None else 0 for v in values]
    top = max(vals + [1e-9])
    L, T, B = 44, 26, 34
    bw = (width - L - 10) / max(1, len(vals))
    out = [f'<svg width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img">',
           f'<text x="{L}" y="14" font-weight="600">{html.escape(title)}</text>']
    for k, (lab, v) in enumerate(zip(labels, vals)):
        h = (height - T - B) * v / top
        x = L + k * bw
        out.append(f'<rect x="{x + 3:.1f}" y="{height - B - h:.1f}" width="{bw - 6:.1f}" height="{h:.1f}" '
                   f'style="fill:var(--a)" opacity=".8"/>'
                   f'<text x="{x + bw / 2:.1f}" y="{height - B + 14}" text-anchor="middle">{html.escape(str(lab))}</text>'
                   f'<text x="{x + bw / 2:.1f}" y="{height - B - h - 3:.1f}" text-anchor="middle">{fmt(v, 3)}</text>')
    out.append("</svg>")
    return f"<div class=chart>{''.join(out)}</div>"


def curve_series(table, metric, keys, xs):
    by = table[metric]["by"]
    return [(x, by[str(k)]["value"], by[str(k)]["lo"], by[str(k)]["hi"]) for k, x in zip(keys, xs)]


def metric_table(table, keys, key_label="r", slope_row=True):
    head = "".join(f"<th>{html.escape(str(k))}</th>" for k in keys)
    rows = []
    for m, (label, headline, confounded, _) in METRICS.items():
        if m not in table:
            continue
        tags = (" <span class=tag>headline</span>" if headline else "") + \
               (" <span class=tag>confounded</span>" if confounded else "")
        cells = "".join(f"<td>{ci(table[m]['by'].get(str(k)))}</td>" for k in keys)
        sl = f"<td>{ci(table[m].get('slope'))}</td>" if slope_row and "slope" in table[m] else ""
        rows.append(f"<tr><td>{html.escape(label)}{tags}</td>{cells}{sl}</tr>")
    counts = "".join(f"<td class=muted>{fmt(table['harm']['by'].get(str(k), {}).get('count'))}</td>" for k in keys)
    sl_head = "<th>slope vs r [95% CI]</th>" if slope_row and "slope" in table.get("harm", {}) else ""
    return (f"<table><tr><th>{key_label}</th>{head}{sl_head}</tr>{''.join(rows)}"
            f"<tr><td class=muted>pair-episodes</td>{counts}</tr></table>")


def render_hamilton(res):
    parts = []
    if "curve" in res:
        charts = []
        for m in HEADLINE + [x for x in METRICS if x not in HEADLINE]:
            series = [("kin layouts", "--a", curve_series(res["curve"], m, R_BUCKETS, R_BUCKETS))]
            ctl = []
            for c, x in (("strangers", 0.0), ("clones", 1.0)):
                if "control_" + c in res:
                    b = res["control_" + c][m]["by"][str(x)]
                    ctl.append((x, b["value"], b["lo"], b["hi"]))
            if ctl:
                series.append((".controls (strangers r=0, clones r=1)", "--b", ctl))
            charts.append(svg_curve(METRICS[m][0].split(":")[0], series, confounded=METRICS[m][2]))
        parts.append("<p>Harm and defend are the headline curves. <b>Near and yield are mechanically "
                     "confounded</b>: the territory kin boost makes a relative's ground better for you, so "
                     "closeness and yielding to kin rise with r without any altruism. Yield is the plan's "
                     "1 &minus; contest/yield-opportunity; contest ticks mostly fall outside the uncontested "
                     "opportunity ticks, so it is not bounded to [0, 1] and can go negative.</p>")
        parts.append(f"<div class=charts>{''.join(charts)}</div>")
        parts.append("<h3>Kin layouts pooled: metric by r bucket, slope against r</h3>")
        parts.append(metric_table(res["curve"], R_BUCKETS))
    for c, x in (("strangers", 0.0), ("clones", 1.0)):
        if "control_" + c in res:
            parts.append(f"<h3>Control: {c}</h3>" + metric_table(res["control_" + c], [x], slope_row=False))
    for layout, t in res.get("per_layout", {}).items():
        parts.append(f"<details><summary>per layout: {layout}</summary>{metric_table(t, R_BUCKETS, slope_row=False)}</details>")
    return "".join(parts)


def render(suite, res, meta):
    if "skipped" in res:
        return f"<p class=muted>Skipped: {html.escape(res['skipped'])}</p>"
    if suite == "incentive":
        g = res["gate"]
        verdict = "<span class=pass>PASS</span>" if g["pass"] else "<span class=fail>FAIL</span>"
        rows = "".join(
            f"<tr><td>{k}</td><td>{ci(v['aware_R'])}</td><td>{ci(v['blind_R'])}</td>"
            f"<td>{ci(v['aware_minus_blind'])}</td><td>{fmt(v['aware_s'])}</td><td>{fmt(v['blind_s'])}</td>"
            f"<td>{'<span class=pass>yes</span>' if g['aware_beats_blind'].get(k) else '<span class=fail>no</span>'}</td></tr>"
            for k, v in res["mixed"].items())
        wrows = "".join(f"<tr><td>{k}</td><td>{ci(v)}</td></tr>" for k, v in res["welfare"].items())
        out = [f"<p>Gate: {verdict} &mdash; aware R &gt; blind R with the 95% CI above 0 on every mixed "
               f"layout, and clone welfare &gt; stranger welfare "
               f"({'yes' if g['clone_welfare_gt_stranger'] else 'no'}).</p>"]
        if not g["pass"]:
            out.append("<p class=fail>Do not launch the league as \"kinship working\". Propose a rules tune "
                       "(great-heart bounty or capture radius) as a separate decision.</p>")
        out.append("<h3>Mixed families: ffa.bas (aware) vs ffa_blind.bas (blind)</h3>"
                   "<table><tr><th>layout</th><th>aware R/seat</th><th>blind R/seat</th><th>aware &minus; blind</th>"
                   f"<th>aware raw s</th><th>blind raw s</th><th>CI &gt; 0</th></tr>{rows}</table>")
        out.append("<h3>Welfare: total raw score per episode, every seat on ffa.bas</h3>"
                   f"<table><tr><th>layout</th><th>&Sigma; s [95% CI]</th></tr>{wrows}</table>")
        labels = list(res["welfare"])
        out.append("<div class=charts>" + svg_bars("welfare (Σ s)", labels, [res["welfare"][k]["value"] for k in labels])
                   + svg_curve("aware − blind R per seat [95% CI]", [(".", "--a", [
                       (n, v["aware_minus_blind"]["value"], v["aware_minus_blind"]["lo"], v["aware_minus_blind"]["hi"])
                       for n, v in enumerate(res["mixed"].values())])], xlabel="layout",
                       xlabels=dict(enumerate(res["mixed"]))) + "</div>")
        return "".join(out)
    if suite in ("hamilton", "heldout", "genes_only"):
        pre = "<p>r-to-me zeroed in the observation (pw_set_obs_mask bit 0).</p>" if suite == "genes_only" else ""
        return pre + render_hamilton(res)
    if suite == "scrambled":
        keys = [f"r={b}/{g}" for b in R_BUCKETS for g in ("same group", "apart")]
        return ("<p>Families spawn apart and strangers together. If behaviour follows kinship the r curves "
                "match the unscrambled ones and the spawn-group split is flat.</p>" + render_hamilton(res)
                + "<h3>By spawn group</h3>" + metric_table(res["by_group"], ["same group", "apart"], "spawn", False)
                + "<h3>By r and spawn group</h3>" + metric_table(res["by_r_group"], keys, "r / spawn", False))
    if suite == "rsweep":
        levels = res["levels"]
        charts = []
        for m in HEADLINE + ["kills", "near", "yield"]:
            charts.append(svg_curve(m + " within family", [
                ("within", "--a", [(lv / 32, res["within"][str(lv)][m]["value"], res["within"][str(lv)][m]["lo"],
                                    res["within"][str(lv)][m]["hi"]) for lv in levels]),
                ("across", "--b", [(lv / 32, res["across"][str(lv)][m]["value"], res["across"][str(lv)][m]["lo"],
                                    res["across"][str(lv)][m]["hi"]) for lv in levels])],
                xlabel="within-family r = ibd/32", confounded=METRICS[m][2]))
        rows = "".join(f"<tr><td>{METRICS[m][0]}</td>" + "".join(
            f"<td>{ci(res['within'][str(lv)][m])}</td>" for lv in levels) + f"<td>{fmt(res['dose_slope'][m])}</td></tr>"
            for m in METRICS)
        return (f"<div class=charts>{''.join(charts)}</div><table><tr><th>within family</th>"
                + "".join(f"<th>ibd {lv}</th>" for lv in levels) + f"<th>slope vs r</th></tr>{rows}</table>")
    if suite == "health":
        rows = []
        charts = []
        for layout, v in res["per_layout"].items():
            alarm = '<span class=fail>ALARM</span>' if v["collusion_alarm"] else "ok"
            ratio = "∞" if v["collusion_ratio_infinite"] else fmt(v["collusion_ratio"])
            rows.append(f"<tr><td>{layout}</td><td>{ci(v['kin_share'])}</td>"
                        f"<td>{fmt(v['heart_pass_per_pair_minute_r_ge_half'])}</td>"
                        f"<td>{fmt(v['heart_pass_per_pair_minute_r_zero'])}</td><td>{ratio}</td><td>{alarm}</td>"
                        f"<td>{fmt(v['episode_ticks_mean'])}</td><td>{fmt(v['death_tick_mean'])}</td>"
                        f"<td>{fmt(v['deaths_per_episode'])}</td></tr>")
            charts.append(svg_curve(f"cogs alive by minute: {layout}",
                                    [("", "--a", [(m, a, None, None) for m, a in enumerate(v["alive_by_minute"])])],
                                    xlabel="minute"))
        return ("<table><tr><th>layout</th><th>kin share of return</th><th>heart passes /pair-min, r&ge;.5</th>"
                "<th>r=0</th><th>ratio</th><th>collusion (&gt;3&times;)</th><th>episode ticks</th>"
                f"<th>mean death tick</th><th>deaths/episode</th></tr>{''.join(rows)}</table>"
                f"<div class=charts>{''.join(charts)}</div>")
    if suite == "selfish":
        if res.get("no_control"):
            return f"<p><b>No control.</b> {html.escape(res['note'])}</p>"
        charts = "".join(svg_curve(m, [(meta["policy"], "--a", curve_series(res["main"]["curve"], m, R_BUCKETS, R_BUCKETS)),
                                       (res["control"], "--b", curve_series(res["second"]["curve"], m, R_BUCKETS, R_BUCKETS))])
                         for m in HEADLINE)
        rows = "".join(f"<tr><td>{w}</td><td>{ci(res[w]['mean_R'])}</td><td>{ci(res[w]['welfare'])}</td>"
                       f"<td>{ci(res[w]['curve']['harm']['slope'])}</td><td>{ci(res[w]['curve']['defend']['slope'])}</td></tr>"
                       for w in ("main", "second"))
        return (f"<div class=charts>{charts}</div><table><tr><th>policy</th><th>mean R</th><th>welfare &Sigma;s</th>"
                f"<th>harm slope</th><th>defend slope</th></tr>{rows}</table>")
    if suite == "gini":
        rows = "".join(f"<tr><td>{k}</td><td>{ci(v)}</td></tr>" for k, v in res["per_layout"].items())
        hz = "".join(f"<tr><td>{k}{'+' if k == '3' else ''}</td><td>{v['deaths']}</td><td>{fmt(v['seat_minutes'])}</td>"
                     f"<td>{fmt(v['per_minute'])}</td></tr>" for k, v in res["hazard"].items())
        sv = "".join(f"<tr><td>{k}</td><td>{fmt(v)}</td></tr>" for k, v in res["survival_seconds_by_close_kin_at_start"].items())
        return (f"<h3>Within-family Gini of raw score</h3><table><tr><th>layout</th><th>Gini [95% CI]</th></tr>{rows}</table>"
                "<h3>Death hazard against living close kin (r &ge; .5)</h3><table><tr><th>living close kin</th>"
                f"<th>deaths</th><th>seat-minutes</th><th>deaths per seat-minute</th></tr>{hz}</table>"
                "<h3>Mean survival (s) by close kin at the start</h3><table><tr><th>close kin</th><th>seconds</th></tr>"
                f"{sv}</table>")
    if suite == "crossplay":
        out = [f"<p>Half of every family runs <b>{html.escape(res['second_name'])}</b>. Rows are the focal policy's "
               "view of kin on the same policy vs on the other one.</p>"]
        for focal in ("main", "second"):
            name = meta["policy"] if focal == "main" else res["second_name"]
            charts = []
            for m in HEADLINE:
                t = res[focal][m]["by"]
                charts.append(svg_curve(f"{m} ({name} focal)", [
                    (lab, col, [(b, t[f"r={b}/{lab}"]["value"], t[f"r={b}/{lab}"]["lo"], t[f"r={b}/{lab}"]["hi"])
                                for b in R_BUCKETS]) for lab, col in (("same", "--a"), ("other", "--b"))]))
            out.append(f"<div class=charts>{''.join(charts)}</div>")
        return "".join(out)
    if suite == "gap":
        keys = ["r=0.5/weak", "r=0.5/full", "stranger->weak", "stranger->full"]
        return ("<p>One member of every family deals half damage and fires at most every other window. "
                f"Defend toward the weak sibling minus toward a full-strength sibling: {ci(res['defend_weak_minus_full'])}</p>"
                + metric_table(res["table"], keys, "target", False))
    return f"<pre>{html.escape(json.dumps(res, indent=1)[:4000])}</pre>"


def write_report(out_dir: Path, results: dict, meta: dict):
    sections = []
    for suite, res in results.items():
        sections.append(f"<h2 id={suite}>{suite}</h2>" + render(suite, res, meta))
    nav = " · ".join(f"<a href='#{s}'>{s}</a>" for s in results)
    page = (f"<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport "
            f"content='width=device-width,initial-scale=1'><title>Heartland kin eval</title><style>{CSS}</style>"
            f"</head><body><h1>Heartland kinship eval</h1><p class=muted>policy <b>{html.escape(meta['policy'])}</b>"
            + (f", second <b>{html.escape(meta['policy2'])}</b>" if meta.get("policy2") else "")
            + f" · {meta['episodes']} episodes per condition · {meta['ticks']} ticks max · seed {meta['seed']}"
            f" · bootstrap {meta['bootstrap']} · {html.escape(meta['finished'])}</p><p>{nav}</p>"
            + "".join(sections) + "</body></html>")
    (out_dir / "report.html").write_text(page)


# ----------------------------------------------------------------------------------------------

def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--suite", default="incentive", help="comma-separated suites, or 'all'")
    ap.add_argument("--episodes", type=int, default=200, help="episodes per condition")
    ap.add_argument("--policy", default=str(FFA_BAS), help="BASIC file or neural bundle .zip")
    ap.add_argument("--policy2", default=None, help="second policy (selfish control, crossplay partner)")
    ap.add_argument("--layouts", default=None, help="comma-separated layouts: " + ",".join(ALL_LAYOUTS))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--ticks", type=int, default=FFA_TICKS, help="max ticks per episode (8640 = full match)")
    ap.add_argument("--workers", type=int, default=1)
    ap.add_argument("--bootstrap", type=int, default=1000, help="bootstrap resamples")
    ap.add_argument("--lib", default=None, help="libpaintbot_pw path (built into tmp/ if missing)")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--dump-episodes", action="store_true", help="also write episodes.jsonl (raw counters)")
    args = ap.parse_args(argv)
    args.suites = SUITES if args.suite == "all" else [s.strip() for s in args.suite.split(",") if s.strip()]
    for s in args.suites:
        if s not in SUITES:
            ap.error(f"unknown suite {s!r}; choose from {', '.join(SUITES)}")
    if args.layouts:
        args.layouts = [x.strip() for x in args.layouts.split(",") if x.strip()]
        for x in args.layouts:
            if x not in LAYOUTS:
                ap.error(f"unknown layout {x!r}")
    if not 1 <= args.ticks <= FFA_TICKS:
        ap.error("--ticks must be 1..8640")
    return args


def main(argv=None):
    args = parse_args(argv)
    lib = Path(args.lib) if args.lib else default_lib_path()
    if not lib.exists():
        if args.lib:
            raise SystemExit(f"{lib}: no such library")
        print(f"building {lib} ...", file=sys.stderr)
        build_lib(lib)
    args.lib = str(lib.resolve())
    policies = {"main": policy_spec(args.policy),
                "aware": policy_spec(FFA_BAS), "blind": policy_spec(BLIND_BAS)}
    if args.policy2:
        policies["second"] = policy_spec(args.policy2)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    suite_policies, jobs = {}, []
    for suite in args.suites:
        sp = dict(policies)
        if suite == "crossplay" and "second" not in sp:
            sp["second"] = policy_spec(FFA_BAS)
        suite_policies[suite] = sp
        for j in make_jobs(suite, args, sp):
            if j["assign"] == "welfare":
                j["assign"] = "all"
                j["policies"] = dict(j["policies"], main=policies["aware"])
            elif j["assign"].startswith("self:"):
                j["policies"] = dict(j["policies"], main=sp[j["assign"][5:]])
                j["assign"] = "all"
            jobs.append(j)
    print(f"{len(jobs)} episodes: " + ", ".join(
        f"{s} {sum(1 for j in jobs if j['suite'] == s)}" for s in args.suites), file=sys.stderr)
    episodes = run_jobs(jobs, args)
    results = {}
    for suite in args.suites:
        eps = [e for e in episodes if e["suite"] == suite]
        failed = sorted({(e["policy"][s], e["status"][s]) for e in eps for s in range(SEATS)
                         if e["status"][s] not in (0, 1)})
        res = analyse(suite, eps, args, suite_policies[suite])
        res["episodes"] = len(eps)
        if failed:
            res["seat_failures"] = [list(x) for x in failed]
        if eps:
            res["mean_episode_ticks"] = mean([e["ticks"] for e in eps])
        results[suite] = res
    if args.dump_episodes:
        with open(out_dir / "episodes.jsonl", "w") as dump:
            for e in episodes:
                dump.write(json.dumps(dict(e, pairs=list(e["pairs"]))) + "\n")
    meta = {"policy": policies["main"]["name"], "policy2": policies.get("second", {}).get("name"),
            "episodes": args.episodes, "ticks": args.ticks, "seed": args.seed, "bootstrap": args.bootstrap,
            "suites": args.suites, "layouts": args.layouts, "finished": time.strftime("%Y-%m-%d %H:%M:%S")}
    (out_dir / "results.json").write_text(json.dumps({"meta": meta, "results": results}, indent=1,
                                                     default=lambda o: None))
    write_report(out_dir, results, meta)
    print(f"wrote {out_dir / 'report.html'} and {out_dir / 'results.json'}", file=sys.stderr)
    if "incentive" in results and "gate" in results["incentive"]:
        g = results["incentive"]["gate"]
        print("incentive gate: " + ("PASS" if g["pass"] else "FAIL"), file=sys.stderr)
    return results


if __name__ == "__main__":
    main()
