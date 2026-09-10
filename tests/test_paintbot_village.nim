import std/[unittest, sets, deques]
import ../examples/paintbot/sim

suite "Gnome village arena":
  test "solid cover is mirrored, separate, and clear of spawns and pickups":
    visionRulesVersion = 7
    for seed in [1'i32, 42, 2026, 99171]:
      let w = newWorld(seed)
      check w.cover.len == 15
      for i, c in w.cover:
        check c.x > 0 and c.z > 0 and c.x+c.w < Width and c.z+c.h < Height
        check Cover(x: Width.int32-c.x-c.w, z: Height.int32-c.z-c.h,
            w: c.w, h: c.h) in w.cover
        for j in 0..<i:
          let d = w.cover[j]
          check c.x+c.w <= d.x or d.x+d.w <= c.x or
              c.z+c.h <= d.z or d.z+d.h <= c.z
      for c in w.cogs: check not w.blocked(c.pos)
      for p in w.pickups: check not w.blocked(p.pos)
      for t in w.trenches:
        for c in w.cover:
          check t.x+t.w <= c.x or c.x+c.w <= t.x or
              t.z+t.h <= c.z or c.z+c.h <= t.z
  test "both hearts and every equipment pickup are connected through walkable lanes":
    visionRulesVersion = 7
    let w = newWorld(2026)
    var visited: HashSet[(int, int)]
    var queue: Deque[(int, int)]
    let start = (home(0).x.int div 50, home(0).z.int div 50)
    visited.incl start
    queue.addLast start
    while queue.len > 0:
      let p = queue.popFirst()
      for d in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let q = (p[0]+d[0], p[1]+d[1])
        if q notin visited and not w.blocked(point(q[0]*50, q[1]*50)):
          visited.incl q
          queue.addLast q
    check (home(1).x.int div 50, home(1).z.int div 50) in visited
    for pickup in w.pickups:
      check (pickup.pos.x.int div 50, pickup.pos.z.int div 50) in visited
