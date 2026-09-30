## Bounded, persistent BASIC players: every seat is a BASIC script with typed observations.
import polyworld/[basic, cli, controllers, rngs]
import sim, oracle, neural_host, seat_view
from neural_contract import ActionContractVersion
export oracle, seat_view
when defined(coworld): import polyworld/coworld

type
  RndStream* = ref object
    ## The seat's rnd(n) stream: SplitMix64 seeded from the match seed and the slot the first
    ## time the seat decides (never part of the world or its hash).
    rng: Rng
    seeded: bool
  Bot* = ref object
    runtime*: Runtime
    failed*: bool
    error*: string ## The BasicError that disabled the seat, if any.
    output*: PrintProc
    strings*: StringPool
    neural*: NeuralSeat
    rnd*: RndStream
# One decision's commands. Training builds run many worlds on many threads: there the
# variable is thread-local, so a handle may migrate between threads. The tick's views, the
# vision cache and the speech live in seat_view.
when defined(pwTraining):
  var commands* {.threadvar.}: seq[Command]
else:
  var commands*: seq[Command]
const RndSalt* = 0x42415352524e4400'u64  # "BASRND" in the high bytes, slot below it
proc rndRng*(matchSeed: int32, slot: int): Rng =
  ## The seat's rnd stream for a match: the neural sampling stream's seeding (match seed salted
  ## with the slot), under its own salt.
  initRng(matchSeed, RndSalt xor (uint64(slot+1) shl 32))
proc limits*(): Limits =
  # An advised seat drafts a structured request and, with the terrain prompt on, probes water
  # along three routes and scans every trench and remembered supply for three candidates on the
  # ask tick. That peaked at 19,000 of the old 20,000 instructions and disabled seats late in a
  # match, so the budget carries headroom: the heaviest measured arm uses about 38% of it. The
  # plain baseline peaks near 5,000 instructions and is unaffected.
  result=defaultLimits()
  result.maxSourceBytes=128*1024; result.maxInstructions=50000
  result.maxMemoryBytes=2*1024*1024; result.maxWorkUnits=125000
  if Seats > LegacySeats:
    # Crowd matches: a script's roster loops grow with the seat count, and so does its budget.
    result.maxInstructions=50000*Seats div LegacySeats; result.maxWorkUnits=125000*Seats div LegacySeats
  result.maxArrayElements=4096;result.maxGlobals=512;result.maxCallDepth=16
  result.maxPrintBytes=1024;result.maxPrintEvents=128
proc host(slot:int, strings:StringPool, neural:NeuralSeat, rnd:RndStream): Host =
  ## The seat's builtins. Perception reads only the seat's SeatView for the tick (seatView,
  ## after decide's beginViews); actions write only the seat's command, shouts and strings.
  result=initHost()
  proc view(): SeatView = seatView(slot)
  result.addNeuralFunctions(neural)
  result.addStringFunctions(strings)
  result.addOracleFunctions(slot,strings)
  discard result.addFunction("shout",1,proc(a:openArray[int32]):int32 =
    if shouts[slot].len>=4:return 0
    shouts[slot].add strings.getString(a[0])[0..<min(256,strings.getString(a[0]).len)];1,68)
  discard result.addFunction("heardCount",0,proc(a:openArray[int32]):int32 = view().heardCount,4)
  discard result.addFunction("heardText",1,proc(a:openArray[int32]):int32 =
    strings.putString(view().heardText(a[0].int)),4)
  discard result.addFunction("heardSlot",1,proc(a:openArray[int32]):int32 = view().heardSlot(a[0].int),4)
  discard result.addFunction("heardX",1,proc(a:openArray[int32]):int32 = view().heardX(a[0].int),4)
  discard result.addFunction("heardY",1,proc(a:openArray[int32]):int32 = view().heardY(a[0].int),4)
  discard result.addFunction("sneak",1,proc(a:openArray[int32]):int32 =
    commands[slot].sneak=a[0]!=0;1,4)
  discard result.addFunction("soundCount",0,proc(a:openArray[int32]):int32 = view().soundCount,4)
  discard result.addFunction("soundKind",1,proc(a:openArray[int32]):int32 = view().soundKind(a[0].int),4)
  discard result.addFunction("soundDirection",1,proc(a:openArray[int32]):int32 = view().soundDirection(a[0].int),4)
  discard result.addFunction("soundDistance",1,proc(a:openArray[int32]):int32 = view().soundDistance(a[0].int),4)
  discard result.addFunction("soundAge",1,proc(a:openArray[int32]):int32 = view().soundAge(a[0].int),4)
  for name in DataNames:discard result.addData(name)
  discard result.addFunction("visible",1,proc(a:openArray[int32]):int32 = view().visible(a[0].int),4)
  discard result.addFunction("playerTeam",1,proc(a:openArray[int32]):int32 = view().playerTeam(a[0].int),4)
  # Nearby agents: nearAgents(radius) lists the agents this seat can see within radius
  # (clamped to 20000), nearest first, at most 64; nearAgentId/X/Y/Hp/Team(k) read entry k,
  # -1 (Hp 0) past the end. Cost follows the neighbourhood, so large games stay cheap.
  discard result.addFunction("nearAgents",1,proc(a:openArray[int32]):int32 = view().nearAgents(a[0].int),16)
  discard result.addFunction("nearAgentId",1,proc(a:openArray[int32]):int32 = view().nearAgentId(a[0].int),4)
  discard result.addFunction("nearAgentX",1,proc(a:openArray[int32]):int32 = view().nearAgentX(a[0].int),4)
  discard result.addFunction("nearAgentY",1,proc(a:openArray[int32]):int32 = view().nearAgentY(a[0].int),4)
  discard result.addFunction("nearAgentHp",1,proc(a:openArray[int32]):int32 = view().nearAgentHp(a[0].int),4)
  discard result.addFunction("nearAgentTeam",1,proc(a:openArray[int32]):int32 = view().nearAgentTeam(a[0].int),4)
  discard result.addFunction("hasUniform",0,proc(a:openArray[int32]):int32 = view().hasUniform,4)
  discard result.addFunction("playerX",1,proc(a:openArray[int32]):int32 = view().playerX(a[0].int),4)
  discard result.addFunction("playerY",1,proc(a:openArray[int32]):int32 = view().playerY(a[0].int),4)
  discard result.addFunction("playerHp",1,proc(a:openArray[int32]):int32 = view().playerHp(a[0].int),4)
  discard result.addFunction("playerCarrying",1,proc(a:openArray[int32]):int32 = view().playerCarrying(a[0].int),4)
  discard result.addFunction("chargeGrenade",1,proc(a:openArray[int32]):int32 =
    commands[slot].chargeGrenade=a[0]!=0;1,4)
  discard result.addFunction("pickupCount",0,proc(a:openArray[int32]):int32 = view().pickupCount,4)
  discard result.addFunction("pickupVisible",1,proc(a:openArray[int32]):int32 = view().pickupVisible(a[0].int),4)
  discard result.addFunction("pickupX",1,proc(a:openArray[int32]):int32 = view().pickupX(a[0].int),4)
  discard result.addFunction("pickupY",1,proc(a:openArray[int32]):int32 = view().pickupY(a[0].int),4)
  discard result.addFunction("pickupKind",1,proc(a:openArray[int32]):int32 = view().pickupKind(a[0].int),4)
  discard result.addFunction("heartCount",0,proc(a:openArray[int32]):int32 = view().heartCount,4)
  discard result.addFunction("glory",1,proc(a:openArray[int32]):int32 = view().glory(a[0].int),4)
  discard result.addFunction("teamLives",1,proc(a:openArray[int32]):int32 = view().teamLives(a[0].int),4)
  discard result.addFunction("awardBehind",0,proc(a:openArray[int32]):int32 = view().awardBehind,4)
  discard result.addFunction("awardBehindSeconds",0,proc(a:openArray[int32]):int32 = view().awardBehindSeconds,4)
  discard result.addFunction("teamCogsOut",1,proc(a:openArray[int32]):int32 = view().teamCogsOut(a[0].int),4)
  discard result.addFunction("awardBehindCogs",0,proc(a:openArray[int32]):int32 = view().awardBehindCogs,4)
  discard result.addFunction("awardBehindCogsSeconds",0,proc(a:openArray[int32]):int32 = view().awardBehindCogsSeconds,4)
  discard result.addFunction("gloryHeartCount",0,proc(a:openArray[int32]):int32 = view().gloryHeartCount,4)
  discard result.addFunction("gloryHeartX",1,proc(a:openArray[int32]):int32 = view().gloryHeartX(a[0].int),4)
  discard result.addFunction("gloryHeartY",1,proc(a:openArray[int32]):int32 = view().gloryHeartY(a[0].int),4)
  discard result.addFunction("gloryHeartTicksLeft",1,proc(a:openArray[int32]):int32 = view().gloryHeartTicksLeft(a[0].int),4)
  discard result.addFunction("controlX",1,proc(a:openArray[int32]):int32 = view().controlX(a[0].int),4)
  discard result.addFunction("controlY",1,proc(a:openArray[int32]):int32 = view().controlY(a[0].int),4)
  discard result.addFunction("controlOwner",1,proc(a:openArray[int32]):int32 = view().controlOwner(a[0].int),4)
  discard result.addFunction("controlCaptureTeam",1,proc(a:openArray[int32]):int32 = view().controlCaptureTeam(a[0].int),4)
  discard result.addFunction("controlCaptureTicks",1,proc(a:openArray[int32]):int32 = view().controlCaptureTicks(a[0].int),4)
  discard result.addFunction("controlContested",1,proc(a:openArray[int32]):int32 = view().controlContested(a[0].int),4)
  discard result.addFunction("controlPoints",1,proc(a:openArray[int32]):int32 = view().controlPoints(a[0].int),4)
  # FFA-kin (Heartland) functions exist only in that mode: the teams game keeps exactly its
  # old host names, so submitted scripts using kin, gene, seatScore... as variables still compile.
  # gameMode is set before any seat is built (coworld config, replay header, native reset).
  # Their fog rules are SeatView's (seat_view.nim).
  if ffa():
    discard result.addFunction("gameMode",0,proc(a:openArray[int32]):int32 = view().gameModeValue,4)
    discard result.addFunction("seatCount",0,proc(a:openArray[int32]):int32 = view().seatCount,4)
    discard result.addFunction("kin",1,proc(a:openArray[int32]):int32 = view().kin(a[0].int),4)
    discard result.addFunction("gene",2,proc(a:openArray[int32]):int32 = view().gene(a[0].int,a[1].int),4)
    discard result.addFunction("seatScore",1,proc(a:openArray[int32]):int32 = view().seatScore(a[0].int),4)
    discard result.addFunction("seatAlive",1,proc(a:openArray[int32]):int32 = view().seatAlive(a[0].int),4)
    discard result.addFunction("heartOwner",1,proc(a:openArray[int32]):int32 = view().heartOwner(a[0].int),4)
    discard result.addFunction("territoryBoost",0,proc(a:openArray[int32]):int32 = view().territoryBoost,4)
    discard result.addFunction("greatHeartCount",0,proc(a:openArray[int32]):int32 = view().greatHeartCount,4)
    discard result.addFunction("greatHeartX",1,proc(a:openArray[int32]):int32 = view().greatHeartX(a[0].int),4)
    discard result.addFunction("greatHeartY",1,proc(a:openArray[int32]):int32 = view().greatHeartY(a[0].int),4)
    discard result.addFunction("greatHeartPresent",1,proc(a:openArray[int32]):int32 = view().greatHeartPresent(a[0].int),4)
    discard result.addFunction("greatHeartProgress",1,proc(a:openArray[int32]):int32 = view().greatHeartProgress(a[0].int),4)
    discard result.addFunction("greatHeartDormant",1,proc(a:openArray[int32]):int32 = view().greatHeartDormant(a[0].int),4)
  discard result.addFunction("mapMinX",0,proc(a:openArray[int32]):int32 = view().mapMinX,4)
  discard result.addFunction("mapMinY",0,proc(a:openArray[int32]):int32 = view().mapMinY,4)
  discard result.addFunction("mapMaxX",0,proc(a:openArray[int32]):int32 = view().mapMaxX,4)
  discard result.addFunction("mapMaxY",0,proc(a:openArray[int32]):int32 = view().mapMaxY,4)
  discard result.addFunction("terrainHeight",2,proc(a:openArray[int32]):int32 = view().terrainHeight(a[0].int,a[1].int),4)
  discard result.addFunction("trenchCount",0,proc(a:openArray[int32]):int32 = view().trenchCount,4)
  discard result.addFunction("trenchX",1,proc(a:openArray[int32]):int32 = view().trenchX(a[0].int),4)
  discard result.addFunction("trenchY",1,proc(a:openArray[int32]):int32 = view().trenchY(a[0].int),4)
  discard result.addFunction("trenchW",1,proc(a:openArray[int32]):int32 = view().trenchW(a[0].int),4)
  discard result.addFunction("trenchH",1,proc(a:openArray[int32]):int32 = view().trenchH(a[0].int),4)
  discard result.addFunction("trenchAt",2,proc(a:openArray[int32]):int32 = view().trenchAt(a[0],a[1]),8)
  discard result.addFunction("waterAt",2,proc(a:openArray[int32]):int32 = view().waterAt(a[0].int,a[1].int),8)
  # rnd(n): 0 .. n-1 from the seat's own stream (seeded from the match seed and the slot;
  # never the world's stream). n must be at least 1.
  discard result.addFunction("rnd",1,proc(a:openArray[int32]):int32 =
    if a[0] < 1: raise newException(BasicError, "rnd needs n >= 1")
    assert rnd.seeded, "rnd before the seat's first decision"
    int32(rnd.rng.next() mod uint64(a[0])),4)
  discard result.addFunction("walkTo",2,proc(a:openArray[int32]):int32 =
    commands[slot].walk=true;commands[slot].goal=Point(x:a[0],z:a[1]);1,4)
  discard result.addFunction("lookAt",2,proc(a:openArray[int32]):int32 =
    commands[slot].aim=Point(x:clamp(a[0],minX().int32,maxX().int32),z:clamp(a[1],minZ().int32,maxZ().int32));1,4)
  discard result.addFunction("shootAt",2,proc(a:openArray[int32]):int32 =
    commands[slot].shoot=true;commands[slot].aim=Point(x:clamp(a[0],minX().int32,maxX().int32),z:clamp(a[1],minZ().int32,maxZ().int32));1,4)
proc loadBots*(groups:seq[BotGroup], playerSlot = 0'i32):seq[Bot] =
  result = newSeq[Bot](Seats)
  # A hosted game journals every advisor request and answer to the asking seat's own log:
  # it is the only record of a decision's exact state that leaves the pod.
  when defined(coworld):
    oracleJournal = proc(slot: int, line: string) = playerLog(slot, line)
  let sources=groups.expandBotSources(controllerKinds(Seats,playerSlot))
  var paths = newSeq[string](Seats)
  var nextSlot = 0
  for group in groups:
    for unused in 0..<group.count:
      while nextSlot < Seats and isPlayerIndex(playerSlot, nextSlot): inc nextSlot
      if nextSlot < Seats: paths[nextSlot] = group.path
      inc nextSlot
  for slot in 0..<Seats:
    if isPlayerIndex(playerSlot, slot): continue
    # Oracle drafts are text-heavy: four times the default handle count, same 64 KiB arena.
    var stringLimits=defaultStringLimits()
    stringLimits.maxStrings=1024
    let strings=initStringPool(stringLimits)
    var neural: NeuralSeat
    var neuralFailed = false
    try:
      neural = loadNeuralSeat(paths[slot], slot)
    except CatchableError as e:
      neural = NeuralSeat(slot: slot)
      neuralFailed = true
      when defined(coworld):
        if e of NeuralBudgetError:
          # The rejected model's cost, so the seat log says how far over budget it was.
          let budget = (ref NeuralBudgetError)(e)
          playerLog(slot, neuralTelemetry(budget.operations, budget.model, 0) & "\n")
        playerError(slot, "Neural package failed: " & e.msg)
      else: echo "seat ", slot, " neural package failed: ", e.msg
    let rnd=RndStream()
    let h=host(slot,strings,neural,rnd)
    let p=when defined(coworld):compilePlayer(sources[slot],h,limits(),slot)
      else:compile(sources[slot],h,limits())
    strings.bindProgram(p)
    result[slot]=Bot(runtime:initRuntime(p,h,limits()),strings:strings,neural:neural,failed:neuralFailed,rnd:rnd)
    when defined(coworld):result[slot].output=playerPrinter(slot)
when defined(pwTraining):
  var peakInstructions* {.threadvar.}: array[MaxSeats, int64]
  var peakWork* {.threadvar.}: array[MaxSeats, int64]
  var peakStrings* {.threadvar.}: array[MaxSeats, int64]
  var peakNativeWork* {.threadvar.}: array[MaxSeats, int64]
  proc scriptBot(source: string, slot: int, neural: NeuralSeat): Bot =
    ## One seat built exactly as loadBots builds a file seat: same string limits, host
    ## functions, compile limits and runtime budget. Raises BasicError when the source does
    ## not compile.
    var stringLimits=defaultStringLimits()
    stringLimits.maxStrings=1024
    let strings=initStringPool(stringLimits)
    let rnd=RndStream()
    let h=host(slot,strings,neural,rnd)
    let p=compile(source,h,limits())
    strings.bindProgram(p)
    Bot(runtime:initRuntime(p,h,limits()),strings:strings,neural:neural,rnd:rnd)
  proc loadScriptBot*(source: string, slot: int): Bot =
    ## One seat from BASIC source text, as loadBots builds a file seat without a neural package.
    scriptBot(source, slot, loadNeuralSeat("/nonexistent/paintbot-pw-script-seat", slot))
  proc loadPolicyBot*(source, manifest: string, slot: int, observationHash: string): Bot =
    ## A training policy-script seat: the bundle's policy.bas and manifest.json, built as
    ## loadBots builds a hosted neural seat (same limits, host functions and budget), with
    ## neural_host.policyNeuralSeat in place of the actor: the trainer feeds the logits.
    ## Raises ValueError when the manifest is rejected, BasicError when the source does not
    ## compile.
    scriptBot(source, slot, policyNeuralSeat(manifest, slot, observationHash))
  proc loadDecoderBot*(source: string, slot: int, observationHash: string,
      contract: ActionContractVersion): Bot =
    ## A training seat whose head choices the caller gives (pw_step): `source` (the reference
    ## decoder, players/neural_decode.bas) turns them into BASIC verbs through the seat's
    ## SeatView, as a hosted neural seat's policy.bas does. neural_host.decoderNeuralSeat
    ## holds the fed choices.
    scriptBot(source, slot, decoderNeuralSeat(slot, observationHash, contract))
else:
  var peakInstructions*, peakWork*, peakStrings*, peakNativeWork*: array[MaxSeats, int64] ## per-seat BASIC peaks, for PW_BASIC_PEAKS
proc logNeuralTelemetry*(bots: openArray[Bot], ticks: int,
    log: proc(slot: int, text: string)) =
  ## Writes each neural seat's telemetry line (peak operations against the budget) through
  ## `log`, one line per seat that loaded a neural model. Plain BASIC seats are skipped, and
  ## nothing here touches the world or the seats' runtimes.
  for slot in 0..<Seats:
    if bots[slot].isNil: continue
    let line = bots[slot].neural.telemetry(peakNativeWork[slot], ticks)
    if line.len > 0: log(slot, line & "\n")
proc runSeat(b: Bot, slot: int, w: World) =
  ## One seat's decision on the tick beginViews started: its neural seat sees the tick, and a
  ## live, working seat runs its script against its SeatView.
  let view = seatView(slot)
  b.neural.beginTick(view, w.seed)
  if b.failed or view.selfHp <= 0: return
  if not b.rnd.seeded:
    b.rnd.rng = rndRng(w.seed, slot)
    b.rnd.seeded = true
  let values = view.dataValues
  b.runtime.restart()
  b.strings.reset()
  try:
    for j,name in DataNames:b.runtime.setData(name,values[j])
    let stats = b.runtime.run(b.output)
    peakNativeWork[slot] = max(peakNativeWork[slot], b.neural.nativeWork)
    peakInstructions[slot] = max(peakInstructions[slot], stats.instructions)
    peakWork[slot] = max(peakWork[slot], stats.workUnits)
    peakStrings[slot] = max(peakStrings[slot], b.strings.stringCount.int64)
  except BasicError as e:
    b.failed=true;b.error=e.msg;commands[slot]=Command()
    when defined(coworld):playerError(slot,e.msg)
    elif not defined(pwTraining):echo "seat ",slot," disabled: ",e.msg
proc decide*(bots:openArray[Bot],w:World):seq[Command] =
  ## Every seat decides on the pre-step world `w`, perceiving it only through its SeatView.
  shouts=newSeq[seq[string]](Seats)
  # Speech heard last tick (deliverSpeech); none yet on a match's first decision.
  if heard.len != Seats: heard.setLen(Seats)
  commands=newSeq[Command](Seats)
  beginViews(w)
  beginOracleTick(w.tick)
  for slot in 0..<Seats:
    let b=(if slot < bots.len: bots[slot] else: nil)
    if b.isNil: continue
    runSeat(b, slot, w)
  commands
when defined(pwTraining):
  proc decideSeats*(bots:openArray[Bot],w:World):seq[Command] =
    ## Training: the non-nil seats of `bots` decide on `w` apart from `decide`'s tick (no
    ## speech delivered, no oracle tick started): the native host's decoder seats, which
    ## neither shout nor ask. `decide`'s commands for the tick are left as they were.
    let saved = commands
    if shouts.len != Seats: shouts = newSeq[seq[string]](Seats)
    if heard.len != Seats: heard.setLen(Seats)
    commands=newSeq[Command](Seats)
    beginViews(w)
    for slot in 0..<Seats:
      let b=(if slot < bots.len: bots[slot] else: nil)
      if b.isNil: continue
      runSeat(b, slot, w)
    result = commands
    commands = saved
