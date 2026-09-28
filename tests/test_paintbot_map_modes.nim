## Both games on small and big maps: a teams match (base.bas) and an FFA-kin match (ffa.bas)
## on Heartwick, a generated map and both ten-times-area big-* maps. Each spawns inside the
## map's own bounds, plays with no failed seat, and replays from its saved recording hash for
## hash.
import std/[unittest, os]
import polyworld/[cli, tapes]
import ../examples/paintbot/[sim, game, bots, kinship]

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
const Ffa = Root / "coworld/paintbot/players/ffa.bas"
const Ticks = 240'i32

proc inBounds(p: Point, margin = 0): bool =
  p.x.int in minX()+margin..maxX()-margin and p.z.int in minZ()+margin..maxZ()-margin

proc record(script: string): Recording =
  ## A live match on the configured map and mode, recorded the way game.advance records it.
  var players = loadBots(@[BotGroup(path: script, count: Seats)])
  world = newLiveWorld(2026, Ticks)
  result = Recording(seed: 2026, endTick: world.endTick, map: mapName())
  for i in 0..<Seats:
    check world.cogs[i].pos.inBounds(100)
    check not world.blocked(world.cogs[i].pos)
  if ffa():
    for g in world.greatHearts:
      check g.pos.inBounds(100)
      check not world.blocked(g.pos)
  for tick in 0..<Ticks:
    let commands = players.decide(world)
    deliverSpeech(world)
    world.step(commands)
    result.frames.add Frame(commands: commands, hash: world.stateHash())
  for slot in 0..<Seats: check not players[slot].failed
  for i in 0..<Seats: check world.cogs[i].pos.inBounds

proc replays(original: Recording, name: string) =
  let path = getTempDir() / ("paintbot-map-modes-" & name & ".replay")
  defer: removeFile(path)
  recording = original
  saveRecording(path, recording)
  let mode = gameMode
  gameMode = gmTeams
  kinshipOverride = none(Kinship)
  configureMap("")
  let loaded = loadRecording(path)
  check gameMode == mode
  check loaded.map == original.map
  check mapName() == original.map
  var again = newWorld(loaded.seed, loaded.endTick)
  check loaded.frames.len == original.frames.len
  for f in loaded.frames:
    again.step(f.commands)
    check again.stateHash() == f.hash

suite "Paintbot modes on small and big maps":
  setup:
    visionRulesVersion = 45
    replayRulesVersion = 45
    replayMode = false
    kinshipOverride = none(Kinship)
  teardown:
    configureMap("")
    gameMode = gmTeams
    kinshipOverride = none(Kinship)

  test "big maps carry their own bounds; shipped maps keep the rules-22 span":
    for name in ["", "crater"]:
      configureMap(name)
      check [minX(), minZ(), maxX(), maxZ()] == [-4800, -2800, 11200, 6800]
    for name in ["big-twin-mesas", "big-deep-forest"]:
      configureMap(name)
      check minX() == currentMap().x0 and minZ() == currentMap().z0
      check maxX() == currentMap().x0+(currentMap().nx-1)*currentMap().step
      check maxZ() == currentMap().z0+(currentMap().nz-1)*currentMap().step
      # Ten times the area, about the same half-turn centre.
      check (maxX()-minX())*(maxZ()-minZ()) > 9*16000*9600
      check minX()+maxX() == Width and minZ()+maxZ() == Height

  for name in ["", "crater", "big-twin-mesas", "big-deep-forest"]:
    let label = if name == "": "heartwick" else: name
    test "teams on " & label & " plays and replays":
      configureMap(name)
      gameMode = gmTeams
      replays(record(Base), "teams-" & label)

    test "FFA-kin on " & label & " plays and replays":
      configureMap(name)
      gameMode = gmFfaKin
      replays(record(Ffa), "ffa-" & label)
