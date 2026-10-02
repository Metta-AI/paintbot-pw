## Per-side combat diagnostics for Paintbot PW team replays (local analysis instrument).
##
##     combat_stats <replay.raw> [...]
##
## Re-simulates each replay and reports, per side (Ember = even slots, Azure = odd): shots, enemy
## hits and accuracy, shots fired standing still and their accuracy, median attacker-victim
## distance and attacker height advantage at hits, downs, and at each down the distance to the
## nearest living ally, enemies within gun range and in-water share. Aggregates over all files.
import std/[algorithm, math, os, strformat]
import game, sim, topography, seat_view

const Range = 5250

type SideStats = object
  shots, stillShots, hits, stillHits, ffHits, downs, wetDowns, armorPicks, medPicks, grenThrows: int
  hitDist, hitHeight, downAllyDist, downFoes, downAllies: seq[float]
  spread: seq[float]
  aimedMoving, aimedMovingHit, aimedStill, aimedStillHit: int
  aTrench, aBlocked, aPerpOk, aPerpMiss: int
  perp: seq[float]
  vWindup, vCooldown, vStillOther, vMovingSeeing, vMovingBlind: int

proc median(xs: seq[float]): float =
  if xs.len == 0: return 0
  var s = xs
  s.sort
  s[s.len div 2]

proc mean(xs: seq[float]): float =
  if xs.len == 0: 0.0 else: xs.sum / xs.len.float

proc wet(p: Point): bool =
  riverBlend(p.x.int, p.z.int) > 0 and terrainHeight(p.x.int, p.z.int) < RiverWaterHeight

var stats: array[2, SideStats]

proc report(path: string) =
  let r = loadRecording(path)
  var w = newWorld(r.seed)
  var prev = w.cogs
  var prevEq = w.equipment
  var shotStill: seq[bool] = newSeq[bool](Seats)
  var aimed: seq[int] = newSeq[int](Seats)
  observeShot = proc(tick: int32, slot: int) =
    let side = team(slot)
    inc stats[side].shots
    shotStill[slot] = w.cogs[slot].pos == prev[slot].pos
    if shotStill[slot]: inc stats[side].stillShots
    # Intended target: the enemy closest in angle to the locked aim, within 6 degrees.
    let g = w.equipment[slot].gunAim
    let gl = sqrt(float(g.x)*float(g.x) + float(g.z)*float(g.z))
    var best = -1
    var bestCos = cos(6.0 * PI / 180)
    for j in 0..<Seats:
      if team(j) == side or w.cogs[j].hp <= 0: continue
      let bx = float(w.cogs[j].pos.x - w.cogs[slot].pos.x); let bz = float(w.cogs[j].pos.z - w.cogs[slot].pos.z)
      let bl = sqrt(bx*bx + bz*bz)
      if gl == 0 or bl == 0 or bl > 5250: continue
      let c = (float(g.x)*bx + float(g.z)*bz) / gl / bl
      if c > bestCos: bestCos = c; best = j
    aimed[slot] = best
    if best >= 0:
      let o = w.cogs[slot].pos; let t = w.cogs[best].pos
      let tr = trenchAt(w, t)
      if tr >= 0 and tr != trenchAt(w, o): inc stats[side].aTrench
      if not w.lineClear(o, t): inc stats[side].aBlocked
      else:
        let bx = float(t.x - o.x); let bz = float(t.z - o.z)
        let pd = abs(float(g.x)*bz - float(g.z)*bx) / gl
        stats[side].perp.add pd
        if pd <= 55: inc stats[side].aPerpOk else: inc stats[side].aPerpMiss
    if best >= 0:
      if w.cogs[best].pos == prev[best].pos: inc stats[side].aimedStill
      else: inc stats[side].aimedMoving
  observeHit = proc(tick: int32, victim, attacker: int, pos: Point) =
    let side = team(attacker)
    if team(victim) == side:
      inc stats[side].ffHits
      return
    inc stats[side].hits
    # Victim state at the hit (counted on the victim's side).
    let vs = team(victim)
    if w.equipment[victim].windup > 0: inc stats[vs].vWindup
    elif w.cogs[victim].cooldown > 0: inc stats[vs].vCooldown
    elif w.cogs[victim].pos == prev[victim].pos: inc stats[vs].vStillOther
    else:
      var sees = false
      for j in 0..<Seats:
        if team(j) != vs and w.cogs[j].hp > 0 and visible(w, victim, j): sees = true
      if sees: inc stats[vs].vMovingSeeing else: inc stats[vs].vMovingBlind
    if shotStill[attacker]: inc stats[side].stillHits
    if aimed[attacker] == victim:
      if w.cogs[victim].pos == prev[victim].pos: inc stats[side].aimedStillHit
      else: inc stats[side].aimedMovingHit
    let a = w.cogs[attacker].pos
    stats[side].hitDist.add sqrt(distance2(a, pos).float) / 100
    stats[side].hitHeight.add (terrainHeight(a.x.int, a.z.int) - terrainHeight(pos.x.int, pos.z.int)).float
  for f in r.frames:
    prev = w.cogs
    prevEq = w.equipment
    w.step(f.commands, replayRulesVersion)
    for i, c in w.cogs:
      let side = team(i)
      if w.equipment[i].armor > prevEq[i].armor: inc stats[side].armorPicks
      if c.hp > prev[i].hp and prev[i].hp > 0: inc stats[side].medPicks
      if c.hp == 0 and prev[i].hp > 0:
        inc stats[side].downs
        if wet(prev[i].pos): inc stats[side].wetDowns
        var nearest = 1e9
        var foes, allies = 0
        for j, o in w.cogs:
          if j == i or o.hp <= 0: continue
          let d = sqrt(distance2(o.pos, prev[i].pos).float)
          if team(j) == side:
            nearest = min(nearest, d)
            if d < 2000: inc allies
          elif d < Range: inc foes
        if nearest < 1e9: stats[side].downAllyDist.add nearest / 100
        stats[side].downFoes.add foes.float
        stats[side].downAllies.add allies.float
    if w.tick mod 48 == 0:
      for side in 0..1:
        var cx, cz, n = 0.0
        for i, c in w.cogs:
          if team(i) == side and c.hp > 0:
            cx += c.pos.x.float; cz += c.pos.z.float; n += 1
        if n >= 2:
          var d = 0.0
          for i, c in w.cogs:
            if team(i) == side and c.hp > 0:
              d += sqrt((c.pos.x.float - cx / n)^2 + (c.pos.z.float - cz / n)^2)
          stats[side].spread.add d / n / 100
    for g in w.grenades:
      if g.releasedAt == w.tick - 1: inc stats[team(g.owner.int)].grenThrows
  observeShot = nil
  observeHit = nil

when isMainModule:
  if paramCount() < 1: quit "usage: combat_stats <replay.raw> [...]"
  for i in 1..paramCount(): report(paramStr(i))
  for side in 0..1:
    let s = stats[side]
    echo &"{(if side == 0: \"Ember/even\" else: \"Azure/odd \")} files={paramCount()}"
    echo &"  shots {s.shots} hits {s.hits} acc {s.hits / max(s.shots, 1):.3f}  still-shot share " &
         &"{s.stillShots / max(s.shots, 1):.2f} still acc {s.stillHits / max(s.stillShots, 1):.3f} " &
         &"moving acc {(s.hits - s.stillHits) / max(s.shots - s.stillShots, 1):.3f}  ff {s.ffHits}"
    echo &"  hit dist median {median(s.hitDist):.1f} m  height adv mean {mean(s.hitHeight):.0f} cm  " &
         &"grenade throws {s.grenThrows}  armor {s.armorPicks}  heals {s.medPicks}"
    echo &"  downs {s.downs} (wet {s.wetDowns})  at down: nearest ally median {median(s.downAllyDist):.1f} m, " &
         &"foes in range mean {mean(s.downFoes):.2f}, allies <20m mean {mean(s.downAllies):.2f}  " &
         &"team spread mean {mean(s.spread):.1f} m"
    echo &"  aimed shots: at moving target {s.aimedMoving} hit {s.aimedMovingHit / max(s.aimedMoving, 1):.3f}; " &
         &"at still target {s.aimedStill} hit {s.aimedStillHit / max(s.aimedStill, 1):.3f}"
    let vt = max(s.vWindup + s.vCooldown + s.vStillOther + s.vMovingSeeing + s.vMovingBlind, 1)
    echo &"  hits TAKEN by state: in windup {s.vWindup / vt:.2f}, gun cooling {s.vCooldown / vt:.2f}, still other {s.vStillOther / vt:.2f}, moving seeing enemy {s.vMovingSeeing / vt:.2f}, moving blind {s.vMovingBlind / vt:.2f} (n={vt})"
    echo &"  aimed: target in other trench {s.aTrench}, wall-blocked {s.aBlocked}, clear line ray-perp<=55cm {s.aPerpOk} >55cm {s.aPerpMiss} (median perp {median(s.perp):.0f} cm)"
