import std/[unittest, sets, os, tempfiles]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game, bots, analysis]

suite "Rotating big hearts":
  setup:
    visionRulesVersion = 26
    replayRulesVersion = 26

  test "first heart appears at exactly 30 seconds and rotates at 60":
    var w = newWorld(2026)
    var commands: array[Seats,Command]
    for tick in 0..<719: w.step(commands)
    check w.bigHeart == -1
    check w.scoreTicks == [719'i32,719'i32]
    w.step(commands)
    require w.bigHeart >= 0
    check w.tick == 720
    check w.scoreTicks == [720'i32,720'i32]
    let first = w.bigHeart
    for tick in 0..<719: w.step(commands)
    check w.bigHeart == first
    w.step(commands)
    check w.tick == 1440
    check w.bigHeart != first
    check w.heartPoints(first) == 1
    check w.heartPoints(w.bigHeart) == 5

  test "selection never repeats and stops when all ten have been used":
    for seed in 1..8:
      var w = newWorld(seed.int32,10000)
      var selected: HashSet[int32]
      for round in 1..10:
        w.tick = int32(round*BigHeartInterval)
        w.updateBigHeart()
        require w.bigHeart in 0'i32..<10'i32
        check w.bigHeart notin selected
        selected.incl(w.bigHeart)
        var bigCount = 0
        for i in 0..<10:
          if w.heartPoints(i) == 5: inc bigCount
        check bigCount == 1
        let chosen = w.bigHeart
        w.updateBigHeart()
        check w.bigHeart == chosen
      check selected.len == 10
      w.tick = 11*BigHeartInterval
      w.updateBigHeart()
      check w.bigHeart == -1
      for i in 0..<10: check w.heartPoints(i) == 1

  test "seeded choices are repeatable but vary between games":
    var firstChoices: HashSet[int32]
    for seed in 1..16:
      var a = newWorld(seed.int32)
      var b = newWorld(seed.int32)
      a.tick = BigHeartInterval
      b.tick = BigHeartInterval
      a.updateBigHeart()
      b.updateBigHeart()
      check a.bigHeart == b.bigHeart
      check a.stateHash() == b.stateHash()
      firstChoices.incl(a.bigHeart)
    check firstChoices.len > 1

  test "owned big heart earns five total points per second, neutral earns none":
    for owner in [-1'i32,0'i32,1'i32]:
      var w = newWorld(2026)
      w.tick = BigHeartInterval
      w.updateBigHeart()
      for heart in w.controlHearts.mitems: heart.owner = -1
      w.controlHearts[w.bigHeart].owner = owner
      var commands: array[Seats,Command]
      for tick in 0..<TickRate: w.step(commands)
      check w.scoreTicks == (if owner == 0: [120'i32,0'i32] elif owner == 1: [0'i32,120'i32] else: [0'i32,0'i32])

  test "income follows ownership without moving the big designation":
    var w = newWorld(2026)
    w.tick = BigHeartInterval
    w.updateBigHeart()
    let big = w.bigHeart
    for heart in w.controlHearts.mitems: heart.owner = -1
    w.controlHearts[big].owner = 0
    var commands: array[Seats,Command]
    w.step(commands)
    check w.scoreTicks == [5'i32,0'i32]
    w.controlHearts[big].owner = 1
    w.step(commands)
    check w.scoreTicks == [5'i32,5'i32]
    check w.bigHeart == big

  test "elimination credits the future 5-point windows exactly once":
    var w = newWorld(2026)
    # 10 ordinary points/s for 300s plus 4 extra points/s for the final 270s.
    check w.remainingHeartPoints() == (300*10+270*4)*TickRate
    w.tick = 750
    check w.remainingHeartPoints() == (10+4)*(MatchTicks-750)
    var commands: array[Seats,Command]
    for i in 0..<Seats:
      if team(i) == 1:
        w.cogs[i].hp = 0
        w.equipment[i].lives = 0
    w.step(commands)
    let final = w.scoreTicks
    w.step(commands)
    check w.scoreTicks == final
    check w.winner == 0
    w = newWorld(2026,10000)
    w.tick = 11*BigHeartInterval
    check w.remainingHeartPoints() == 10*(10000-w.tick)

  test "timeout does not select a heart that cannot score":
    var w = newWorld(2026,BigHeartInterval)
    var commands: array[Seats,Command]
    for tick in 0..<BigHeartInterval: w.step(commands)
    check w.winner == -2
    check w.bigHeart == -1

  test "BASIC reads point values and invalid indices":
    var w = newWorld(2026)
    w.tick = BigHeartInterval
    w.updateBigHeart()
    let (file,path) = createTempFile("big-heart-policy-", ".bas")
    file.write("walkTo(controlPoints(" & $w.bigHeart & "),controlPoints(" & $((w.bigHeart+1) mod 10) & "))\nlookAt(controlPoints(-1),controlPoints(10))")
    file.close()
    defer: removeFile(path)
    let players = loadBots(@[BotGroup(path:path,count:Seats)])
    let commands = players.decide(w)
    check commands[0].goal == point(5,1)
    check commands[0].aim == point(-1,-1)

  test "replay seeking preserves rotation history, scores and hashes":
    let path = getTempDir()/"paintbot-big-heart-test.replay"
    defer: removeFile(path)
    world = newWorld(2026,2161)
    recording = Recording(seed:2026,endTick:2161)
    var commands: array[Seats,Command]
    for tick in 0..<2161:
      world.step(commands)
      recording.frames.add Frame(commands:commands,hash:world.stateHash())
    saveReplayFile(path,"paintbot_pw",26,recording)
    recording = loadRecording(path)
    replayMode = true
    let index = indexReplay()
    for tick in [720,1440,719,2160,721,1441,0,2161]:
      index.restore(tick)
      check world.stateHash() == (if tick == 0: newWorld(2026,2161).stateHash() else: recording.frames[tick-1].hash)
      var used = 0
      for selected in world.usedBigHearts:
        if selected: inc used
      check used == tick div BigHeartInterval
    replayMode = false

  test "rules 24 retain one-point hearts":
    visionRulesVersion = 24
    var w = newWorld(2026)
    w.tick = BigHeartInterval
    w.updateBigHeart()
    check w.bigHeart == -1
    check w.usedBigHearts.len == 0
    for i in 0..<10: check w.heartPoints(i) == 1
