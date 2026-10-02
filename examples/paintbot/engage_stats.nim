## Engagement diagnostics per side for team replays (local analysis instrument).
##
##     engage_stats <replay.raw> [...]
##
## Initiative: when an enemy pair first becomes visible in either direction, which side saw first.
## Hits on an unaware victim: the victim could not see the attacker the tick the hit landed.
## Stationary share: alive cog-ticks with no position change. Facing share: alive cog-ticks with
## a visible enemy whose aim points within 30 degrees of the nearest visible enemy.
import std/[os, strformat, math]
import game, sim

type SideStats = object
  firstSight, mutualStart, unawareHits, hits, stillTicks, aliveTicks, seeTicks, facingTicks: int
  seenByTicks, exposedTicks: int
  combatTicks, linMiss, stayMiss: int
  releases, ducked, nearCoverCombat, highCombat: int
  formSamples: int
  depth, width, gunsOnVictim, victimSamples: float
  blindTicks, blindToEnemy, blindToWalk, blindToEnemyHome, blindLos, blindLosInCone: int

var stats: array[2, SideStats]

proc report(path: string) =
  let r = loadRecording(path)
  var w = newWorld(r.seed)
  var prevVis: array[16, array[16, bool]]
  var hist: seq[seq[Point]]
  var pendingDuck: seq[tuple[t, shooter: int]]
  var seen: seq[seq[bool]]
  observeShot = proc(tick: int32, slot: int) =
    inc stats[team(slot)].releases
    pendingDuck.add (hist.len, slot)
  observeHit = proc(tick: int32, victim, attacker: int, pos: Point) =
    if team(victim) == team(attacker): return
    inc stats[team(attacker)].hits
    if not visible(w, victim, attacker): inc stats[team(attacker)].unawareHits
  for f in r.frames:
    let prev = w.cogs
    w.step(f.commands, replayRulesVersion)
    var vis: array[16, array[16, bool]]
    for i in 0..<16:
      if w.cogs[i].hp <= 0: continue
      for j in 0..<16:
        if team(j) != team(i) and w.cogs[j].hp > 0: vis[i][j] = visible(w, i, j)
    for i in 0..<16:
      if w.cogs[i].hp <= 0: continue
      let s = team(i)
      inc stats[s].aliveTicks
      if w.cogs[i].pos == prev[i].pos: inc stats[s].stillTicks
      var seesAny, seenAny = false
      var best = -1
      var bestD = int64.high
      for j in 0..<16:
        if team(j) == s or w.cogs[j].hp <= 0: continue
        if vis[j][i]: seenAny = true
        if vis[i][j]:
          seesAny = true
          let d = distance2(w.cogs[i].pos, w.cogs[j].pos)
          if d < bestD: bestD = d; best = j
        if j > i:
          let before = prevVis[i][j] or prevVis[j][i]
          let now = vis[i][j] or vis[j][i]
          if now and not before:
            inc stats[s].mutualStart
            inc stats[1 - s].mutualStart
            if vis[i][j] and not vis[j][i]: inc stats[s].firstSight
            elif vis[j][i] and not vis[i][j]: inc stats[1 - s].firstSight
      if seenAny: inc stats[s].exposedTicks
      if seenAny and not seesAny: inc stats[s].seenByTicks
      if best < 0:
        inc stats[s].blindTicks
        let c = w.cogs[i]
        let ax = float(c.aim.x - c.pos.x); let az = float(c.aim.z - c.pos.z)
        proc within(ax, az, bx, bz: float, deg: float): bool =
          let n = sqrt(ax*ax + az*az) * sqrt(bx*bx + bz*bz)
          n > 0 and (ax*bx + az*bz) / n > cos(deg * PI / 180)
        var ne = -1
        var nd = int64.high
        for j in 0..<16:
          if team(j) != s and w.cogs[j].hp > 0:
            let d = distance2(c.pos, w.cogs[j].pos)
            if d < nd: nd = d; ne = j
        if ne >= 0 and within(ax, az, float(w.cogs[ne].pos.x - c.pos.x), float(w.cogs[ne].pos.z - c.pos.z), 60): inc stats[s].blindToEnemy
        if within(ax, az, float(c.pos.x - prev[i].pos.x), float(c.pos.z - prev[i].pos.z), 30): inc stats[s].blindToWalk
        let eh = home(1 - s)
        if within(ax, az, float(eh.x - c.pos.x), float(eh.z - c.pos.z), 60): inc stats[s].blindToEnemyHome
        for j in 0..<16:
          if team(j) != s and w.cogs[j].hp > 0 and distance2(c.pos, w.cogs[j].pos) < 5250'i64*5250 and w.lineClear(c.pos, w.cogs[j].pos):
            inc stats[s].blindLos
            break
      if best >= 0:
        inc stats[s].seeTicks
        let c = w.cogs[i]
        let ax = float(c.aim.x - c.pos.x); let az = float(c.aim.z - c.pos.z)
        let bx = float(w.cogs[best].pos.x - c.pos.x); let bz = float(w.cogs[best].pos.z - c.pos.z)
        let n = sqrt(ax*ax + az*az) * sqrt(bx*bx + bz*bz)
        if n > 0 and (ax*bx + az*bz) / n > cos(30.0 * PI / 180): inc stats[s].facingTicks
    prevVis = vis
    var pos: seq[Point]
    var sees: seq[bool]
    for i in 0..<16:
      pos.add w.cogs[i].pos
      var any = false
      for j in 0..<16:
        if vis[i][j]: any = true
      sees.add any and w.cogs[i].hp > 0
    hist.add pos
    if w.tick mod 24 == 0:
      for side in 0..1:
        let eh = home(1 - side)
        var cx, cz, n = 0.0
        for i in 0..<16:
          if team(i) == side and w.cogs[i].hp > 0: cx += float(w.cogs[i].pos.x); cz += float(w.cogs[i].pos.z); n += 1
        if n < 3: continue
        cx /= n; cz /= n
        let ax = float(eh.x) - cx; let az = float(eh.z) - cz; let al = sqrt(ax*ax + az*az)
        if al == 0: continue
        var dd, ww = 0.0
        for i in 0..<16:
          if team(i) == side and w.cogs[i].hp > 0:
            let rx = float(w.cogs[i].pos.x) - cx; let rz = float(w.cogs[i].pos.z) - cz
            dd += abs(rx*ax + rz*az) / al; ww += abs(rx*az - rz*ax) / al
        stats[side].depth += dd / n / 100; stats[side].width += ww / n / 100; inc stats[side].formSamples
    # Guns on each visible enemy: for every enemy seen by this side, how many of the side's cogs see it.
    if w.tick mod 6 == 0:
      for side in 0..1:
        for j in 0..<16:
          if team(j) == side or w.cogs[j].hp <= 0: continue
          var k = 0
          for i in 0..<16:
            if team(i) == side and vis[i][j]: inc k
          if k > 0: stats[side].gunsOnVictim += k.float; stats[side].victimSamples += 1
    # A release counts as ducked if within 12 ticks no enemy can see the shooter for a tick.
    var keep: seq[tuple[t, shooter: int]]
    for d in pendingDuck:
      if w.cogs[d.shooter].hp <= 0: continue
      var seenBy = false
      for j in 0..<16:
        if team(j) != team(d.shooter) and vis[j][d.shooter]: seenBy = true
      if not seenBy: inc stats[team(d.shooter)].ducked
      elif hist.len - d.t < 12: keep.add d
    pendingDuck = keep
    seen.add sees
    let t = hist.len - 1
    if t >= 6:
      for i in 0..<16:
        # Cog i was in combat at t-5 (saw an enemy) and alive across the window.
        if not seen[t-5][i] or w.cogs[i].hp <= 0: continue
        let p0 = hist[t-5][i]; let pm = hist[t-6][i]; let p5 = hist[t][i]
        if distance2(p0, pm) > 40000 or distance2(p5, p0) > 40000: continue  # respawn jump
        let lin = Point(x: p0.x + 5*(p0.x - pm.x), z: p0.z + 5*(p0.z - pm.z))
        inc stats[team(i)].combatTicks
        if distance2(p5, lin) > 55*55: inc stats[team(i)].linMiss
        if distance2(p5, p0) > 55*55: inc stats[team(i)].stayMiss
  observeHit = nil

when isMainModule:
  if paramCount() < 1: quit "usage: engage_stats <replay.raw> [...]"
  for i in 1..paramCount(): report(paramStr(i))
  for s in 0..1:
    let x = stats[s]
    echo &"{(if s == 0: \"Ember/even\" else: \"Azure/odd \")} first-sight {x.firstSight}/{x.mutualStart div 2} " &
         &"unaware-victim hits {x.unawareHits}/{x.hits}  still {x.stillTicks / max(x.aliveTicks, 1):.2f}  " &
         &"facing-nearest {x.facingTicks / max(x.seeTicks, 1):.2f}  exposed {x.exposedTicks / max(x.aliveTicks, 1):.2f} " &
         &"seen-blind {x.seenByTicks / max(x.aliveTicks, 1):.2f}"
    echo &"   in combat: linear-lead prediction off by >55cm {x.linMiss / max(x.combatTicks, 1):.2f}, aim-at-current off >55cm {x.stayMiss / max(x.combatTicks, 1):.2f}"
    echo &"   releases {x.releases}, ducked out of all enemy sight within 12 ticks {x.ducked / max(x.releases, 1):.2f}"
    echo &"   formation depth {x.depth / max(x.formSamples, 1).float:.1f} m width {x.width / max(x.formSamples, 1).float:.1f} m; mean own cogs seeing each seen enemy {x.gunsOnVictim / max(x.victimSamples, 1):.2f}"
    echo &"   blind ticks {x.blindTicks / max(x.aliveTicks, 1):.2f}: aim within 60deg of nearest enemy {x.blindToEnemy / max(x.blindTicks, 1):.2f}, " &
         &"along walk {x.blindToWalk / max(x.blindTicks, 1):.2f}, toward enemy home {x.blindToEnemyHome / max(x.blindTicks, 1):.2f}, " &
         &"enemy in range with clear line but unseen {x.blindLos / max(x.blindTicks, 1):.2f}"
