## Dump per-side positions (every 12 ticks), shot releases, hits and downs from team replays as CSV.
##
##     dump_positions <replay.raw> [...] > out.csv
##
## Columns: file,kind,tick,slot,side,x,z,height,extra. kind is pos | shot | hit (shooter position,
## extra = victim) | down (victim position). Coordinates are the world frame; mirror Azure (odd) with
## (Width - x, Height - z) to compare sides.
import std/os
import game, sim, topography

var w: World
var fi: int
proc row(kind: string, slot: int, p: Point, extra: int) =
  echo fi, ",", kind, ",", w.tick, ",", slot, ",", team(slot), ",", p.x, ",", p.z, ",", terrainHeight(p.x.int, p.z.int), ",", extra

proc dump(path: string) =
  let r = loadRecording(path)
  w = newWorld(r.seed)
  observeShot = proc(tick: int32, slot: int) = row("shot", slot, w.cogs[slot].pos, -1)
  observeHit = proc(tick: int32, victim, attacker: int, pos: Point) =
    if team(victim) != team(attacker): row("hit", attacker, w.cogs[attacker].pos, victim)
  for f in r.frames:
    let prev = w.cogs
    w.step(f.commands, replayRulesVersion)
    for i, c in w.cogs:
      if c.hp == 0 and prev[i].hp > 0: row("down", i, prev[i].pos, -1)
      if c.hp > 0 and w.tick mod 12 == 0: row("pos", i, c.pos, c.hp)
      if c.hp > 0 and getEnv("PW_DUMP_EVERY") != "":
        echo fi, ",tick,", w.tick, ",", i, ",", team(i), ",", c.pos.x, ",", c.pos.z, ",", c.aim.x, ",", c.aim.z
    if w.tick mod 48 == 0:
      for k, h in w.controlHearts:
        echo fi, ",heart,", w.tick, ",", k, ",", h.owner, ",", h.pos.x, ",", h.pos.z, ",0,0"
  observeShot = nil
  observeHit = nil

when isMainModule:
  echo "file,kind,tick,slot,side,x,z,height,extra"
  for i in 1..paramCount():
    fi = i
    dump(paramStr(i))
