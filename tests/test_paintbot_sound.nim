import std/[unittest, os, tempfiles]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, bots, game, analysis]

proc arena(): World =
  result = newWorld(2026)
  result.cover = @[]
  result.trenches = @[]
  for i in 0..<Seats:
    result.cogs[i].hp = 0
    result.cogs[i].respawn = 1000
  for i in 0..1:
    result.cogs[i].hp = 3
    result.cogs[i].pos = point(3200+i*500,2000)
    result.cogs[i].goal = result.cogs[i].pos

suite "Imperfect directional hearing":
  setup:
    visionRulesVersion = 26
    replayRulesVersion = 26

  test "octants are coarse and deterministic":
    for i,p in [point(900,20),point(600,600),point(20,900),point(-600,600),
        point(-900,20),point(-600,-600),point(20,-900),point(600,-600)]:
      check soundDirection(p.x,p.z) == i.int32

  test "sound travels around cover but respects range and living listeners":
    var w = arena()
    w.cover = @[Cover(x:3300,z:1800,w:100,h:500)]
    w.emitSound(point(3600,2000),1,1,3500)
    check w.sounds.len == 1
    check w.sounds[0] == SoundCue(listener:0,kind:1,direction:0,distance:0,tick:0)
    w.sounds = @[]
    w.emitSound(point(7000,2000),1,1,3500)
    check w.sounds.len == 0

  test "repeated sounds merge and each listener has a bounded inbox":
    var w = arena()
    for i in 0..<30: w.emitSound(point(3600,2000),1,1,3500)
    check w.sounds.len == 1
    for kind in 0..3:
      for p in [point(3500,2000),point(3500,2300),point(3200,2300),point(2900,2300),
          point(2900,2000),point(2900,1700),point(3200,1700),point(3500,1700)]:
        w.emitSound(p,kind,1,3500)
    check w.sounds.len == 12

  test "quiet movement halves speed and removes only footsteps":
    var loud = arena()
    var quiet = loud.snapshot()
    var commands: array[Seats,Command]
    commands[0] = Command(walk:true,direct:true,goal:point(3400,2000))
    loud.step(commands)
    commands[0].sneak = true
    quiet.step(commands)
    check loud.cogs[0].pos.x-3200 == MoveSpeed
    check quiet.cogs[0].pos.x-3200 == MoveSpeed div 2
    check loud.sounds.len == 1
    check loud.sounds[0].kind == 0
    check quiet.sounds.len == 0
    commands[0].shoot = true
    commands[0].aim = point(4000,2000)
    for i in 0..GunWindupTicks: quiet.step(commands)
    var gun = false
    for cue in quiet.sounds:
      if cue.kind == 1: gun = true
    check gun

  test "explosions produce cues and cues expire after one second":
    var w = arena()
    w.grenades = @[Lob(target:point(3200,3000),owner:0,landsAt:0)]
    w.step(default(array[Seats,Command]))
    check w.sounds.len == 2
    check w.sounds[0].kind == 2
    for i in 0..<SoundLifetime: w.step(default(array[Seats,Command]))
    check w.sounds.len == 0

  test "BASIC receives only its own directional cues and can sneak":
    let (file,path) = createTempFile("paintbot-sound-", ".bas")
    file.write("print soundCount()\nprint soundKind(0)\nprint soundDirection(0)\nprint soundDistance(0)\nprint soundAge(0)\nprint soundKind(99)\nsneak(1)\n")
    file.close()
    defer: removeFile(path)
    var w = arena()
    w.emitSound(point(3600,2000),1,1,3500)
    let bs = loadBots(@[BotGroup(path:path,count:Seats)])
    var output: seq[int32]
    bs[0].output = proc(event:PrintEvent) =
      if event.kind == ValuePrint: output.add event.value
    let commands = bs.decide(w)
    check not bs[0].failed
    check commands[0].sneak
    check output == @[1'i32,1,0,0,0,-1]

  test "old rules never create sound cues":
    visionRulesVersion = 25
    var w = arena()
    w.emitSound(point(3600,2000),1,1,3500)
    check w.sounds.len == 0

  test "checkpoints own their sound storage":
    var w = arena()
    w.emitSound(point(3600,2000),1,1,3500)
    let saved = w.snapshot()
    w.sounds[0].direction = 4
    check saved.sounds[0].direction == 0
