import std/unittest
import polyworld/rngs
import ../examples/paintbot/sim

suite "Heart-based spawns":
  setup:
    visionRulesVersion = 24

  test "initial spawns are near owned hearts and do not overlap":
    for seed in 1..10:
      let w = newWorld(seed.int32)
      for i, cog in w.cogs:
        check cog.hp == 3
        var nearOwned = false
        for heart in w.controlHearts:
          if heart.owner == team(i).int32 and
              distance2(cog.pos, heart.pos) <= HeartSpawnRadius*HeartSpawnRadius:
            nearOwned = true
        check nearOwned
        check not w.blocked(cog.pos)
        for j in 0..<i:
          check distance2(cog.pos, w.cogs[j].pos) >= 4*Radius*Radius

  test "softmax favors the sum of distances and ignores self, enemies and dead cogs":
    var w: World
    w.rng = initRng(42)
    w.controlHearts = @[
      ControlHeart(pos: point(0, 0), owner: 0),
      ControlHeart(pos: point(1000, 0), owner: 0),
      ControlHeart(pos: point(100000, 0), owner: 1),
      ControlHeart(pos: point(100000, 0), owner: -1)]
    w.cogs[0] = Cog(hp: 3, pos: point(100000, 0))
    w.cogs[1] = Cog(hp: 3, pos: point(100000, 0))
    w.cogs[2] = Cog(hp: 3, pos: point(0, 0))
    w.cogs[4] = Cog(hp: 3, pos: point(0, 0))
    w.cogs[6] = Cog(hp: 0, pos: point(100000, 0))
    var far = 0
    for trial in 0..<10000:
      let chosen = w.sampleSpawnHeart(0)
      check chosen in 0..1
      if chosen == 1: inc far
    # exp(2) / (1+exp(2)) = 88.08%; averaging would yield only 73.1%.
    check far in 8600..9000
    w.cogs[2].hp = 0
    w.cogs[4].hp = 0
    far = 0
    for trial in 0..<10000:
      if w.sampleSpawnHeart(0) == 1: inc far
    check far in 4800..5200
    w.controlHearts[0].owner = 1
    w.controlHearts[1].owner = -1
    check w.sampleSpawnHeart(0) == -1

  test "respawn follows current heart ownership":
    var w = newWorld(42)
    for heart in w.controlHearts.mitems: heart.owner = -1
    w.controlHearts[2].owner = 0
    w.cogs[0].hp = 0
    w.cogs[0].respawn = 1
    var commands: array[Seats, Command]
    w.step(commands)
    check w.cogs[0].hp == 3
    check distance2(w.cogs[0].pos, w.controlHearts[2].pos) <= HeartSpawnRadius*HeartSpawnRadius
    check not w.blocked(w.cogs[0].pos)

  test "blocked heart retries instead of spawning elsewhere":
    var w = newWorld(42)
    for heart in w.controlHearts.mitems: heart.owner = -1
    w.controlHearts[0].owner = 0
    let p = w.controlHearts[0].pos
    w.cover.add Cover(x: p.x-1000, z: p.z-1000, w: 2000, h: 2000)
    w.cogs[0].hp = 0
    w.cogs[0].respawn = 1
    var commands: array[Seats, Command]
    w.step(commands)
    check w.cogs[0].hp == 0
    check w.equipment[0].lives == 4

  test "no owned hearts retains endzone fallback":
    var w = newWorld(42)
    for heart in w.controlHearts.mitems: heart.owner = -1
    w.cogs[0].hp = 0
    w.cogs[0].respawn = 1
    var commands: array[Seats, Command]
    w.step(commands)
    check w.cogs[0].hp == 3
    check w.cogs[0].pos.x in 150'i32..800'i32
