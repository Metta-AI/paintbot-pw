## In-process training ABI. Build with --app:lib --mm:arc --threads:on -d:pwTraining.
## A handle may migrate between threads but must never be used concurrently.
## The caller owns flat buffers; no Nim-managed values cross the C boundary.
import std/[strutils, options]
from std/json import parseJson
import jsony
import sim, kinship, neural_contract, bots, neural_actor, match_config, training_labels
from neural_host import MaxNeuralOperations, neuralOperationBudget, setConditionals, NeuralSeat
import polyworld/rngs
import polyworld/basic
import snapshot, contract_hash

when not defined(pwTraining): {.error: "native_env requires -d:pwTraining".}

type
  PairStat* = enum
    ## FFA-kin pair counters (pw_pair_stats), [i][j] = i's side of the pair, per match:
    psVisible          ## ticks i could see j (both alive)
    psInRange          ## ticks j was visible to i and within gun range (FfaGunRange = 2000 in FFA)
    psDamage           ## health i removed from j
    psKills            ## kills of j by i
    psDefend           ## health i removed from a cog that removed health from j in the last KinWindow ticks
                       ## ("in the last KinWindow ticks" is always exclusive: 0 <= now - then < 72)
    psDefendOpp        ## ticks some such attacker of j (alive, not i) was visible to i (j alive)
    psYieldOpp         ## ticks j was capturing a heart uncontested and i was within KinNearRange of it
    psContest          ## ticks i stood in the capture zone (ControlHeartRadius) of a heart j was capturing;
                       ## a capture i's presence has paused still names j, so j stays credited as capturer
    psNear             ## ticks the pair was within KinNearRange (both alive)
    psCoCapture        ## great-heart captures i and j shared
    psCostlyDefend     ## the part of psDefend dealt while i was in its last third of health (hp*3 <= maxHp)
    psDeathAfterDefend ## i died within KinWindow ticks of a defend event for j
    psHeartPass        ## hearts whose ownership went directly from j to i
  KinCounters = object
    ## Per-match FFA-kin telemetry: never part of the world, its hash or any decision.
    pair: seq[seq[array[PairStat, int32]]]
    deathTick: seq[int32] # -1 while alive
    ownReturn, kinReturn: seq[float64] # cumulative reward parts (reward units)
    split: seq[array[2, float32]] # the last step's {own, kin} reward parts
    lastHit: seq[seq[int32]] # [a][v]: tick a last removed health from v
    lastDefend: seq[seq[int32]] # [i][j]: tick of i's last defend event for j
  NativeEnv* = object ## Exported by name only (tests use std/importutils.privateAccess).
    world: World
    # Seats of the current world (LegacySeats unless pw_set_seats chose another count for an
    # ffa.v2 handle) and the count the next pw_reset applies (0 = keep). Every per-seat seq
    # below holds `n` entries; a reset that changes the count re-creates them all (every
    # per-seat setting back to its default, every script removed).
    n, nextSeats: int
    # ffa.view.1 handles lay out every seat's row from its SeatView (ffaViewRows) each time
    # it is asked; nothing about apparent identities is cached here.
    resets: seq[float32]
    stats: CombatTelemetry # Cumulative since the last create/reset; see pw_seat_stats.
    # BASIC seats: the production interpreter, host functions, limits and per-decision
    # budget from bots.nim drive these slots instead of the caller's actions.
    scripts: seq[string]
    scriptBots: seq[Bot]
    scriptStatus: seq[int32] # 0 none, 1 running, 2 compile failed, 3 disabled at runtime
    scriptErrors: seq[string]
    scriptHeard: seq[seq[HeardMessage]] # Speech carried from the previous decision.
    scriptOrders: seq[Command] # What each scripted seat ordered on the last step.
    scriptCount: int
    # Curriculum knobs, kept across resets like scripts. A fire period above 1 lets a
    # seat's shoot order through only once per that many cooldown windows; a damage
    # scale below or above 1000 permille changes what the seat deals.
    firePeriod: seq[int32]
    lastHonouredShot: seq[int32]
    damagePermille: array[MaxSeats,int32] # damageScale points here
    handicapKnobs: Handicap # sim.handicap points here for a reset or a step
    # Caller-driven seats (no script, no raw command, or a script under an override mask):
    # pw_step's head choices for them are decoded by the reference decoder script
    # (players/neural_decode.bas, or neural_decode_ffa.bas on an ffa.view.1 handle) running
    # through the seat's SeatView, as a hosted neural seat's policy.bas decodes its heads.
    # Built on first use and dropped by every create/reset.
    decoders: seq[Bot]
    # The action contract pw_step's caller heads are read under (pw_set_action_contract):
    # teams.view.1 (11, the default of a 201 handle) or its aim-offset variant (13, seven heads
    # per seat), ffa.view.1 pointer (12, a 202 handle's only one). Kept across resets.
    actionContract: ActionContractVersion
    # Privileged supervision labels (pw_seat_privileged_labels, training_labels.nim): the
    # pre-step positions of the last step, for the lead label's velocity. Never observed.
    labelMemory: LabelMemory
    # Mapping-ceiling diagnostics (pw-bc): a scripted seat with a non-zero override mask
    # still runs its script every step (its orders are reported by pw_seat_orders) but
    # executes the caller's decoded action for the masked heads: 1 walk/goal/direct,
    # 2 aim, 4 shoot, 8 grenade, 16 sneak. pw_script_decide runs the scripts' decision
    # for the current tick ahead of pw_step so the caller can read the orders, map them
    # and hand the mapped action to the same step.
    overrideMask: seq[int32]
    # Decoder sampling (pw_set_seat_sampling, kept across resets like the knobs): the
    # seat's draw stream, seeded from the match seed and the slot exactly as the hosted
    # seat seeds its own (neural_contract.samplingRng) on every create/reset, so a probe
    # that feeds pw_sample_actions the logits the hosted actor would produce takes the
    # hosted seat's draws. Never part of the world or its hash; pw_step is untouched.
    sampling: seq[SamplingOptions]
    sampleRng: seq[Rng]
    sampleDraws: seq[int32]
    # Decoder objective forbid (pw_set_seat_forbid_objectives, kept across resets): the
    # movement-head indices pw_sample_actions never selects for the seat and pw_step
    # refuses from the caller for it (the hosted bundle option decoder.forbid_objectives).
    forbidden: seq[ObjectiveMask]
    forbidAny: seq[bool]
    # Raw commands (pw_set_seat_command): a seat with a pending command executes it on the
    # next pw_step instead of its decoded heads or its script's order (no forbid check, no
    # head decode or decoder option for it); commandShown marks an unscripted seat whose
    # pw_seat_orders echo holds a command, cleared on its next step without one. Nothing
    # here is part of the world or its hash; unused, every flag stays false.
    commandPending: seq[bool]
    commandNext: seq[Command]
    commandShown: seq[bool]
    decided: seq[Command]
    decidedTick: int32
    decidedValid: bool
    # Observation contract the handle encodes (chosen at create, kept across resets):
    # teams.view.1 (pw_create) or ffa.view.1. The world never reads it.
    obsVersion: ObservationContractVersion
    # Neural BASIC I/O. userInputs: the K of observation contract teams.view.1u<K> or
    # ffa.view.1u<K> (pw_create_observation_inputs / _v; 0 otherwise): every pw_observe row is
    # the base contract's floats + K, the last K a policy seat's user inputs (zeros for any
    # other seat). policy:
    # the seats running a bundle's policy.bas under its manifest
    # (pw_set_seat_policy_script), stepped only by pw_step_logits. Unused, nothing here
    # runs and every path is byte-identical.
    userInputs: int
    policy: seq[bool]
    policyManifests: seq[string]
    policyCount: int
    # A policy seat's COND_HEAD layers (pw_set_seat_conditionals): the trainer's current
    # learned conditional heads, applied to the seat at every install. Empty = none.
    policyConditionals: seq[seq[Conditional]]
    # FFA-kin. mode is the current world's game mode; nextMode (pw_set_game_mode) and
    # kinLayout (pw_set_kin_layout, -1 = sampled from the seed) are kept across resets and
    # applied at the next reset, like the fire period. kinship is the current world's
    # (zero in the teams game). Eval-only overrides, reachable from this ABI alone:
    # kinOverride (pw_set_kin_override) and spawnGrouping (pw_set_spawn_grouping) apply at
    # the next reset and stay until cleared; obsMask (pw_set_obs_mask) is read by the ffa.v1
    # encoder at once. kin holds the match's reward split and pair counters (reset by
    # create/reset). None of it is part of the world or its hash; unused, the teams game is
    # byte-identical.
    mode, nextMode: GameMode
    kinLayout: int32
    kinship: Kinship
    kinOverride: Option[Kinship]
    spawnGrouping: Option[array[LegacySeats, int8]]
    obsMask: uint32
    kin: KinCounters
    # pw_set_pair_stats_enabled(h, 0) sets this (zeroed = counters on): the per-tick pair
    # counters and the damage hook are skipped; the reward, its split and death ticks stay.
    pairStatsOff: bool
    # Map (pw_set_map): 1 + an index into MapNames, 0 = the rules' own island (the zero-init
    # default, so an untouched handle plays exactly as before). mapSlot is the current world's
    # and ready() installs it on the calling thread like the mode and kinship; nextMapSlot is
    # kept across resets and applied at the next reset, so a live world never changes map.
    mapSlot, nextMapSlot: int32
    # Rules and match config (pw_set_rules, pw_set_config_json), per handle like the map: rules
    # 0 means NativeRules (the zero-init default); glory and vision are the current world's,
    # ready() installs them, and the next* values apply at the next reset. createEnv starts
    # both glories at DefaultGloryConfig, so an untouched handle plays exactly as before.
    rules, nextRules: int32
    glory, nextGlory: GloryConfig
    vision, nextVision: bool
    # "vision_range" metres (0 = unlimited), current world's and next reset's, like vision.
    visionRange, nextVisionRange: int32
  FloatBuffer = ptr UncheckedArray[cfloat]
  ActionBuffer = ptr UncheckedArray[int32]

const
  NativeRules* = 40
  PairStatCount* = PairStat.high.ord + 1
  KinWindow* = 3*TickRate # 72 ticks: a hit or defend counts while now - then < KinWindow
  KinNearRange* = 400
  FfaRewardScale* = 4320.0 # pw_step pays delta R_i (points) / this each tick in FFA
  NoTick = low(int32) div 2
  KinHeartSlots = 16 # control hearts tracked for psHeartPass (rules 40 has 10)
static: doAssert PairStatCount == 13 and KinWindow == 72

proc rulesVersion(env: ptr NativeEnv): int =
  ## The current world's rules.
  if env.rules == 0: NativeRules else: env.rules.int

proc initCurriculum(env: ptr NativeEnv)
proc seatsOf(handle: pointer): int =
  ## The seats of a non-nil handle's current world.
  cast[ptr NativeEnv](handle).n
proc allocSeats(env: ptr NativeEnv, n: int) =
  ## Every per-seat seq, fresh, for `n` seats: each setting at its default (curriculum knobs
  ## neutral, sampling and forbids off, no script). createEnv, and a reset that changes the
  ## seat count, call it; a reset that keeps the count keeps every setting.
  env.n = n
  env.resets = newSeq[float32](n)
  env.decoders = newSeq[Bot](n)
  env.scripts = newSeq[string](n)
  env.scriptBots = newSeq[Bot](n)
  env.scriptStatus = newSeq[int32](n)
  env.scriptErrors = newSeq[string](n)
  env.scriptHeard = newSeq[seq[HeardMessage]](n)
  env.scriptOrders = newSeq[Command](n)
  env.scriptCount = 0
  env.firePeriod = newSeq[int32](n)
  env.lastHonouredShot = newSeq[int32](n)
  for slot in 0..<MaxSeats: env.damagePermille[slot] = 0
  env.handicapKnobs = Handicap()
  for slot in 0..<MaxSeats: env.handicapKnobs.damageTaken[slot] = 1000
  env.overrideMask = newSeq[int32](n)
  env.sampling = newSeq[SamplingOptions](n)
  env.sampleRng = newSeq[Rng](n)
  env.sampleDraws = newSeq[int32](n)
  env.forbidden = newSeq[ObjectiveMask](n)
  env.forbidAny = newSeq[bool](n)
  env.commandPending = newSeq[bool](n)
  env.commandNext = newSeq[Command](n)
  env.commandShown = newSeq[bool](n)
  env.decided = newSeq[Command](n)
  env.decidedValid = false
  env.policy = newSeq[bool](n)
  env.policyManifests = newSeq[string](n)
  env.policyConditionals = newSeq[seq[Conditional]](n)
  env.policyCount = 0
  env.initCurriculum()

proc ready(handle: pointer = nil) =
  ## Every entry point: the thread's GC, map and rules, and, for a handle, its game mode and
  ## kinship, and its rules, glory awards, vision and vision range. All are threadvars the engine reads
  ## (terrain, layout, ffa(), scores, glory, sight, the ffa.v1 encoder) and several handles may
  ## share a thread, so each call installs its own handle's; without a handle, NativeRules on
  ## the rules' own island with the default awards. The map goes first so configureRules binds the
  ## terrain table once, for the right key (a key compare when nothing changed).
  setupForeignThreadGc()
  setActiveMap(if handle == nil: -1 else: cast[ptr NativeEnv](handle).mapSlot.int-1)
  if handle == nil:
    configureRules(NativeRules)
    configureGlory(DefaultGloryConfig)
    teamVision = false
    configureVisionRange(0)
  else:
    let env = cast[ptr NativeEnv](handle)
    configureRules(env.rulesVersion)
    configureGlory(env.glory)
    teamVision = env.vision
    configureVisionRange(env.visionRange)
    gameMode = env.mode
    activeKinship = env.kinship
    configureSeats(env.n)

proc resetDecoders(env: ptr NativeEnv) =
  ## Every decoder seat starts the new match fresh (built again on first use).
  for slot in 0..<env.n: env.decoders[slot] = nil
proc resetStats(env: ptr NativeEnv) =
  for slot in 0..<env.n:
    env.stats[slot] = SeatStats(firstFriendlyFireTick: -1)
proc recent(now, then: int32): bool =
  ## "In the last KinWindow ticks", exclusive: then happened within the 72 ticks before now,
  ## now's own tick included (now - then in 0 ..< KinWindow).
  now - then < KinWindow
proc resetKin(env: ptr NativeEnv) =
  ## The match's FFA-kin telemetry starts empty (settings and overrides persist).
  let n = env.n
  env.kin = KinCounters(pair: newSeq[seq[array[PairStat, int32]]](n), deathTick: newSeq[int32](n),
    ownReturn: newSeq[float64](n), kinReturn: newSeq[float64](n), split: newSeq[array[2, float32]](n),
    lastHit: newSeq[seq[int32]](n), lastDefend: newSeq[seq[int32]](n))
  for i in 0..<n:
    env.kin.pair[i] = newSeq[array[PairStat, int32]](n)
    env.kin.lastHit[i] = newSeq[int32](n)
    env.kin.lastDefend[i] = newSeq[int32](n)
    env.kin.deathTick[i] = -1
    for j in 0..<n:
      env.kin.lastHit[i][j] = NoTick
      env.kin.lastDefend[i][j] = NoTick
proc newEnvWorld(env: ptr NativeEnv, seed, maxTicks: int32) =
  ## The world a create or reset starts, in the pending game mode, with the pending kin
  ## layout and eval overrides fed to the engine through its threadvars for this call only,
  ## on the pending map (newWorld's configureRules binds its terrain table).
  let mode = env.nextMode
  let seats = if env.nextSeats > 0: env.nextSeats else: env.n
  gameMode = mode
  configureSeats(seats)
  setActiveMap(env.nextMapSlot.int-1)
  configureRules(if env.nextRules == 0: NativeRules else: env.nextRules.int)
  configureGlory(env.nextGlory)
  teamVision = env.nextVision
  configureVisionRange(env.nextVisionRange)
  let savedKinship = kinshipOverride
  # The eval overrides (pw_set_kin_override, pw_set_spawn_grouping) are 16-seat tables: they
  # apply to 16-seat worlds only.
  kinshipOverride =
    if env.kinOverride.isSome and seats == LegacySeats: env.kinOverride
    elif env.kinLayout >= 0: some(kinshipFor(KinLayout(env.kinLayout), seed))
    else: none(Kinship)
  spawnGroupingOverride = if seats == LegacySeats: env.spawnGrouping else: none(array[LegacySeats, int8])
  # The handicaps' fractional damage belongs to the match; the knobs persist.
  for slot in 0..<MaxSeats:
    env.handicapKnobs.remOut[slot] = 0; env.handicapKnobs.remIn[slot] = 0
  handicap = addr env.handicapKnobs
  try:
    env.world = newWorld(seed, maxTicks)
  finally:
    handicap = nil
    kinshipOverride = savedKinship
    spawnGroupingOverride = none(array[LegacySeats, int8])
  env.mapSlot = env.nextMapSlot
  env.rules = env.nextRules
  env.glory = env.nextGlory
  env.vision = env.nextVision
  env.visionRange = env.nextVisionRange
  env.mode = mode
  env.kinship = if mode == gmFfaKin: activeKinship else: initKinship(seats)
  activeKinship = env.kinship
  env.nextSeats = 0
  if seats != env.n: env.allocSeats(seats)
  env.resetKin()

var kinEnv {.threadvar.}: ptr NativeEnv # The handle an FFA step is counting for.
proc observeKinDamage(w: World, victim, attacker: int, removed: int32,
    killed: bool) {.nimcall, gcsafe.} =
  ## damage() hook for one FFA step: psDamage, psKills, psDefend, psCostlyDefend, the
  ## defend and hit memories, psDeathAfterDefend and the death tick.
  let env = kinEnv
  if env == nil: return
  let t = w.tick
  if killed:
    if env.kin.deathTick[victim] < 0: env.kin.deathTick[victim] = t
    for j in 0..<env.n:
      if j != victim and recent(t, env.kin.lastDefend[victim][j]):
        inc env.kin.pair[victim][j][psDeathAfterDefend]
  if attacker notin 0..<env.n or attacker == victim: return
  env.kin.pair[attacker][victim][psDamage] += removed
  if killed: inc env.kin.pair[attacker][victim][psKills]
  if removed <= 0: return
  for j in 0..<env.n:
    if j == attacker or j == victim or not recent(t, env.kin.lastHit[victim][j]): continue
    env.kin.pair[attacker][j][psDefend] += removed
    if w.cogs[attacker].hp*3 <= maxHp(): env.kin.pair[attacker][j][psCostlyDefend] += removed
    env.kin.lastDefend[attacker][j] = t
  env.kin.lastHit[attacker][victim] = t

proc kinAfterStep(env: ptr NativeEnv, preScore, preGreat: openArray[int32],
    preOwners: array[KinHeartSlots, int32], preDormant: array[2, int32], wasDead: openArray[bool],
    rewards: FloatBuffer) =
  ## After an FFA step: the dense kin-weighted reward and its split, then the per-tick pair
  ## counters on the post-step world (events happened on tick w.tick - 1).
  template w: untyped = env.world
  let now = w.tick - 1
  var ds = newSeq[float64](env.n)
  for j in 0..<env.n: ds[j] = float64(w.seatScore[j] - preScore[j]) / 10
  for i in 0..<env.n:
    let own = env.kinship.r(i, i) * ds[i]
    var kin = 0.0
    for j in 0..<env.n:
      if j != i: kin += env.kinship.r(i, j) * ds[j]
    env.kin.split[i] = [float32(own / FfaRewardScale), float32(kin / FfaRewardScale)]
    env.kin.ownReturn[i] += own / FfaRewardScale
    env.kin.kinReturn[i] += kin / FfaRewardScale
    rewards[i] = float32((own + kin) / FfaRewardScale)
  var alive = newSeq[bool](env.n)
  for i in 0..<env.n:
    alive[i] = w.cogs[i].hp > 0
    if not wasDead[i] and not alive[i] and env.kin.deathTick[i] < 0: env.kin.deathTick[i] = now
  if env.pairStatsOff: return # the trainer opted out of pair counters (pw_set_pair_stats_enabled)
  var vis = newSeq[seq[bool]](env.n)
  for i in 0..<env.n: vis[i] = newSeq[bool](env.n)
  for i in 0..<env.n:
    if not alive[i]: continue
    for j in 0..<env.n:
      if j != i and alive[j]: vis[i][j] = w.visible(i, j)
  const near2 = KinNearRange.int64 * KinNearRange
  let gunRange = (if ffa(): FfaGunRange else: ShotRange).int64
  let shot2 = gunRange * gunRange
  for i in 0..<env.n:
    if not alive[i]: continue
    for j in 0..<env.n:
      if j == i or not alive[j]: continue
      let d2 = distance2(w.cogs[i].pos, w.cogs[j].pos)
      if vis[i][j]:
        inc env.kin.pair[i][j][psVisible]
        if d2 <= shot2: inc env.kin.pair[i][j][psInRange]
      if d2 <= near2: inc env.kin.pair[i][j][psNear]
      for k in 0..<env.n:
        if k != i and k != j and vis[i][k] and recent(now, env.kin.lastHit[k][j]):
          inc env.kin.pair[i][j][psDefendOpp]
          break
  var yielded, contested = newSeq[seq[bool]](env.n)
  for i in 0..<env.n:
    yielded[i] = newSeq[bool](env.n)
    contested[i] = newSeq[bool](env.n)
  for h in 0..<min(w.controlHearts.len, w.heartCaptures.len):
    let capture = w.heartCaptures[h]
    let j = capture.team.int
    if j notin 0..<env.n: continue
    let spot = w.controlHearts[h].pos
    for i in 0..<env.n:
      if i == j or not alive[i]: continue
      let d2 = distance2(w.cogs[i].pos, spot)
      if not capture.contested and d2 <= near2: yielded[i][j] = true
      if d2 <= ControlHeartRadius*ControlHeartRadius and w.traversable(w.cogs[i].pos, spot):
        contested[i][j] = true
  for i in 0..<env.n:
    for j in 0..<env.n:
      if yielded[i][j]: inc env.kin.pair[i][j][psYieldOpp]
      if contested[i][j]: inc env.kin.pair[i][j][psContest]
  for h in 0..<min(w.controlHearts.len, KinHeartSlots):
    let before = preOwners[h]
    let after = w.controlHearts[h].owner
    if before >= 0 and after >= 0 and before != after:
      inc env.kin.pair[after][before][psHeartPass]
  const great2 = GreatHeartRadius.int64 * GreatHeartRadius
  for g in 0..<2:
    if w.greatHearts[g].dormantUntil == preDormant[g]: continue
    var members: seq[int]
    for i in 0..<env.n:
      if w.greatShare[i] > preGreat[i] and distance2(w.cogs[i].pos, w.greatHearts[g].pos) <= great2:
        members.add i
    for i in members:
      for j in members:
        if i != j: inc env.kin.pair[i][j][psCoCapture]

proc resetSampling(env: ptr NativeEnv) =
  ## Fresh streams for the new match (options persist); draw counts belong to the match.
  for slot in 0..<env.n:
    env.sampleRng[slot] = samplingRng(env.world.seed, slot)
    env.sampleDraws[slot] = 0
proc resetCurriculum(env: ptr NativeEnv) =
  ## Knob values persist; the shot history belongs to the match.
  for slot in 0..<env.n:
    env.lastHonouredShot[slot] = low(int32) div 2
    if env.firePeriod[slot] < 1: env.firePeriod[slot] = 1
proc initCurriculum(env: ptr NativeEnv) =
  for slot in 0..<env.n:
    env.firePeriod[slot] = 1
    env.damagePermille[slot] = 1000
  env.resetCurriculum()
static: doAssert FireCooldownTicks == 24, "the fire period unit is the 24-tick cooldown window"
proc gateFire(env: ptr NativeEnv, slot: int, command: var Command) =
  ## Honour a shoot order only when the seat could fire now and at least
  ## period x FireCooldownTicks (period x 24 ticks) have passed since its last honoured
  ## shot. Period 1 never gates.
  let period = env.firePeriod[slot]
  if period <= 1 or not command.shoot: return
  let c = env.world.cogs[slot]
  let e = env.world.equipment[slot]
  let ready = c.hp > 0 and (if e.sprayCan: e.sprayCooldown == 0 else: c.cooldown == 0 and e.windup == 0)
  if ready and env.world.tick-env.lastHonouredShot[slot] >= period*FireCooldownTicks.int32:
    env.lastHonouredShot[slot] = env.world.tick
  else:
    command.shoot = false
proc observationHash(env: ptr NativeEnv): string =
  ## The observation contract hash this handle encodes (teams.view.1 or ffa.view.1, or either's u<K>).
  if env.userInputs > 0: userInputsContractHash(env.userInputs, env.obsVersion)
  else: observationContractHash(env.obsVersion)
proc installScript(env: ptr NativeEnv, slot: int) =
  ## A fresh runtime for the seat's source, as a new match loads its bots. A policy seat
  ## gets a fresh neural seat from its manifest too (fresh streams, user inputs at init).
  env.scriptBots[slot] = nil
  env.scriptErrors[slot] = ""
  env.scriptOrders[slot] = Command()
  if env.scripts[slot].len == 0:
    env.scriptStatus[slot] = 0
    return
  try:
    env.scriptBots[slot] =
      if env.policy[slot]: loadPolicyBot(env.scripts[slot], env.policyManifests[slot], slot, env.observationHash)
      else: loadScriptBot(env.scripts[slot], slot)
    if env.policy[slot] and env.policyConditionals[slot].len > 0:
      env.scriptBots[slot].neural.setConditionals(env.policyConditionals[slot])
    env.scriptStatus[slot] = 1
  except BasicError as e:
    env.scriptStatus[slot] = 2
    env.scriptErrors[slot] = e.msg
  except ValueError as e:
    env.scriptStatus[slot] = 2
    env.scriptErrors[slot] = "policy manifest rejected: " & e.msg
proc sizeHeard(env: ptr NativeEnv) =
  ## Carried speech, one list per seat (a zeroed handle starts with none).
  if env.scriptHeard.len != env.n: env.scriptHeard.setLen(env.n)
proc resetScripts(env: ptr NativeEnv) =
  env.scriptCount = 0
  env.decidedValid = false
  env.scriptHeard = newSeq[seq[HeardMessage]](env.n)
  for slot in 0..<env.n:
    env.installScript(slot)
    if env.scripts[slot].len > 0: inc env.scriptCount
proc scriptDecide(env: ptr NativeEnv) =
  ## The production tick's decision half: every BASIC seat decides on the pre-step world
  ## (hearing what was shouted last tick), shouts are delivered for next tick. Runs once
  ## per world tick, inline from pw_step or ahead of it from pw_script_decide.
  heard = env.scriptHeard
  let decided = decide(env.scriptBots, env.world)
  deliverSpeech(env.world)
  env.scriptHeard = heard
  for slot in 0..<env.n:
    if env.scripts[slot].len == 0: continue
    let b = env.scriptBots[slot]
    if b != nil and b.failed and env.scriptStatus[slot] == 1:
      env.scriptStatus[slot] = 3
      env.scriptErrors[slot] = b.error
    env.scriptOrders[slot] = decided[slot]
  for slot in 0..<env.n: env.decided[slot] = decided[slot]
  env.decidedTick = env.world.tick
  env.decidedValid = true
const
  DecoderSource = staticRead("players/neural_decode.bas")
  DecoderSourceFfa = staticRead("players/neural_decode_ffa.bas")

proc contract(env: ptr NativeEnv): ActionContractVersion = env.actionContract

proc rowsFor(env: ptr NativeEnv, slot: int): FfaViewRows =
  ## The seat's ffa.view.1 row -> entity map on the current unchanged world, from its view.
  beginViews(env.world)
  ffaViewRows(seatView(slot))

proc decoderFor(env: ptr NativeEnv, slot: int): Bot =
  ## The seat's decoder seat for this match (built on first use).
  if env.decoders[slot].isNil:
    env.decoders[slot] = loadDecoderBot(if env.obsVersion == ocFfaView1: DecoderSourceFfa else: DecoderSource,
      slot, env.observationHash, env.actionContract)
  env.decoders[slot]

proc pw_env_version*(): cint {.exportc, cdecl, dynlib.} = 1
proc pw_observation_size*(): cint {.exportc, cdecl, dynlib.} = TeamsViewSize
proc pw_action_count*(): cint {.exportc, cdecl, dynlib.} = ActionSizes.len

const NativeObservationVersions = [ocTeamsView1.int32, ocFfaView1.int32]
proc obsContract(version: int32): ObservationContractVersion =
  ## A native observation version already checked to be 201 or 202.
  if version == ocTeamsView1.int32: ocTeamsView1 else: ocFfaView1
proc layoutOf(env: ptr NativeEnv): FfaViewLayout =
  ## The ffa.view.1 layout of the handle's current world.
  ffaViewLayout(env.n, env.world.controlHearts.len)
proc rowWidth(env: ptr NativeEnv): int =
  ## Floats per seat this handle's pw_observe writes: the contract's width (ffa.view.1: the
  ## current world's layout) plus the user inputs.
  if env.obsVersion == ocFfaView1: env.layoutOf.size + env.userInputs
  else: TeamsViewSize + env.userInputs
proc actionHeads(env: ptr NativeEnv): seq[int] =
  ## The head sizes of the handle's action contract (teams.view.1: ActionSizes; ffa.view.1
  ## pointer: the current world's layout).
  if env.obsVersion == ocFfaView1: pointerHeads(env.layoutOf) else: actionHeadSizes(env.actionContract)
proc logitWidth(env: ptr NativeEnv): int =
  ## Logits per seat under the handle's action contract (pw_step_logits' row stride).
  for h in env.actionHeads: result += h

proc createEnv(seed, maxTicks: int32, obsVersion: ObservationContractVersion): pointer =
  ready()
  if maxTicks < 0 or maxTicks > HeartMeterMatchTicks: return nil
  let env = cast[ptr NativeEnv](allocShared0(sizeof(NativeEnv)))
  try:
    env.obsVersion = obsVersion
    env.actionContract = pairedAction(obsVersion)
    env.kinLayout = -1
    env.glory = DefaultGloryConfig
    env.nextGlory = DefaultGloryConfig
    env.allocSeats(LegacySeats)
    env.newEnvWorld(seed, maxTicks)
    for i in 0..<env.n: env.resets[i] = 1
    env.resetStats()
    env.initCurriculum()
    env.resetDecoders()
    env.resetSampling()
    env.labelMemory.resetLabelMemory()
    result = env
  except CatchableError:
    `=destroy`(env[])
    deallocShared(env)

proc pw_create*(seed, maxTicks: int32): pointer {.exportc, cdecl, dynlib.} =
  ## Observation contract teams.view.1 (512 floats per seat).
  createEnv(seed, maxTicks, ocTeamsView1)

proc pw_create_observation*(seed, maxTicks, obsVersion: int32): pointer {.exportc, cdecl, dynlib.} =
  ## pw_create with the observation contract chosen: 201 = teams.view.1 (identical to
  ## pw_create; the teams game only: pw_set_game_mode refuses FFA-kin on the handle),
  ## 202 = ffa.view.1 (any seat count, pw_set_seats; the width follows the match:
  ## pw_handle_observation_size, pw_observation_layout). nil for any other version (the
  ## contracts before teams.view.1 were retired for BASIC parity) or a bad max_ticks.
  if obsVersion notin NativeObservationVersions: return nil
  createEnv(seed, maxTicks, obsContract(obsVersion))

proc pw_observation_size_for*(obsVersion: int32): cint {.exportc, cdecl, dynlib.} =
  ## Floats per seat under observation contract `obsVersion`; -1 if unknown, and for 202
  ## (ffa.view.1), whose width follows the match (pw_handle_observation_size).
  if obsVersion != ocTeamsView1.int32: return -1
  TeamsViewSize.cint

proc pw_observation_contract*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## The handle's observation contract version (201 or 202); -1 for a nil handle.
  if handle == nil: return -1
  cast[ptr NativeEnv](handle).obsVersion.cint

proc pw_handle_observation_size*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## Floats per seat this handle's pw_observe writes (the row stride; ffa.view.1: the current
  ## world's layout size, fixed for the match); -1 for nil.
  if handle == nil: return -1
  cint(cast[ptr NativeEnv](handle).rowWidth)

proc pw_create_observation_inputs*(seed, maxTicks, userInputs: int32): pointer {.exportc, cdecl, dynlib.} =
  ## Observation contract teams.view.1u<K>, K = userInputs within 1 .. 256: every pw_observe
  ## row is teams.view.1's 512 floats followed by K user-input floats, a policy seat's
  ## (pw_set_seat_policy_script) as its policy.bas set them, zeros for every other seat.
  ## K = 0 is pw_create. nil for a bad K or max_ticks.
  if userInputs notin 0'i32..MaxUserInputs.int32: return nil
  result = createEnv(seed, maxTicks, ocTeamsView1)
  if result != nil: cast[ptr NativeEnv](result).userInputs = userInputs.int

proc pw_create_observation_inputs_v*(seed, maxTicks, obsVersion, userInputs: int32): pointer {.exportc, cdecl, dynlib.} =
  ## pw_create_observation_inputs with the base contract named: 201 = teams.view.1u<K> (as
  ## pw_create_observation_inputs), 202 = ffa.view.1u<K>: every pw_observe row is the match's
  ## ffa.view.1 floats (pw_observation_layout's sections, unchanged) followed by K user-input
  ## floats, a policy seat's as its policy.bas set them, zeros for every other seat; K = 0 is
  ## pw_create_observation(seed, max_ticks, 202). nil for another version, a bad K or max_ticks.
  if obsVersion == ocTeamsView1.int32: return pw_create_observation_inputs(seed, maxTicks, userInputs)
  if obsVersion != ocFfaView1.int32 or userInputs notin 0'i32..MaxUserInputs.int32: return nil
  result = createEnv(seed, maxTicks, ocFfaView1)
  if result != nil: cast[ptr NativeEnv](result).userInputs = userInputs.int

proc pw_handle_user_inputs*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## The handle's K (0 unless created by pw_create_observation_inputs); -1 for nil.
  if handle == nil: return -1
  cast[ptr NativeEnv](handle).userInputs.cint

proc pw_set_seats*(handle: pointer, seats: int32): cint {.exportc, cdecl, dynlib.} =
  ## The seat count of this handle's worlds from its NEXT pw_reset on, 2 .. 256 (kinship
  ## MaxSeats; Heartland Big plays 50). Any count other than 16 needs an observation contract
  ## ffa.view.1 handle (version 202): teams.view.1 lays out 16 seats.
  ## Kept across resets. A reset that changes the count re-creates every per-seat setting
  ## at its default (curriculum knobs, decoder options, scripts and policy seats removed);
  ## one that keeps it keeps them. Every per-seat buffer is sized by the current world's
  ## count (pw_seats): pw_observe rows, pw_step actions / rewards / terminals, pw_kin,
  ## pw_scores, pw_reward_split, ... 0, or -1 bad args.
  if handle == nil or seats notin 2'i32..MaxSeats.int32: return -1
  let env = cast[ptr NativeEnv](handle)
  if seats != LegacySeats.int32 and env.obsVersion != ocFfaView1: return -1
  env.nextSeats = seats.int
  0

proc pw_seats*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## The current world's seat count; -1 for nil.
  if handle == nil: return -1
  cast[ptr NativeEnv](handle).n.cint

const ObservationLayoutWords* = 16 ## pw_observation_layout's int32 count

proc pw_observation_layout*(handle: pointer, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Where each section of this handle's observation row lies for the current world,
  ## 16 int32: [row floats, header floats, cog offset, cog rows, cog width, heart offset,
  ## heart rows, heart width, great offset, great rows, great width, valid column, seats,
  ## control hearts, 0, 0]. ffa.view.1: header 24, cog rows = min(seats - 1, 64) (only the
  ## agents the seat sees are valid, packed first), heart rows = control hearts, great rows 2;
  ## every row's valid flag is column 0 (neural_contract.encodeFfaView documents every column).
  ## Any other contract has no sections: [row floats, row floats, 0 ..., seats, control
  ## hearts, 0, 0] with the offsets, counts and widths 0 and valid column -1. Row floats
  ## include an ffa.view.1u<K> handle's K user inputs, the row's last K floats (the sections
  ## are unchanged). Fixed for the match; a reset may change it (map, seats). 0, or -1 bad args.
  if handle == nil or output == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  for i in 0..<ObservationLayoutWords: output[i] = 0
  let width = env.rowWidth
  output[0] = width.int32
  output[12] = env.n.int32
  output[13] = env.world.controlHearts.len.int32
  if env.obsVersion != ocFfaView1:
    output[1] = width.int32
    output[11] = -1
    return 0
  let l = env.layoutOf
  output[1] = FfaHeaderSize
  output[2] = l.cogOffset.int32; output[3] = l.cogRows.int32; output[4] = FfaCogWidth
  output[5] = l.heartOffset.int32; output[6] = l.heartRows.int32; output[7] = FfaHeartWidth
  output[8] = l.greatOffset.int32; output[9] = l.greatRows.int32; output[10] = FfaGreatWidth
  output[11] = FfaValidColumn
  0

proc pw_observation_rows*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32],
    capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## ffa.view.1: the seat's row -> entity map for its observation of the current world (the
  ## one pw_observe writes before the next pw_step), laid out like the sections: cog rows
  ## (the identity each row describes, -1 for a row past the agents the seat sees),
  ## then heart rows (control heart indices), then the 2 great heart rows (great heart
  ## indices). Returns that count (seats - 1 + hearts + 2) and writes it only when capacity
  ## holds it (capacity 0 sizes the buffer); -1 bad args or not an ffa.view.1 handle.
  if handle == nil or seat notin 0..<seatsOf(handle) or capacity < 0 or (capacity > 0 and output == nil): return -1
  let env = cast[ptr NativeEnv](handle)
  if env.obsVersion != ocFfaView1: return -1
  ready(handle)
  let l = env.layoutOf
  let total = l.cogRows + l.heartRows + l.greatRows
  if capacity < total: return total.cint
  try:
    let rows = env.rowsFor(seat)
    for k in 0..<l.cogRows: output[k] = if k < rows.agents.len: rows.agents[k].identity else: -1
    for k in 0..<l.heartRows: output[l.cogRows+k] = rows.hearts[k].int32
    for k in 0..<l.greatRows: output[l.cogRows+l.heartRows+k] = rows.greats[k].int32
  except CatchableError: return -1
  total.cint

proc pw_action_layout*(handle: pointer, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## The handle's action heads for the current world, 8 int32: [heads (5), the five head
  ## sizes, logits per seat (pw_step_logits' row stride), 0]. teams.view.1: [5, 51, 25, 2, 2,
  ## 2, 82, 0]; ffa.view.1 pointer: [5, 11 + control hearts, 9 + cog rows, 2, 2, 2, total, 0].
  ## 0, or -1 (and -1 under the seven-head aim-offset contract: use pw_action_layout_ext).
  if handle == nil or output == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  let heads = env.actionHeads
  if heads.len > ActionSizes.len: return -1
  output[0] = heads.len.int32
  for i, h in heads: output[1+i] = h.int32
  output[6] = env.logitWidth.int32
  output[7] = 0
  0

proc pw_action_layout_ext*(handle: pointer, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## The handle's action heads, 10 int32: [heads (5 or 7), the head sizes (7 slots, 0 past
  ## the last head), logits per seat, 0]. teams.view.1 aim-offset: [7, 51, 25, 2, 2, 2, 23,
  ## 23, 128, 0]. 0, or -1 bad args (and -1 under the nine-head movement-offset contract: use
  ## pw_action_layout_ext2).
  if handle == nil or output == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  let heads = env.actionHeads
  if heads.len > ActionSizesOffset.len: return -1
  for i in 0..<10: output[i] = 0
  output[0] = heads.len.int32
  for i, h in heads: output[1+i] = h.int32
  output[8] = env.logitWidth.int32
  0

proc pw_action_layout_ext2*(handle: pointer, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## The handle's action heads, 12 int32: [heads (5, 7 or 9), the head sizes (9 slots, 0 past
  ## the last head), logits per seat, 0]. teams.view.1 movement-offset: [9, 51, 25, 2, 2, 2,
  ## 23, 23, 23, 23, 174, 0]. 0, or -1 bad args.
  if handle == nil or output == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  let heads = env.actionHeads
  if heads.len > ActionSizesMove.len: return -1
  for i in 0..<12: output[i] = 0
  output[0] = heads.len.int32
  for i, h in heads: output[1+i] = h.int32
  output[10] = env.logitWidth.int32
  0

proc pw_set_action_contract*(handle: pointer, version: int32): cint {.exportc, cdecl, dynlib.} =
  ## The action contract pw_step reads the caller's heads under: on a 201 handle 11
  ## (teams.view.1, five heads per seat; the default) or 13 (teams.view.1 aim-offset, seven
  ## heads per seat: the five, then two 23-bin aim offsets the reference decoder adds to an
  ## identity aim) or 14 (teams.view.1 movement-offset, nine heads per seat: those seven, then
  ## two 23-bin offsets the reference decoder adds to the movement goal); on a 202 handle 12
  ## only. Kept across pw_reset; every decoder seat starts over. 0, or -1 bad args.
  if handle == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if version notin [acTeamsView1.int32, acFfaView1Pointer.int32, acTeamsView1Offset.int32,
      acTeamsView1Move.int32]: return -1
  let contract = ActionContractVersion(version)
  if not pairs(env.obsVersion, contract): return -1
  env.actionContract = contract
  env.resetDecoders()
  0

proc pw_user_inputs_contract_hash*(userInputs: int32, output: ptr UncheckedArray[char],
    capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## The 64-hex SHA-256 of observation contract teams.view.1u<K> (K = userInputs, 1 .. 256),
  ## the hash an actor and manifest with K user inputs carry, NUL-terminated (capacity >= 65).
  ## 0, or -1 bad args.
  if output == nil or capacity < 65 or userInputs notin 1'i32..MaxUserInputs.int32: return -1
  let hash = userInputsContractHash(userInputs.int)
  for i, c in hash: output[i] = c
  output[hash.len] = '\0'
  0

proc pw_user_inputs_contract_hash_v*(obsVersion, userInputs: int32, output: ptr UncheckedArray[char],
    capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## pw_user_inputs_contract_hash with the base contract named: 201 = teams.view.1u<K>,
  ## 202 = ffa.view.1u<K> ("paintbot-pw.ffa.view.1u<K>"). -1 for another version or bad args.
  if obsVersion == ocTeamsView1.int32: return pw_user_inputs_contract_hash(userInputs, output, capacity)
  if obsVersion != ocFfaView1.int32: return -1
  if output == nil or capacity < 65 or userInputs notin 1'i32..MaxUserInputs.int32: return -1
  let hash = userInputsContractHash(userInputs.int, ocFfaView1)
  for i, c in hash: output[i] = c
  output[hash.len] = '\0'
  0

proc pw_observation_contract_hash*(obsVersion: int32, output: ptr UncheckedArray[char],
    capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## The 64-hex SHA-256 an actor and manifest carry for observation contract
  ## `obsVersion`, NUL-terminated; capacity must be >= 65. 0, or -1 bad args.
  if output == nil or capacity < 65 or obsVersion notin NativeObservationVersions: return -1
  let hash = observationContractHash(obsContract(obsVersion))
  for i, c in hash: output[i] = c
  output[hash.len] = '\0'
  0

proc pw_destroy*(handle: pointer) {.exportc, cdecl, dynlib.} =
  if handle == nil: return
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  `=destroy`(env[])
  deallocShared(env)

proc pw_reset*(handle: pointer, seed, maxTicks: int32): cint {.exportc, cdecl, dynlib.} =
  if handle == nil or maxTicks < 0 or maxTicks > HeartMeterMatchTicks: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  try:
    env.newEnvWorld(seed, maxTicks)
    for i in 0..<env.n: env.resets[i] = 1
    env.resetStats()
    env.resetScripts()
    env.resetCurriculum()
    env.resetDecoders()
    env.resetSampling()
    env.labelMemory.resetLabelMemory()
    for slot in 0..<env.n:
      env.commandPending[slot] = false
      env.commandShown[slot] = false
    return 0
  except CatchableError: return -1

proc observeSeats(env: ptr NativeEnv, chosen: proc(slot: int): bool, observations, resets: FloatBuffer) =
  ## Encode the chosen seats' rows (row s at s * rowWidth) from each seat's SeatView of the
  ## current world, leaving the others as they are. teams.view.1u<K> / ffa.view.1u<K>: the
  ## row, then the seat's user inputs as its policy.bas left them (zeros for a seat without them).
  let n = env.rowWidth
  beginViews(env.world)
  for slot in 0..<env.n:
    if not chosen(slot): continue
    let view = seatView(slot)
    template row: untyped = observations.toOpenArray(slot*n, (slot+1)*n-1)
    var inputs = newSeq[int32](env.userInputs)
    let bot = env.scriptBots[slot]
    if env.userInputs > 0 and env.policy[slot] and bot != nil and bot.neural != nil:
      for i in 0..<min(inputs.len, bot.neural.userInputs.len): inputs[i] = bot.neural.userInputs[i]
    if env.obsVersion == ocFfaView1:
      encodeObservation(view, ocFfaView1, row, inputs, rows = ffaViewRows(view), mask = env.obsMask)
    else:
      encodeObservation(view, ocTeamsView1, row, inputs)
    resets[slot] = env.resets[slot]

proc pw_observe_seats*(handle: pointer, seats: uint32, observations, resets: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## Encode only the seats whose bit is set; the other seats' buffer rows are left as
  ## they are. A host training one side against built-in bots need not pay for the
  ## bots' observations. Bit s is slot s (seats 0 .. 31; a seat from 32 on is never chosen
  ## here: pw_observe encodes every seat). Same bytes as pw_observe for chosen seats.
  if handle == nil or observations == nil or resets == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  try:
    env.observeSeats(proc(slot: int): bool = slot < 32 and (seats and (1'u32 shl slot)) != 0,
      observations, resets)
    return 0
  except CatchableError: return -1

proc pw_observe*(handle: pointer, observations, resets: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## Every seat's row (seat s at s * pw_handle_observation_size) and reset flag.
  if handle == nil or observations == nil or resets == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  try:
    env.observeSeats(proc(slot: int): bool = true, observations, resets)
    return 0
  except CatchableError: return -1

proc stepEnv(env: ptr NativeEnv, actions: ActionBuffer, rewards, terminals: FloatBuffer,
    logits: FloatBuffer): cint
proc pw_step*(handle: pointer, actions: ActionBuffer, rewards, terminals: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## Settled score reward only, normalized by 1000. Optional shaping belongs in
  ## the training adapter, never hidden in the game ABI. No implicit auto-reset.
  ## FFA-kin (pw_set_game_mode): every tick pays each seat, dead ones included, its
  ## kin-weighted score change (R_i(t) - R_i(t-1)) / 4320, R_i = sum_j r_ij s_j in points,
  ## so a match's rewards sum to R_i / 4320 (pw_reward_split has the own/kin parts).
  ## Caller-driven seats (no script, no raw command, or a script under an override mask):
  ## the five head choices in `actions` are decoded by the reference decoder script
  ## (players/neural_decode.bas; neural_decode_ffa.bas under ffa.view.1 pointer) through the
  ## seat's SeatView, exactly as a hosted policy.bas would decode them: the model's output
  ## reaches the engine only through BASIC. -1 for an index outside its head.
  ## -3: a live caller-driven seat chose a movement index its forbid mask lists
  ## (pw_set_seat_forbid_objectives); nothing is stepped.
  ## -4: a policy seat is installed (pw_set_seat_policy_script); step with
  ## pw_step_logits instead; nothing is stepped. Buffers hold one row per seat of the
  ## current world (rewards and terminals n floats, actions n x 5).
  if handle == nil or actions == nil or rewards == nil or terminals == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if env.policyCount > 0: return -4
  stepEnv(env, actions, rewards, terminals, nil)

proc pw_step_logits*(handle: pointer, actions: ActionBuffer, logits, rewards,
    terminals: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## pw_step for a handle with policy seats: `logits` holds n x 82 floats in seat order (n = pw_seats),
  ## and each policy seat's row is what run_neural_net yields to its policy.bas this tick
  ## (the trainer ran the actor on the seat's pw_observe row). Sampling, every decoder
  ## option, masks, temperatures and the command are the script's, on the seat's own
  ## streams, exactly as the hosted seat plays; read what it executed with
  ## pw_seat_policy_choices. Other seats' rows are ignored and every other seat steps as
  ## under pw_step. Same return codes as pw_step.
  if handle == nil or actions == nil or logits == nil or rewards == nil or terminals == nil: return -1
  ready(handle)
  stepEnv(cast[ptr NativeEnv](handle), actions, rewards, terminals, logits)

proc stepEnv(env: ptr NativeEnv, actions: ActionBuffer, rewards, terminals: FloatBuffer,
    logits: FloatBuffer): cint =
  if env.world.winner != -1 or env.world.tick >= env.world.endTick: return -2
  let heads = env.actionHeads
  for slot in 0..<env.n:
    if env.contract == acFfaView1Pointer: break  # forbid masks name the teams contract's movement indices
    if not env.forbidAny[slot] or env.world.cogs[slot].hp <= 0 or env.commandPending[slot] or
        (env.scripts[slot].len > 0 and env.overrideMask[slot] == 0): continue
    let movement = actions[slot*heads.len]
    if movement in 0'i32..<ActionSizes[0].int32 and env.forbidden[slot][movement]: return -3
  try:
    var commands = newSeq[Command](env.n)
    var wasDead = newSeq[bool](env.n)
    var decoders = newSeq[Bot](env.n)
    for slot in 0..<env.n:
      wasDead[slot] = env.world.cogs[slot].hp <= 0
      if env.commandPending[slot] or (env.scripts[slot].len > 0 and env.overrideMask[slot] == 0): continue
      let bot = env.decoderFor(slot)
      for head, size in heads:
        let choice = actions[slot*heads.len+head]
        if choice < 0 or choice >= size.int32: raise newException(ValueError, "neural action index out of range")
        if head < ActionSizes.len: bot.neural.fedChoices[head] = choice
        else: bot.neural.fedOffsetChoices[head-ActionSizes.len] = choice
      bot.neural.choicesFed = true
      decoders[slot] = bot
    let decoded = decideSeats(decoders, env.world)
    for slot in 0..<env.n:
      if decoders[slot] != nil: commands[slot] = decoded[slot]
    if env.scriptCount > 0:
      # The production tick: every BASIC seat decides on the pre-step world (hearing
      # what was shouted last tick), shouts are delivered for next tick, then the world
      # steps. Unscripted seats hold no bot and shout nothing. A decision already taken
      # for this tick by pw_script_decide is used as it is.
      if not (env.decidedValid and env.decidedTick == env.world.tick):
        if logits != nil:
          let stride = env.logitWidth
          for slot in 0..<env.n:
            let bot = env.scriptBots[slot]
            if not env.policy[slot] or bot == nil or bot.neural == nil: continue
            if bot.neural.fedLogits.len != stride:
              raise newException(ValueError, "policy seat logits do not match the handle's action layout")
            for i in 0..<stride: bot.neural.fedLogits[i] = logits[slot*stride+i]
            bot.neural.logitsFed = true
        try: env.scriptDecide()
        finally:
          for slot in 0..<env.n:
            let bot = env.scriptBots[slot]
            if env.policy[slot] and bot != nil and bot.neural != nil: bot.neural.logitsFed = false
      env.decidedValid = false
      for slot in 0..<env.n:
        if env.scripts[slot].len == 0: continue
        let mask = env.overrideMask[slot]
        if mask == 0:
          commands[slot] = env.decided[slot]
        else:
          var cmd = env.decided[slot]
          let caller = commands[slot]
          if (mask and 1) != 0:
            cmd.walk = caller.walk; cmd.goal = caller.goal; cmd.direct = caller.direct
          if (mask and 2) != 0: cmd.aim = caller.aim
          if (mask and 4) != 0: cmd.shoot = caller.shoot
          if (mask and 8) != 0: cmd.chargeGrenade = caller.chargeGrenade
          if (mask and 16) != 0: cmd.sneak = caller.sneak
          commands[slot] = cmd
    for slot in 0..<env.n:
      if env.commandPending[slot]:
        # The raw command replaces whatever the seat would have executed (a scripted
        # seat's script has still run and heard/shouted as usual), and is echoed.
        commands[slot] = env.commandNext[slot]
        env.scriptOrders[slot] = env.commandNext[slot]
        env.commandPending[slot] = false
        env.commandShown[slot] = env.scripts[slot].len == 0
      elif env.commandShown[slot]:
        env.scriptOrders[slot] = Command()
        env.commandShown[slot] = false
    for slot in 0..<env.n: env.gateFire(slot, commands[slot])
    let kinStep = env.mode == gmFfaKin
    var preScore, preGreat: seq[int32]
    var preOwners: array[KinHeartSlots, int32]
    var preDormant: array[2, int32]
    if kinStep:
      preScore = env.world.seatScore
      preGreat = env.world.greatShare
      for h in 0..<min(env.world.controlHearts.len, KinHeartSlots): preOwners[h] = env.world.controlHearts[h].owner
      for g in 0..<2: preDormant[g] = env.world.greatHearts[g].dormantUntil
      if not env.pairStatsOff:
        kinEnv = env
        damageObserver = observeKinDamage
    env.labelMemory.recordLabelMemory(env.world)
    combatTelemetry = addr env.stats
    damageScale = addr env.damagePermille
    handicap = addr env.handicapKnobs
    try: env.world.step(commands)
    finally:
      combatTelemetry = nil
      damageScale = nil
      handicap = nil
      damageObserver = nil
      kinEnv = nil
    # pw_seat_equip_stats: ticks each seat ends disguised (telemetry only).
    for slot in 0..<env.n:
      if env.world.uniforms[slot]: inc env.stats[slot].disguisedTicks
    let done = env.world.winner != -1 or env.world.tick >= env.world.endTick
    if kinStep:
      # FFA-kin: the dense kin-weighted score reward, every seat, dead ones included.
      env.kinAfterStep(preScore, preGreat, preOwners, preDormant, wasDead, rewards)
    for slot in 0..<env.n:
      if not kinStep:
        rewards[slot] = if done: float32(env.world.glory[team(slot)])/1000 else: 0
      terminals[slot] = float32(done.int)
      env.resets[slot] = float32((wasDead[slot] or env.world.cogs[slot].hp<=0 or done).int)
    return 0
  except CatchableError: return -1

proc pw_state_hash*(handle: pointer): uint32 {.exportc, cdecl, dynlib.} =
  if handle == nil: return 0
  ready(handle)
  cast[ptr NativeEnv](handle).world.stateHash()

proc pw_results*(handle: pointer, output: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## [tick, winner, glory0, glory1, meter0, meter1, hearts0, hearts1].
  ## FFA-kin: [tick, winner (-1 playing, -3 ended), seats still in the match, total raw
  ## score (sum of s_j, points), best R_i (points), the seat holding it (lowest on a tie),
  ## control hearts owned by any seat, great-heart bounty paid in total (points)].
  if handle == nil or output == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  template w: untyped = env.world
  output[0] = w.tick.float32
  output[1] = w.winner.float32
  if cast[ptr NativeEnv](handle).mode == gmFfaKin:
    let scores = w.scores()
    var standing, owned = 0
    var raw, great = 0'i64
    var best = 0
    for i in 0..<env.n:
      if w.cogs[i].hp > 0 or w.equipment[i].lives > 0: inc standing
      raw += w.seatScore[i]
      great += w.greatShare[i]
      if scores[i] > scores[best]: best = i
    for heart in w.controlHearts:
      if heart.owner >= 0: inc owned
    output[2] = standing.float32
    output[3] = float32(raw) / 10
    output[4] = scores[best].float32
    output[5] = best.float32
    output[6] = owned.float32
    output[7] = float32(great) / 10
    return 0
  for side in 0..1:
    output[2+side] = w.glory[side].float32
    output[4+side] = w.scoreTicks[side].float32 / TickRate.float32
    var hearts = 0
    for heart in w.controlHearts:
      if heart.owner == side.int32: inc hearts
    output[6+side] = hearts.float32
  return 0

proc pw_bot_actions*(handle: pointer, side, level: cint,
    actions: ActionBuffer): cint {.exportc, cdecl, dynlib.} =
  ## Write only the selected team's slots in a full 16-seat action buffer (rows of the
  ## handle's head count; the aim-offset heads, when present, get the centre bin 11).
  ## -1 in FFA-kin (the built-in bot plays sides; use pw_set_seat_script with ffa.bas).
  if handle == nil or actions == nil or side notin 0..1 or level notin 1..2: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if env.mode == gmFfaKin or env.n != LegacySeats: return -1
  let stride = env.actionHeads.len
  beginViews(env.world)
  for slot in 0..<env.n:
    if team(slot) == side:
      trainingBotActions(seatView(slot),level.int,
        actions.toOpenArray(slot*stride,slot*stride+ActionSizes.len-1))
      for head in ActionSizes.len..<stride: actions[slot*stride+head] = AimOffsetCentre.int32
  return 0

proc pw_seat_stats*(handle: pointer, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Per-seat combat telemetry, n seats (pw_seats; 16 unless pw_set_seats) x 8 int32 in seat order:
  ## [damage_dealt_enemy, damage_dealt_team, hits_enemy, hits_taken, kills, deaths,
  ##  captures, first_friendly_fire_tick (-1 if none)]. Cumulative since the last
  ## create/reset. Damage is health removed (armor absorbs first); a hit is a damage
  ## event past shield and life checks; captures are the world's own credit for
  ## flipping a heart. Pure telemetry: reading or ignoring it changes no state.
  if handle == nil or output == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  for slot in 0..<env.n:
    let s = env.stats[slot]
    let o = slot*8
    output[o] = s.damageDealtEnemy; output[o+1] = s.damageDealtTeam
    output[o+2] = s.hitsEnemy; output[o+3] = s.hitsTaken
    output[o+4] = s.kills; output[o+5] = s.deaths
    output[o+6] = env.world.cogs[slot].captures; output[o+7] = s.firstFriendlyFireTick
  return 0

proc pw_set_game_mode*(handle: pointer, mode: int32): cint {.exportc, cdecl, dynlib.} =
  ## 0 = the teams game (default), 1 = FFA-kin. Kept across resets and applied at the next
  ## pw_reset (the current world keeps its mode). 0, or -1 bad args (FFA-kin on an
  ## observation contract teams.view.1 handle included: teams.view.1 is the teams game's).
  if handle == nil or mode notin 0'i32..1'i32: return -1
  if mode == 1 and cast[ptr NativeEnv](handle).obsVersion == ocTeamsView1: return -1
  cast[ptr NativeEnv](handle).nextMode = GameMode(mode)
  0

proc pw_game_mode*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## The current world's mode (0 teams, 1 FFA-kin); -1 for nil.
  if handle == nil: return -1
  cast[ptr NativeEnv](handle).mode.cint

proc pw_map_count*(): cint {.exportc, cdecl, dynlib.} =
  ## The number of maps pw_set_map accepts (MapNames), besides -1 for the rules' own island.
  MapNames.len.cint

proc pw_map_name*(index: cint, output: ptr UncheckedArray[char], capacity: cint): cint {.exportc, cdecl, dynlib.} =
  ## MapNames[index], NUL-terminated ("" for -1, the rules' own island); capacity must hold the
  ## name and its NUL (32 always does). 0, or -1 bad args.
  if output == nil or index notin -1'i32..MapNames.high.int32: return -1
  let name = if index < 0: "" else: MapNames[index]
  if capacity <= name.len: return -1
  for i, c in name: output[i] = c
  output[name.len] = '\0'
  0

proc pw_set_map*(handle: pointer, index: cint): cint {.exportc, cdecl, dynlib.} =
  ## The map for this handle's worlds from its NEXT pw_reset on: -1 = the rules' own island
  ## (the default), 0 .. pw_map_count()-1 = MapNames[index]. Kept across resets; the current
  ## world keeps its map until then. Handles on one thread may play different maps. 0, or -1
  ## bad args.
  if handle == nil or index notin -1'i32..MapNames.high.int32: return -1
  cast[ptr NativeEnv](handle).nextMapSlot = index+1
  0

proc pw_map*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## The current world's map: an index into MapNames, -1 for the rules' own island; -2 for nil.
  if handle == nil: return -2
  cint(cast[ptr NativeEnv](handle).mapSlot-1)

proc writeMessage(output: ptr UncheckedArray[char], capacity: cint, message: string)
proc pw_rules_latest*(): cint {.exportc, cdecl, dynlib.} =
  ## The newest rules pw_set_rules accepts: the rules live games play (sim.LiveRules).
  LiveRules.cint

proc pw_set_rules*(handle: pointer, version: cint): cint {.exportc, cdecl, dynlib.} =
  ## The rules for this handle's worlds from its NEXT pw_reset on: NativeRules (40, the
  ## default) .. pw_rules_latest(). Kept across resets; the current world keeps its rules.
  ## 0, or -1 bad args.
  if handle == nil or version notin NativeRules.cint..LiveRules.cint: return -1
  cast[ptr NativeEnv](handle).nextRules = version
  0

proc pw_rules*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## The current world's rules; -1 for nil.
  if handle == nil: return -1
  cast[ptr NativeEnv](handle).rulesVersion.cint

proc pw_set_config_json*(handle: pointer, json: ptr UncheckedArray[char], length: int32,
    error: ptr UncheckedArray[char], capacity: cint): cint {.exportc, cdecl, dynlib.} =
  ## A whole Coworld game config object (a manifest variant's game_config, verbatim), read by
  ## the host's own parser (match_config.parseMatchConfig): mode, kin_layout, glory, map,
  ## vision and vision_range; its seating and length keys (tokens, players, slots, seed, max_ticks) are
  ## accepted and ignored, since a handle's seats and match length come from its own calls.
  ## Every match key it has not got takes the host's default, except "map": without it the
  ## handle keeps its map (pw_set_map's, or an earlier config's); "map": "" is the island. They
  ## replace the handle's mode, kin layout, map, vision, vision range and glory awards from its NEXT pw_reset
  ## on (the current world keeps its own), as pw_set_game_mode, pw_set_kin_layout and pw_set_map
  ## do; the rules stay pw_set_rules'. 0; -1 bad args; -2 a config the host would refuse (or an
  ## FFA-kin config on an observation contract teams.view.1 handle), with its reason in `error`
  ## (NUL-terminated, truncated to capacity; "" on success; may be NULL).
  if handle == nil or length < 0 or (length > 0 and json == nil): return -1
  var text = newString(length.int)
  if length > 0: copyMem(addr text[0], json, length.int)
  let config =
    try: parseMatchConfig(parseJson(text))
    except CatchableError as e:
      writeMessage(error, capacity, e.msg)
      return -2
  let env = cast[ptr NativeEnv](handle)
  if config.mode == gmFfaKin and env.obsVersion == ocTeamsView1:
    # Observation contract teams.view.1 is the teams game's, as pw_set_game_mode refuses it too.
    writeMessage(error, capacity, "observation contract teams.view.1 is for the teams game only")
    return -2
  env.nextMode = config.mode
  env.kinLayout = if config.kinLayout.isSome: config.kinLayout.get.ord.int32 else: -1
  # A config without "map" keeps the handle's map (pw_set_map), so a trainer can draw maps
  # per reset under one config; "map": "" is the island.
  if config.mapGiven: env.nextMapSlot = int32(mapIndex(config.map)+1)
  env.nextVision = config.vision == "team"
  env.nextVisionRange = config.visionRange.int32
  env.nextGlory = config.glory
  writeMessage(error, capacity, "")
  0

proc pw_set_kin_layout*(handle: pointer, layout: int32): cint {.exportc, cdecl, dynlib.} =
  ## FFA kin layout for the next resets: -1 = drawn from the seed by weight (default), else
  ## 0 fours, 1 pairs, 2 trios + loner, 3 cousins, 4 strangers, 5 clones, 6 tribes (families and genes
  ## still from the seed, kinship.kinshipFor). Kept across resets, applied at the next
  ## pw_reset; pw_set_kin_override wins over it. 0, or -1 bad args.
  if handle == nil or layout notin -1'i32..KinLayout.high.ord.int32: return -1
  cast[ptr NativeEnv](handle).kinLayout = layout
  0

proc pw_kin*(handle: pointer, output: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## The current world's relatedness, n x n floats row-major (n = pw_seats, 16 unless
  ## pw_set_seats): output[n*i + j] = r(i, j) (1 on the diagonal in FFA; all zero in the
  ## teams game). 0, or -1 bad args.
  if handle == nil or output == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  for i in 0..<env.n:
    for j in 0..<env.n: output[i*env.n+j] = float32(env.kinship.r(i, j))
  0

proc pw_genes*(handle: pointer, output: ptr UncheckedArray[uint32]): cint {.exportc, cdecl, dynlib.} =
  ## The current world's genomes, n uint32 (n = pw_seats; bit b = locus b; zero in the teams game).
  if handle == nil or output == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  for i in 0..<env.n: output[i] = env.kinship.genes[i]
  0

proc pw_scores*(handle: pointer, output: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## The world's results.scores, n floats (n = pw_seats): in FFA-kin R_i = sum_j r_ij s_j in
  ## points; in the teams game each seat's team score (sim.scores). 0, or -1 bad args.
  if handle == nil or output == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  let scores = env.world.scores()
  for i in 0..<env.n: output[i] = float32(scores[i])
  0

proc pw_reward_split*(handle: pointer, output: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## The last pw_step's FFA reward per seat in two parts, 2n floats (n = pw_seats) {own_0, kin_0, own_1,
  ## kin_1, ...}, in reward units: own = r_ii * delta s_i / 4320, kin = sum_{j != i} r_ij *
  ## delta s_j / 4320 (points); own + kin is the reward pw_step paid. Zeros before the first
  ## FFA step of a match and in the teams game. 0, or -1 bad args.
  if handle == nil or output == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  for i in 0..<env.n:
    output[2*i] = env.kin.split[i][0]
    output[2*i+1] = env.kin.split[i][1]
  0

proc pw_pair_stats*(handle: pointer, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## FFA-kin pair counters, cumulative since the last create/reset, n x n x PairStatCount
  ## int32 (n = pw_seats): output[(n*i + j) * 13 + stat] is i's count about j, stats in PairStat order
  ## (psVisible .. psHeartPass; native_env.h lists them). Telemetry only, never hashed;
  ## all zero in the teams game. 0, or -1 bad args.
  if handle == nil or output == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  for i in 0..<env.n:
    for j in 0..<env.n:
      for stat in PairStat:
        output[(i*env.n+j)*PairStatCount+stat.ord] = env.kin.pair[i][j][stat]
  0

proc pw_kin_seat_stats*(handle: pointer, output: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## FFA-kin per seat, n x 3 floats (n = pw_seats) {death_tick (-1 alive), own-part return, kin-part
  ## return}; the returns are the match's cumulative pw_reward_split parts. 0, or -1.
  if handle == nil or output == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  for i in 0..<env.n:
    output[3*i] = float32(env.kin.deathTick[i])
    output[3*i+1] = float32(env.kin.ownReturn[i])
    output[3*i+2] = float32(env.kin.kinReturn[i])
  0

proc pw_set_spawn_grouping*(handle: pointer, groups: ptr UncheckedArray[int8]): cint {.exportc, cdecl, dynlib.} =
  ## Eval only: FFA spawn groups independent of the kinship, 16 int8 (a group id 0..15,
  ## -1 = spawns alone); NULL clears. Applied at the next pw_reset and kept until cleared.
  ## Only FFA spawn placement reads it, and only in a 16-seat world. 0, or -1 bad args.
  if handle == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  if groups == nil:
    env.spawnGrouping = none(array[LegacySeats, int8])
    return 0
  var g: array[LegacySeats, int8]
  for i in 0..<LegacySeats:
    if groups[i] notin -1'i8..int8(LegacySeats-1): return -1
    g[i] = groups[i]
  env.spawnGrouping = some(g)
  0

proc pw_set_kin_override*(handle: pointer, family: ptr UncheckedArray[int8],
    genes: ptr UncheckedArray[uint32], ibd: ptr UncheckedArray[int8]): cint {.exportc, cdecl, dynlib.} =
  ## Eval only: an exact FFA kinship for the next resets (the r sweep, label swaps); its
  ## layout field is only a label (pw_set_kin_layout's value, else fours) and changes nothing:
  ## family int8[16] (-1..15; spawn groups unless pw_set_spawn_grouping is set), genes
  ## uint32[16], ibd int8[256] row-major loci shared by descent (0..32, symmetric, 32 on the
  ## diagonal; r = ibd / 32). family NULL clears. Applied at the next pw_reset, kept until
  ## cleared, wins over pw_set_kin_layout; a 16-seat table, applied to 16-seat worlds only.
  ## 0, or -1 bad args.
  if handle == nil: return -1
  let env = cast[ptr NativeEnv](handle)
  if family == nil:
    env.kinOverride = none(Kinship)
    return 0
  if genes == nil or ibd == nil: return -1
  var k = initKinship(LegacySeats)
  k.layout = if env.kinLayout >= 0: KinLayout(env.kinLayout) else: klFours
  for i in 0..<LegacySeats:
    if family[i] notin -1'i8..int8(LegacySeats-1): return -1
    k.family[i] = family[i]
    k.genes[i] = genes[i]
    for j in 0..<LegacySeats:
      let v = ibd[i*LegacySeats+j]
      if v notin 0'i8..Loci.int8 or v != ibd[j*LegacySeats+i] or (i == j and v != Loci.int8): return -1
      k.ibd[i][j] = v
  env.kinOverride = some(k)
  0

proc pw_set_pair_stats_enabled*(handle: pointer, enabled: int32): cint {.exportc, cdecl, dynlib.} =
  ## FFA pair counters on (1, the default) or off (0): off skips pw_pair_stats' per-tick
  ## work and the damage hook (the counters then stop growing; nothing is cleared). The
  ## reward, pw_reward_split, the returns and the death ticks are always kept. Takes effect
  ## on the next pw_step; kept across resets. 0, or -1 bad args.
  if handle == nil or enabled notin 0'i32..1'i32: return -1
  cast[ptr NativeEnv](handle).pairStatsOff = enabled == 0
  0

proc pw_set_obs_mask*(handle: pointer, flags: uint32): cint {.exportc, cdecl, dynlib.} =
  ## Eval only: ffa.view.1 observation ablations, read by the next pw_observe (kept across
  ## resets). Bit 0 zeroes every column that reads kin (cog column 37, a heart owned by
  ## another seat's column 5, header column 11): the genes-only ablation. Other bits are
  ## rejected. 0, or -1.
  if handle == nil or (flags and not FfaObsMaskKin) != 0: return -1
  cast[ptr NativeEnv](handle).obsMask = flags
  0

proc pw_set_seat_script*(handle: pointer, seat: cint, source: ptr UncheckedArray[char],
    length: int32): cint {.exportc, cdecl, dynlib.} =
  ## Drive one seat from BASIC source text with the production interpreter, host
  ## functions, limits and per-decision budget; the caller's actions for that seat are
  ## ignored while a script is installed. Compiles now; a fresh runtime with cleared
  ## persistent variables is installed here and again on every pw_reset. length 0
  ## removes the script. Returns 0 (running), 1 (compile failed: the seat is disabled and
  ## idles, as a hosted seat would), -1 (bad arguments). The host functions are the current
  ## world's mode's (FFA-kin adds kin, gene, ...): the source is compiled now against the
  ## current world, and again at every pw_reset after the pending mode is applied, so an
  ## FFA script set before the reset that switches the mode compiles at that reset.
  if handle == nil or seat notin 0..<seatsOf(handle) or length < 0 or (length > 0 and source == nil): return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if env.scripts[seat].len > 0: dec env.scriptCount
  if env.policy[seat]:
    env.policy[seat] = false
    env.policyManifests[seat] = ""
    dec env.policyCount
  env.scripts[seat] = newString(length)
  if length > 0: copyMem(addr env.scripts[seat][0], source, length)
  env.sizeHeard()
  env.scriptHeard[seat] = @[]
  env.installScript(seat)
  if env.scripts[seat].len > 0: inc env.scriptCount
  if env.scriptStatus[seat] == 2: 1 else: 0

proc pw_seat_script_status*(handle: pointer, seat: cint, message: ptr UncheckedArray[char],
    capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## 0 unscripted, 1 running, 2 compile failed, 3 disabled by a runtime error (budget
  ## overrun, bad host call, ...), exactly the errors that disable a hosted seat. The
  ## error text is copied, NUL-terminated and truncated to capacity, when given.
  if handle == nil or seat notin 0..<seatsOf(handle): return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if message != nil and capacity > 0:
    let n = min(capacity.int-1, env.scriptErrors[seat].len)
    if n > 0: copyMem(message, unsafeAddr env.scriptErrors[seat][0], n)
    message[n] = '\0'
  env.scriptStatus[seat]

proc pw_set_seat_policy_script*(handle: pointer, seat: cint, source: ptr UncheckedArray[char], length: int32,
    manifest: ptr UncheckedArray[char], manifestLength: int32): cint {.exportc, cdecl, dynlib.} =
  ## Drive one seat with a bundle's policy.bas under its manifest.json exactly as the
  ## hosted neural seat plays it: same interpreter, host functions, limits and budget; the
  ## manifest's selection options, user inputs and action contract; the seat's own sampling
  ## stream seeded from the match seed and slot. There is no actor: run_neural_net yields
  ## the logits the trainer passes for the seat to pw_step_logits (pw_step returns -4 while
  ## any policy seat is installed). The manifest's observation_contract must be this
  ## handle's (teams.view.1, ffa.view.1, or either's u<K> from pw_create_observation_inputs /
  ## _v). The seat is rebuilt on every pw_reset; length 0 removes it. Per-seat
  ## selection setters (pw_set_seat_sampling, ...) do not apply to a policy seat: its
  ## manifest governs. Returns 0 (running), 1 (compile
  ## failed), 2 (manifest rejected; the seat idles, as a hosted seat whose package fails),
  ## -1 (bad arguments); the error text is pw_seat_script_status's.
  if handle == nil or seat notin 0..<seatsOf(handle) or length < 0 or (length > 0 and source == nil) or
      manifestLength < 0 or (manifestLength > 0 and manifest == nil): return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if env.scripts[seat].len > 0: dec env.scriptCount
  if env.policy[seat]: dec env.policyCount
  env.scripts[seat] = newString(length)
  if length > 0: copyMem(addr env.scripts[seat][0], source, length)
  env.policy[seat] = length > 0
  env.policyManifests[seat] = if length > 0: newString(manifestLength) else: ""
  if length > 0 and manifestLength > 0: copyMem(addr env.policyManifests[seat][0], manifest, manifestLength)
  env.sizeHeard()
  env.scriptHeard[seat] = @[]
  env.installScript(seat)
  if env.scripts[seat].len > 0:
    inc env.scriptCount
    inc env.policyCount
  if env.scriptStatus[seat] == 2:
    (if env.scriptErrors[seat].startsWith("policy manifest rejected"): 2 else: 1)
  else: 0

proc pw_set_seat_conditionals*(handle: pointer, seat: cint, count: int32, heads: ptr UncheckedArray[int32],
    weights: FloatBuffer, weightCount: int32): cint {.exportc, cdecl, dynlib.} =
  ## A policy seat's learned conditional heads (the model's COND_HEAD layers, neural_actor.md),
  ## which the trainer holds: `count` pairs (condition head, re-selected head) in `heads`
  ## [2*count], and their weights concatenated in that order in `weights` (each
  ## size(head) x size(condition head), row-major). They replace the seat's previous ones, apply
  ## from its next selection, and stay across pw_reset until set again (count 0 clears them).
  ## Returns 0, -1 for bad arguments or a seat that is not a policy seat, -2 when the heads or
  ## weights break COND_HEAD's rules (or the manifest asks for decoder.joint_sampling).
  if handle == nil or seat notin 0..<seatsOf(handle) or count < 0 or count > 32 or weightCount < 0 or
      (count > 0 and heads == nil) or (weightCount > 0 and weights == nil): return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if not env.policy[seat]: return -1
  var conditionals: seq[Conditional]
  var at = 0
  let bot = env.scriptBots[seat]
  let sizes = if bot != nil and bot.neural != nil: bot.neural.heads else: @ActionSizes
  for k in 0..<count.int:
    var c = Conditional(whenHead: heads[2*k].int, head: heads[2*k+1].int)
    if c.whenHead notin 0..<sizes.len or c.head notin 0..<sizes.len: return -2
    let n = sizes[c.head]*sizes[c.whenHead]
    if at + n > weightCount.int: return -2
    for i in 0..<n: c.weights.add weights[at+i].float32
    at += n
    conditionals.add c
  if at != weightCount.int: return -2
  try:
    checkConditionals(conditionals, sizes)
    if bot != nil and bot.neural != nil: bot.neural.setConditionals(conditionals)
  except ValueError: return -2
  env.policyConditionals[seat] = conditionals
  0

proc pw_seat_policy_choices*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## What a policy seat's script executed on the last pw_step_logits, 22 int32:
  ## [decided, selected[5], final[5], temperature_milli[5], mask0_lo, mask0_hi, mask1,
  ##  mask2, mask3, mask4]. decided = 1 when the script made its selection that step
  ## (neuralSample; 0 for a dead or disabled seat, or a script that did not select).
  ## selected = the heads drawn under the applied masks and temperatures (before
  ## neuralSetChoice): the ones whose log-probability the trainer takes under that masked,
  ## tempered distribution. final = the choices after the script's neuralSetChoice calls
  ## (what it reports it acted on). temperature_milli: 0 = argmax, else the head's temperature x 1000
  ## (rounded). mask bits: choice i of the head is excluded when bit i is set (head 0:
  ## choices 0 .. 31 in mask0_lo, 32 .. 50 in mask0_hi's bits 0 .. 18). Returns 0, -1 for
  ## bad arguments or a seat that is not a policy seat.
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if not env.policy[seat]: return -1
  for i in 0..<22: output[i] = 0
  let bot = env.scriptBots[seat]
  if bot == nil or bot.neural == nil or not bot.neural.sampled: return 0
  let n = bot.neural
  output[0] = 1
  for head in 0..<ActionSizes.len:
    output[1+head] = n.selected[head]
    output[6+head] = n.choices[head]
    output[11+head] = n.appliedTemperatures[head]
  proc bits(mask: openArray[bool], first: int): int32 =
    var value = 0'u32
    for bit in 0..31:
      if first+bit < mask.len and mask[first+bit]: value = value or (1'u32 shl bit)
    cast[int32](value)
  output[16] = bits(n.appliedMasks[0].toOpenArray(0, ActionSizes[0]-1), 0)
  output[17] = bits(n.appliedMasks[0].toOpenArray(0, ActionSizes[0]-1), 32)
  for head in 1..<ActionSizes.len:
    output[17+head] = bits(n.appliedMasks[head].toOpenArray(0, ActionSizes[head]-1), 0)
  0

proc pw_seat_policy_offset_choices*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## A policy seat's aim-offset heads (action contract 13) on the last pw_step_logits, six
  ## int32: [selected5, selected6, final5, final6, temperature_milli5, temperature_milli6]
  ## (selected: the draw or argmax; final: after neuralSetChoice); zeros when the seat did not
  ## select. Returns 0, -1 for bad arguments, a seat that is not a policy seat, or a seat
  ## without exactly the two aim-offset heads (a movement-offset seat: use
  ## pw_seat_policy_extra_choices).
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if not env.policy[seat]: return -1
  let bot = env.scriptBots[seat]
  if bot == nil or bot.neural == nil or bot.neural.extraHeads != AimOffsetHeads: return -1
  for i in 0..<6: output[i] = 0
  let n = bot.neural
  if not n.sampled: return 0
  for e in 0..<AimOffsetHeads:
    output[e] = n.offsetSelected[e]
    output[2+e] = n.offsetChoices[e]
    output[4+e] = n.appliedOffsetTemperatures[e]
  0

proc pw_seat_policy_extra_choices*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## A policy seat's extra heads (5 .. 8: the aim offsets, then under action contract 14 the
  ## movement offsets) on the last pw_step_logits, twelve int32: [selected5 .. selected8,
  ## final5 .. final8, temperature_milli5 .. temperature_milli8], zeros for a head the seat's
  ## contract lacks and when the seat did not select. Returns 0, -1 for bad arguments, a seat
  ## that is not a policy seat, or a seat without extra heads.
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if not env.policy[seat]: return -1
  let bot = env.scriptBots[seat]
  if bot == nil or bot.neural == nil or not bot.neural.offsetHeads: return -1
  for i in 0..<3*ExtraHeadsMax: output[i] = 0
  let n = bot.neural
  if not n.sampled: return 0
  for e in 0..<n.extraHeads:
    output[e] = n.offsetSelected[e]
    output[ExtraHeadsMax+e] = n.offsetChoices[e]
    output[2*ExtraHeadsMax+e] = n.appliedOffsetTemperatures[e]
  0

proc pw_seat_orders*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## The command a scripted seat issued on the last pw_step, ten int32:
  ## [walk, goal_x, goal_z, shoot, aim_x, aim_z, charge_grenade, sneak, direct, scripted].
  ## walkTo sets walk+goal; lookAt sets aim; shootAt sets shoot+aim (the last call of
  ## each kind wins, as in the game). aim (0,0) means no aim order, as the game reads
  ## it. A seat given a raw command (pw_set_seat_command) for the last step reports that
  ## command instead. Other unscripted seats report zeros with scripted=0.
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  let c = env.scriptOrders[seat]
  output[0] = c.walk.int32; output[1] = c.goal.x; output[2] = c.goal.z
  output[3] = c.shoot.int32; output[4] = c.aim.x; output[5] = c.aim.z
  output[6] = c.chargeGrenade.int32; output[7] = c.sneak.int32; output[8] = c.direct.int32
  output[9] = int32(env.scripts[seat].len > 0)
  0

proc pw_set_seat_command*(handle: pointer, seat: cint, nine: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## A raw command for one seat on the next pw_step only, nine int32 in pw_seat_orders'
  ## layout: [walk, goal_x, goal_z, shoot, aim_x, aim_z, charge_grenade, sneak, direct],
  ## the flags 0 or 1. The seat executes exactly this command, built as BASIC's orders
  ## build one: walkTo's goal verbatim (the world clamps where it walks, and stores the
  ## point), lookAt/shootAt's aim clamped to the map (aim (0,0) = no aim order). A harness
  ## tool (replays, probes), not a seat: for that step the seat's heads are not decoded and
  ## not checked against its forbid mask, and a scripted seat's script still runs but its
  ## order is replaced. The fire period applies only if already set on the seat (off by
  ## default).
  ## pw_seat_orders echoes the command after the step (an unscripted seat reports zeros
  ## again after a step without one). A later call before the step replaces it; pw_reset
  ## drops it. Never calling it is byte-identical to a library without it. Returns 0, -1
  ## for bad arguments.
  if handle == nil or seat notin 0..<seatsOf(handle) or nine == nil: return -1
  for i in [0, 3, 6, 7, 8]:
    if nine[i] notin 0'i32..1'i32: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  env.commandNext[seat] = Command(walk: nine[0] == 1, goal: Point(x: nine[1], z: nine[2]), shoot: nine[3] == 1,
    aim: Point(x: clamp(nine[4], minX().int32, maxX().int32), z: clamp(nine[5], minZ().int32, maxZ().int32)),
    chargeGrenade: nine[6] == 1, sneak: nine[7] == 1, direct: nine[8] == 1)
  env.commandPending[seat] = true
  0

proc pw_action_contract*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## The handle's action contract version: 11 (teams.view.1), 12 (ffa.view.1 pointer) or 13
  ## (teams.view.1 aim-offset); -1 for a bad handle.
  if handle == nil: return -1
  ready(handle)
  cint(cast[ptr NativeEnv](handle).contract)

proc pw_action_contract_hash*(version: int32, output: ptr UncheckedArray[char],
    capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## The 64-hex SHA-256 contract hash an actor and its manifest carry for action contract
  ## `version` (11, 12, 13 or 14), NUL-terminated into output (capacity >= 65). Returns 0, -1
  ## for a bad version (the contracts before these were retired for BASIC parity) or buffer.
  if version notin [acTeamsView1.int32, acFfaView1Pointer.int32, acTeamsView1Offset.int32,
      acTeamsView1Move.int32] or
      output == nil or capacity < 65: return -1
  let hash = actionContractHash(ActionContractVersion(version))
  copyMem(output, unsafeAddr hash[0], hash.len)
  output[hash.len] = '\0'
  0

proc pw_script_decide*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## Diagnostic: run the scripted seats' decision for the current tick now (once;
  ## repeated calls before the next pw_step are no-ops) so pw_seat_orders reports the
  ## orders the coming pw_step will execute. With every override mask 0 the world is
  ## byte-identical whether or not this is called. Returns 1 when a decision was taken,
  ## 0 when nothing was needed, -1 on a bad handle.
  if handle == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if env.policyCount > 0: return -4   # a policy seat decides only with its logits (pw_step_logits)
  if env.scriptCount == 0 or env.world.winner != -1 or env.world.tick >= env.world.endTick: return 0
  if env.decidedValid and env.decidedTick == env.world.tick: return 0
  env.scriptDecide()
  1

proc pw_set_seat_override*(handle: pointer, seat: cint, mask: int32): cint {.exportc, cdecl, dynlib.} =
  ## Diagnostic: heads of a scripted seat taken from the caller's action (decoded by the
  ## reference decoder script, as pw_step decodes a caller-driven seat) instead
  ## of the script's order (bits: 1 walk/goal/direct, 2 aim, 4 shoot, 8 grenade, 16
  ## sneak; 0 = exact script play). Kept across pw_reset like the curriculum knobs.
  if handle == nil or seat notin 0..<seatsOf(handle) or mask < 0 or mask > 31: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  env.overrideMask[seat] = mask
  0

proc pw_set_seat_fire_period*(handle: pointer, seat: cint, period: int32): cint {.exportc, cdecl, dynlib.} =
  ## Curriculum: the seat's shoot order (from its script, the Nim bot, or the caller)
  ## is honoured only when it could fire now and at least `period` weapon cooldown
  ## windows have passed since its last honoured shot. The unit is the gun cooldown
  ## window, FireCooldownTicks = 24 ticks (one second): period 4 means at most one
  ## honoured shot per 96 ticks, the same unit as the adapter's fire-gated Nim bot.
  ## lookAt, movement and everything the script believes are untouched. 1 restores
  ## exact behaviour. Kept across pw_reset; the shot history is not.
  if handle == nil or seat notin 0..<seatsOf(handle) or period < 1: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  env.firePeriod[seat] = period
  0

proc pw_set_seat_damage_scale*(handle: pointer, seat: cint, permille: int32): cint {.exportc, cdecl, dynlib.} =
  ## Curriculum: damage dealt BY this seat is scaled by permille/1000, the fraction
  ## carried to the seat's next hit (500 = every other 1-point gun hit lands; 0 = no
  ## damage). Hits still land (shield, cooldown relief, telemetry, glory as before). 1000
  ## restores exact behaviour. Kept across pw_reset (the carried fraction is not).
  if handle == nil or seat notin 0..<seatsOf(handle) or permille < 0: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  env.damagePermille[seat] = permille
  0

proc pw_set_seat_max_hp*(handle: pointer, seat: cint, hp: int32): cint {.exportc, cdecl, dynlib.} =
  ## Curriculum handicap: the HP this seat spawns and respawns with and a medkit restores,
  ## 1 .. 6; 0 restores the rules' maxHp() (3 in teams). The initial spawn takes it at the
  ## next pw_reset. Kept across pw_reset.
  if handle == nil or seat notin 0..<seatsOf(handle) or hp notin 0'i32..6'i32: return -1
  ready(handle)
  cast[ptr NativeEnv](handle).handicapKnobs.maxHp[seat] = hp
  0

proc pw_set_seat_lives*(handle: pointer, seat: cint, lives: int32): cint {.exportc, cdecl, dynlib.} =
  ## Curriculum handicap: the lives this seat starts a match with, 1 .. 8 (a seat is out after
  ## that many deaths); 0 restores the rules' (4 in teams from rules 19). Applies at the next
  ## pw_reset. Kept across pw_reset.
  if handle == nil or seat notin 0..<seatsOf(handle) or lives notin 0'i32..8'i32: return -1
  ready(handle)
  cast[ptr NativeEnv](handle).handicapKnobs.lives[seat] = lives
  0

proc pw_set_seat_damage_taken*(handle: pointer, seat: cint, permille: int32): cint {.exportc, cdecl, dynlib.} =
  ## Curriculum handicap: damage dealt TO this seat is scaled by permille/1000, its fraction
  ## carried to the next hit (500 = every other 1-point hit lands); applies with
  ## pw_set_seat_damage_scale's attacker scale, whose fraction now carries the same way.
  ## 0 .. 10000; 1000 restores exact behaviour. Kept across pw_reset (the carried fractions
  ## are not).
  if handle == nil or seat notin 0..<seatsOf(handle) or permille notin 0'i32..10000'i32: return -1
  ready(handle)
  cast[ptr NativeEnv](handle).handicapKnobs.damageTaken[seat] = permille
  0

proc pw_set_team_capture_ticks*(handle: pointer, side: cint, ticks: int32): cint {.exportc, cdecl, dynlib.} =
  ## Curriculum handicap: the ticks team `side` (0 or 1) must hold a control heart alone to
  ## capture it in the teams game, 36 .. 144; 0 restores HeartCaptureTicks (72). Kept across
  ## pw_reset.
  if handle == nil or side notin 0..1 or (ticks != 0 and ticks notin 36'i32..144'i32): return -1
  ready(handle)
  cast[ptr NativeEnv](handle).handicapKnobs.captureTicks[side] = ticks
  0

proc pw_set_seat_respawn_ticks*(handle: pointer, seat: cint, ticks: int32): cint {.exportc, cdecl, dynlib.} =
  ## Curriculum handicap: the ticks this seat waits to respawn after a death, 1 .. 1440; 0
  ## restores RespawnTicks (72). Kept across pw_reset.
  if handle == nil or seat notin 0..<seatsOf(handle) or ticks notin 0'i32..1440'i32: return -1
  ready(handle)
  cast[ptr NativeEnv](handle).handicapKnobs.respawnTicks[seat] = ticks
  0

proc pw_set_seat_sampling*(handle: pointer, seat: cint, temperaturePermille, headMask: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder sampling for one seat (the hosted bundle option decoder.sampling): with
  ## temperaturePermille > 0 (10 .. 10000 = 0.01 .. 10.0), pw_sample_actions draws the
  ## heads in headMask (bit h = head h; 0 = every head) from softmax(logits / T) with the
  ## seat's stream and takes argmax for the rest; 0 (the default) makes it plain argmax
  ## with no draw. Only pw_sample_actions is affected: pw_step takes the caller's actions
  ## as before, so a library with this call is byte-identical when it is never made.
  ## Kept across pw_reset (the stream itself is reseeded). Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<seatsOf(handle): return -1
  if temperaturePermille < 0 or temperaturePermille > 10_000 or headMask < 0 or headMask >= (1 shl ActionSizes.len): return -1
  if temperaturePermille != 0 and temperaturePermille < 10: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  var options: SamplingOptions
  if temperaturePermille > 0:
    options.enabled = true
    options.temperature = float32(temperaturePermille) / 1000'f32
    for head in 0..<ActionSizes.len:
      options.heads[head] = headMask == 0 or (headMask and (1 shl head)) != 0
  env.sampling[seat] = options
  0

proc pw_sample_actions*(handle: pointer, seat: cint, logits: FloatBuffer, actions: ActionBuffer): cint {.exportc, cdecl, dynlib.} =
  ## Select the seat's five head actions from 82 logits: the seat's sampling options and
  ## stream (neural_contract.sampleActions; exactly one draw per sampled head, advancing
  ## the stream) or, with sampling off, deterministic argmax and no draw. The actions are
  ## what the caller then hands to pw_step for the seat. Returns 0, -1 for bad arguments
  ## or non-finite logits, and under action contract ffa.view.1 pointer (the caller samples
  ## its match-sized heads itself, or runs a policy seat).
  if handle == nil or seat notin 0..<seatsOf(handle) or logits == nil or actions == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  if env.contract == acFfaView1Pointer: return -1
  try:
    var input: array[LogitSize, float32]
    for i in 0..<LogitSize: input[i] = logits[i]
    let picked = sampleActions(input, env.sampling[seat], env.sampleRng[seat], env.forbidden[seat])
    if env.sampling[seat].enabled: inc env.sampleDraws[seat]
    for head in 0..<ActionSizes.len: actions[head] = picked[head]
    return 0
  except CatchableError: return -1

proc pw_seat_sample_draws*(handle: pointer, seat: cint): cint {.exportc, cdecl, dynlib.} =
  ## Decisions pw_sample_actions drew for the seat since the last create/reset (0 with
  ## sampling off). Pure telemetry. Returns -1 for bad arguments.
  if handle == nil or seat notin 0..<seatsOf(handle): return -1
  ready(handle)
  cint(cast[ptr NativeEnv](handle).sampleDraws[seat])

proc pw_set_seat_forbid_objectives*(handle: pointer, seat: cint, indices: ptr UncheckedArray[int32],
    count: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder objective forbid for one seat (the hosted bundle option
  ## decoder.forbid_objectives): the `count` movement-head indices (distinct, 0..50, at
  ## least one index left allowed) are never selected by pw_sample_actions for the seat
  ## (argmax or draw, as if their logits were -inf), and pw_step returns -3 without
  ## stepping when the caller hands one of them for the seat while it is alive (a dead
  ## seat's actions are ignored by the decoder anyway). count 0 clears (indices may
  ## be NULL). With no seat forbidding anything the library is byte-identical to one
  ## without this call. Kept across pw_reset. Returns 0, -1 for bad arguments (the mask
  ## is then unchanged).
  if handle == nil or seat notin 0..<seatsOf(handle) or count < 0 or count >= ActionSizes[0].int32: return -1
  if count > 0 and indices == nil: return -1
  var mask: ObjectiveMask
  for i in 0..<count.int:
    let index = indices[i]
    if index notin 0'i32..<ActionSizes[0].int32 or mask[index]: return -1
    mask[index] = true
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  env.forbidden[seat] = mask
  env.forbidAny[seat] = mask.forbidsAny
  0

proc pw_seat_forbidden_objectives*(handle: pointer, seat: cint, mask: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## The seat's forbid mask: mask (int32[51], may be NULL) gets 1 for each forbidden
  ## movement-head index and 0 otherwise, the logit mask a trainer applies before it
  ## samples. Returns the number forbidden, -1 for bad arguments.
  if handle == nil or seat notin 0..<seatsOf(handle): return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  var n = 0
  for index in 0..<ActionSizes[0]:
    let on = env.forbidden[seat][index]
    if mask != nil: mask[index] = on.int32
    if on: inc n
  cint(n)

proc pw_seat_spray_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Spray-can combat counters for one seat (training library only), four int32:
  ## [enemy damage, teammate damage, enemy kills, teammate kills] dealt by the seat's spray
  ## since the last create/reset. Damage is health removed (armor absorbs first), as in
  ## pw_seat_stats; attribution is the damage's owner and the spray burst. Pure telemetry.
  ## Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let s = cast[ptr NativeEnv](handle).stats[seat]
  output[0] = s.sprayDamageEnemy
  output[1] = s.sprayDamageTeam
  output[2] = s.sprayKillsEnemy
  output[3] = s.sprayKillsTeam
  0

proc pw_seat_privileged_labels*(handle: pointer, seat: cint, output: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## TRAINING-ONLY supervision labels for one seat on the current pre-step world,
  ## PrivilegedLabelCount = 21 floats (training_labels.privilegedLabels documents each): gun
  ## cooldown, windup, spray cooldown, shield, respawn, aim x, aim z, own and enemy heart
  ## meter, lead valid, lead x, lead z, then 9 traversable probe flags. State no seat can perceive: for auxiliary losses only,
  ## never an input to a policy (the hosted engine has no such call). 0, or -1 bad args.
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  let labels = privilegedLabels(env.world, seat.int, env.labelMemory)
  for i, x in labels: output[i] = x
  0

proc pw_seat_grenade_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Grenade telemetry for one seat (training library only), six int32, cumulative since
  ## the last create/reset: [throws released, enemy hits, enemy kills, enemy health removed,
  ## teammate hits, teammate health removed]. A hit is a blast damage event past the shield
  ## and life checks (pw_seat_stats' rule), attributed to the thrower; kills equal
  ## pw_seat_weapon_stats[1]. Pure telemetry. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let s = cast[ptr NativeEnv](handle).stats[seat]
  for i, v in [s.grenadeThrows, s.grenadeHitsEnemy, s.grenadeKills, s.grenadeDamageEnemy, s.grenadeHitsTeam,
      s.grenadeDamageTeam]:
    output[i] = v
  0

proc pw_seat_damage_taken_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Damage taken by one seat (training library only), eight int32, cumulative since the last
  ## create/reset: [hits, health lost] from enemy guns, enemy grenades, enemy spray, and from
  ## everything else (the seat's own or a teammate's weapon, the map), in that order. A hit is
  ## a damage event past the shield and life checks (pw_seat_stats' hits_taken counts every
  ## one, so the four hit counts sum to it); health lost is after armor (armor's share is
  ## pw_seat_equip_stats[5]). Pure telemetry. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let s = cast[ptr NativeEnv](handle).stats[seat]
  for k in 0..3:
    output[2*k] = s.takenHits[k]
    output[2*k+1] = s.takenHealth[k]
  0

proc pw_seat_equip_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Equipment and disguise telemetry for one seat (training library only), eight int32,
  ## cumulative since the last create/reset: [armor pickups, uniform (disguise) pickups,
  ## medkit pickups, grenade pickups, spray pickups, health its armor soaked (same units as
  ## pw_seat_stats' damage), ticks it ended disguised, enemy kills plus heart captures it
  ## made while disguised]. Pure telemetry. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let s = cast[ptr NativeEnv](handle).stats[seat]
  for i, v in [s.armorPickups, s.uniformPickups, s.medkitPickups, s.grenadePickups, s.sprayPickups,
      s.armorAbsorbed, s.disguisedTicks, s.disguisedKillsCaptures]:
    output[i] = v
  0

proc waterPoint(x, z: int): bool =
  ## The river's water (rules >= 30; SeatView.waterAt's test), clamped to the map.
  let cx = clamp(x, minX(), maxX()); let cz = clamp(z, minZ(), maxZ())
  visionRulesVersion >= 30 and riverBlend(cx, cz) > 0 and terrainHeight(cx, cz) < RiverWaterHeight

proc pw_heart_terrain*(handle: pointer, output: ptr UncheckedArray[int32], capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## Static terrain of the current world's control hearts (training library only): one
  ## int32 per heart slot, bit 0 (1) = the heart stands in water, bit 1 (2) = water within
  ## one step of it (any of 16 samples at 50 and 100 units in the 8 compass directions).
  ## Writes min(hearts, capacity) slots and returns the heart count (-1 for bad
  ## arguments). Pure read.
  if handle == nil or capacity < 0 or (capacity > 0 and output == nil): return -1
  ready(handle)
  let w = addr cast[ptr NativeEnv](handle).world
  for k in 0..<min(w[].controlHearts.len, capacity.int):
    let p = w[].controlHearts[k].pos
    var bits = 0'i32
    if waterPoint(p.x.int, p.z.int): bits = bits or 1
    block near:
      for r in [50, 100]:
        for d in [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]:
          if waterPoint(p.x.int + d[0]*r, p.z.int + d[1]*r):
            bits = bits or 2
            break near
    output[k] = bits
  w[].controlHearts.len.cint

proc pw_seat_weapon_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Per-weapon enemy kills and enemy-hit locations for one seat (training library only),
  ## nine int32, cumulative since the last create/reset, attributed to the damage's owner,
  ## enemy victims only: [gun kills, grenade kills, spray kills, hits from water, hits from
  ## high ground, hits from a trench, hits to water, hits to high ground, hits to a
  ## trench]. A hit is every enemy damage event past the shield and life checks (the event
  ## pw_seat_stats' hits_enemy counts), any weapon; a kill is the one that takes the victim
  ## to hp 0 (the three kinds sum to pw_seat_stats' kills; spray equals
  ## pw_seat_spray_stats[2]). "From" classifies the shooter's position at the damage event,
  ## "to" the victim's: water = in the river's water (rules >= 30; SeatView.waterAt's test),
  ## high = terrainHeight >= 216, trench = inside a trench; the classes may overlap. Pure
  ## telemetry. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<seatsOf(handle) or output == nil: return -1
  ready(handle)
  let s = cast[ptr NativeEnv](handle).stats[seat]
  for i, v in [s.gunKills, s.grenadeKills, s.weaponSprayKills, s.hitsFromWater, s.hitsFromHigh,
      s.hitsFromTrench, s.hitsToWater, s.hitsToHigh, s.hitsToTrench]:
    output[i] = v
  0

const SeatStateFloats* = 8 ## pw_seat_state floats per seat

proc pw_seat_state*(handle: pointer, output: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## Every seat's public body state in one call (training library only), n seats (pw_seats) x 8
  ## floats in seat order: [x, z (world units), hp, armor, lives, respawn (ticks until the
  ## seat respawns, 0 while alive), carrying (1 = holds a heart), equipment bits (1 =
  ## grenade, 2 = spray can)]. For training-side critics that need the whole match state
  ## every tick without pw_world_json's serialisation. A pure read: the world and its hash
  ## are unchanged. Returns 0, -1 for bad arguments.
  if handle == nil or output == nil: return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  for slot in 0..<env.n:
    let c = env.world.cogs[slot]
    let e = env.world.equipment[slot]
    let o = slot*SeatStateFloats
    output[o] = c.pos.x.float32; output[o+1] = c.pos.z.float32
    output[o+2] = c.hp.float32; output[o+3] = e.armor.float32
    output[o+4] = e.lives.float32; output[o+5] = c.respawn.float32
    output[o+6] = (if c.carrying: 1'f32 else: 0'f32)
    output[o+7] = float32((if e.grenade: 1 else: 0) + (if e.sprayCan: 2 else: 0))
  0

proc pw_world_json*(handle: pointer, output: ptr UncheckedArray[char], capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## The whole world as one JSON object (training library only): {"rulesVersion": R,
  ## "heard": {}, then every World field}, the object the engine streamed to PW_POLICY_FD
  ## each tick before seats stopped acting through the host (#51). For external
  ## controllers that plan from world state and act through pw_set_seat_command. Returns
  ## the length in bytes; the JSON (no terminating NUL) is written only when capacity >=
  ## that length, so a call with capacity 0 sizes the buffer. A pure read: the world and
  ## its hash are unchanged. -1 for bad arguments.
  if handle == nil or capacity < 0 or (capacity > 0 and output == nil): return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  let snapshot = env.world.toJson()
  let doc = "{\"rulesVersion\":" & $env.rulesVersion & ",\"heard\":{}," & snapshot[1..^1]
  if capacity >= doc.len and doc.len > 0:
    copyMem(output, unsafeAddr doc[0], doc.len)
  doc.len.cint

proc pw_elevation*(handle: pointer, x, z: int32): cint {.exportc, cdecl, dynlib.} =
  ## The ground height at (x, z) in this handle's world, sim.elevation: terrain plus world
  ## features (training library only), for external controllers that raster line of sight
  ## from pw_world_json. A pure read. Returns the height; -1_000_000 for a nil handle.
  if handle == nil: return -1_000_000
  ready(handle)
  elevation(cast[ptr NativeEnv](handle).world, Point(x: x, z: z)).cint

proc pw_terrain_prewarm*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## Computes now the terrain table blocks covering the handle's current world bounds, so its
  ## rays, walks and observations never pay for a block's first touch (a cold table otherwise
  ## halves throughput for the first few thousand ticks of a process). The table is shared by
  ## every handle and thread of the process whose rules and map agree, so one call per rules
  ## and map suffices. Returns the blocks covered; 0 for a generated map (read from its grid,
  ## never tabled); -1 for a nil handle. Changes no world state.
  if handle == nil: return -1
  ready(handle)
  cint(prewarmTerrain(minX(), minZ(), maxX(), maxZ()))

proc pw_terrain_cache_save*(handle: pointer, path: cstring): cint {.exportc, cdecl, dynlib.} =
  ## Writes the terrain table of the handle's rules and map (every computed block; call
  ## pw_terrain_prewarm first for a complete one) to path, replaced atomically. Returns the
  ## blocks written; 0 for a generated map; -1 for a nil argument or an I/O failure.
  if handle == nil or path == nil: return -1
  ready(handle)
  try: cint(saveTerrain($path))
  except CatchableError: -1

proc pw_terrain_cache_load*(handle: pointer, path: cstring): cint {.exportc, cdecl, dynlib.} =
  ## Maps a file pw_terrain_cache_save wrote, read-only and shared through the page cache, into
  ## the table of the handle's rules and map. Returns the blocks installed (those not already
  ## computed); 0 for a generated map; -1 for a nil argument or a file this build cannot use
  ## (missing, another game build's terrain, other rules or map, or cells that disagree with
  ## the direct terrain functions), in which case nothing is installed.
  if handle == nil or path == nil: return -1
  ready(handle)
  try: cint(loadTerrain($path))
  except CatchableError: -1

proc pw_terrain_cache_blocks*(): cint {.exportc, cdecl, dynlib.} =
  ## Diagnostic: resident 64x64 terrain blocks (16 KiB each) across all tables.
  cint(terrainCacheResidentBlocks())

# PWNET001 / PWNET002 actors in the training library: the hosted seat's own loader and
# inference (neural_actor.nim), so a trainer or evaluator runs a bundle's model.bin
# bit for bit as the hosted seat does. A net handle owns its scratch and buffers: one
# call at a time per handle, like an env handle.
type NativeNet = object
  actor: Actor
  state, logits: seq[float32]

proc writeMessage(output: ptr UncheckedArray[char], capacity: cint, message: string) =
  if output == nil or capacity <= 0: return
  let n = min(message.len, capacity.int - 1)
  for i in 0..<n: output[i] = message[i]
  output[n] = '\0'

proc pw_net_load*(data: pointer, length: int64, error: ptr UncheckedArray[char],
    capacity: cint): pointer {.exportc, cdecl, dynlib.} =
  ## Loads and validates a model.bin (PWNET001 or PWNET002) with the hosted loader, and
  ## rejects a model over the 4,000,000 operations per seat per tick budget as the hosted
  ## seat does. NULL on rejection, with the reason in `error` (NUL-terminated, truncated
  ## to capacity; "" on success; may be NULL). Contracts and Paintbot dimensions are the
  ## caller's to check (pw_net_info).
  if data == nil or length < 8 or length > MaxNet2FileBytes:
    writeMessage(error, capacity, "invalid neural actor length")
    return nil
  ready()
  var bytes = newString(length.int)
  copyMem(addr bytes[0], data, length.int)
  try:
    let actor = loadActor(bytes)
    if actor.operationCount > MaxNeuralOperations:
      raise newException(ValueError, "neural actor exceeds native operation budget: " &
        $actor.operationCount & " > " & $MaxNeuralOperations)
    let net = createShared(NativeNet)
    net.actor = actor
    net.state = newSeq[float32](actor.stateSize)
    net.logits = newSeq[float32](actor.outputSize)
    writeMessage(error, capacity, "")
    net
  except ValueError as e:
    writeMessage(error, capacity, e.msg)
    nil

proc pw_net_load_layout*(handle: pointer, data: pointer, length: int64, error: ptr UncheckedArray[char],
    capacity: cint): pointer {.exportc, cdecl, dynlib.} =
  ## pw_net_load for an ffa.view.1 handle's current match: the model's PWNET002 layout words
  ## (neural_actor.md) resolve against the handle's observation layout (pw_observation_layout)
  ## and its action contract's heads, so one model.bin loads at every seat and heart count
  ## (an ffa.view.1u<K> handle: the input count is the layout's size + K).
  ## The budget is the hosted seat's for the handle's seat count (4,000,000 operations per
  ## seat per tick, times seats / 16 above 16 seats). NULL on rejection (a handle that is not
  ## ffa.view.1 included), with the reason in `error`, as pw_net_load.
  if handle == nil:
    writeMessage(error, capacity, "no handle")
    return nil
  let env = cast[ptr NativeEnv](handle)
  if env.obsVersion != ocFfaView1:
    writeMessage(error, capacity, "layout words need an observation contract ffa.view.1 handle")
    return nil
  if data == nil or length < 8 or length > MaxNet2FileBytes:
    writeMessage(error, capacity, "invalid neural actor length")
    return nil
  ready(handle)
  var bytes = newString(length.int)
  copyMem(addr bytes[0], data, length.int)
  try:
    let l = env.layoutOf
    let targets = pointerTargets(l)
    let actor = loadActor(bytes, actorLayout(l, env.actionHeads, targets, env.userInputs))
    let budget = neuralOperationBudget(env.n)
    if actor.operationCount > budget:
      raise newException(ValueError, "neural actor exceeds native operation budget: " &
        $actor.operationCount & " > " & $budget)
    let net = createShared(NativeNet)
    net.actor = actor
    net.state = newSeq[float32](actor.stateSize)
    net.logits = newSeq[float32](actor.outputSize)
    writeMessage(error, capacity, "")
    net
  except ValueError as e:
    writeMessage(error, capacity, e.msg)
    nil

proc pw_net_destroy*(net: pointer) {.exportc, cdecl, dynlib.} =
  if net == nil: return
  ready()
  let n = cast[ptr NativeNet](net)
  `=destroy`(n[])
  deallocShared(n)

proc pw_net_info*(net: pointer, output: ptr UncheckedArray[int64]): cint {.exportc, cdecl, dynlib.} =
  ## Eight int64: [format (1 or 2), inputs, outputs, recurrent state floats, heads, layers,
  ## parameters, operations per inference (the published count the budget binds)].
  if net == nil or output == nil: return -1
  let a = cast[ptr NativeNet](net).actor
  output[0] = a.actorFormat
  output[1] = a.inputSize
  output[2] = a.outputSize
  output[3] = a.stateSize
  output[4] = a.headSizes.len
  output[5] = a.layerCount
  output[6] = a.parameterCount
  output[7] = a.operationCount
  0

proc pw_net_head_sizes*(net: pointer, output: ptr UncheckedArray[int32], capacity: cint): cint {.exportc, cdecl, dynlib.} =
  ## Writes the categorical head sizes; returns the head count, -1 for bad arguments or a
  ## capacity below it.
  if net == nil or output == nil: return -1
  let a = cast[ptr NativeNet](net).actor
  if capacity < a.headSizes.len: return -1
  for i, size in a.headSizes: output[i] = size.int32
  a.headSizes.len.cint

proc pw_net_contracts*(net: pointer, output: ptr UncheckedArray[char], capacity: cint): cint {.exportc, cdecl, dynlib.} =
  ## The observation and action contract hashes as "<obs64> <action64>" (NUL-terminated,
  ## capacity >= 130). 0, or -1 for bad arguments.
  if net == nil or output == nil or capacity < 130: return -1
  let a = cast[ptr NativeNet](net).actor
  writeMessage(output, capacity, a.observationContract & " " & a.actionContract)
  0

proc pw_net_infer*(net: pointer, observation, state, logits: ptr UncheckedArray[float32]): cint {.exportc, cdecl, dynlib.} =
  ## One inference, the hosted seat's run_neural_net: reads `inputs` observation floats and
  ## the `state` floats (all MINGRU states in layer order), writes the new state in place
  ## and `outputs` logits. Returns 0; -1 bad arguments; -2 when inference fails (a
  ## nonfinite input, state, intermediate or output), leaving state and logits untouched,
  ## as the hosted seat is then disabled without committing either. The reset convention is
  ## the host's: zero the whole state at initial use, match reset, death and respawn.
  if net == nil or observation == nil or logits == nil: return -1
  ready()
  let n = cast[ptr NativeNet](net)
  if n.state.len > 0 and state == nil: return -1
  for i in 0..<n.state.len: n.state[i] = state[i]
  try:
    n.actor.infer(toOpenArray(observation, 0, n.actor.inputSize-1), n.state, n.logits)
  except ValueError:
    return -2
  for i in 0..<n.state.len: state[i] = n.state[i]
  for i in 0..<n.logits.len: logits[i] = n.logits[i]
  0


# ---- World snapshots (pw_world_save / pw_world_load; training library only, default-off) ----
# A blob = header (magic, format, build id, observation version, seats) + every NativeEnv field in declaration order
# through snapshot.nim's codec, the world included, except the BASIC bots: per slot, a scripted or decoder bot is
# saved as its runtime and string-pool state (polyworld basic saveState), its failure flags, its neural seat and its
# rnd stream, and on load is rebuilt from the blob's own script / manifest (installScript, decoderFor) before that
# state is restored. Nothing here runs unless the caller saves or loads.
const
  SnapMagic = "PWSAVE01"
  SnapFormat = 1'u64
  # Any change to a source that defines a snapshotted type changes the id: a blob loads only into the build that wrote it.
  SnapBuildId = sha256Hex(staticRead("sim.nim") & staticRead("mechanics.nim") & staticRead("native_env.nim") &
    staticRead("neural_host.nim") & staticRead("bots.nim") & staticRead("kinship.nim") &
    staticRead("training_labels.nim") & staticRead("snapshot.nim") & staticRead("../../src/polyworld/basic.nim") &
    staticRead("../../src/polyworld/rngs.nim"))

var snapLastError {.threadvar.}: string  # pw_world_load_error: why the calling thread's last load was refused

proc snapChecksum(data: openArray[byte], n: int): string =
  ## sha256 (hex) of the blob's first n bytes: the trailer that makes any corruption a refusal.
  var s = newString(n)
  if n > 0: copyMem(addr s[0], unsafeAddr data[0], n)
  sha256Hex(s)

proc saveBot(w: var SnapWriter, b: Bot) =
  w.put(not b.isNil)
  if b.isNil: return
  w.putBytes(b.runtime.saveState())
  w.put(not b.strings.isNil)
  if not b.strings.isNil: w.putBytes(b.strings.saveState())
  w.put(b.failed); w.put(b.error)
  w.put(b.neural)
  w.put(b.rnd)

proc loadBot(r: var SnapReader, b: Bot) =
  ## Restores a saveBot record into a bot freshly built from the same script.
  b.runtime.restoreState(r.getBytes())
  var hasStrings: bool
  r.get(hasStrings)
  if hasStrings:
    if b.strings.isNil: r.fail("string pool missing on the rebuilt bot")
    b.strings.restoreState(r.getBytes())
  r.get(b.failed); r.get(b.error)
  r.get(b.neural)
  r.get(b.rnd)

proc pw_world_save*(handle: pointer, output: ptr UncheckedArray[byte], capacity: int64): int64 {.exportc, cdecl, dynlib.} =
  ## The handle's whole match state as one versioned, deterministic blob (training library only): the world, every
  ## per-seat setting and stream, the BASIC seats' runtime state, the decoders, telemetry. Returns its size in bytes
  ## and writes it only when capacity >= size (capacity 0 sizes it). A pure read: the world and its hash are
  ## unchanged. -1 for bad arguments. A policy seat's network recurrent state is the caller's (not in the blob).
  ## The blob ends with a sha256 of everything before it, so a corrupted blob is refused, never half-read.
  if handle == nil or capacity < 0 or (capacity > 0 and output == nil): return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  var w: SnapWriter
  w.put(SnapMagic); w.putU64(SnapFormat); w.put(SnapBuildId)
  w.put(env.obsVersion); w.put(env.n)
  for name, f in fieldPairs(env[]):
    when name == "scriptBots" or name == "decoders":
      w.putU64(f.len.uint64)
      for b in f: w.saveBot(b)
    else:
      w.put(f)
  w.put(snapChecksum(w.data, w.data.len))
  if capacity >= w.data.len and w.data.len > 0:
    copyMem(output, unsafeAddr w.data[0], w.data.len)
  w.data.len.int64

proc pw_world_load*(handle: pointer, data: ptr UncheckedArray[byte], length: int64): cint {.exportc, cdecl, dynlib.} =
  ## Replaces the handle's whole match state with a pw_world_save blob (training library only). The handle must have
  ## the blob's observation version and seat count. Returns 0; -1 bad arguments; -2 another format / build / handle
  ## shape; -3 a corrupt or truncated blob. On any refusal the handle is unchanged (the blob is decoded and its bots
  ## rebuilt on a copy, which replaces the handle only when everything succeeded).
  snapLastError = ""
  if handle == nil or data == nil or length <= 0:
    snapLastError = "bad arguments"; return -1
  ready(handle)
  let env = cast[ptr NativeEnv](handle)
  var r = SnapReader(data: newSeq[byte](length.int))
  copyMem(addr r.data[0], data, length.int)
  try:
    var magic, build: string
    r.get(magic)
    if magic != SnapMagic:
      snapLastError = "not a world snapshot"; return -2
    if r.getU64() != SnapFormat:
      snapLastError = "another snapshot format"; return -2
    r.get(build)
    if build != SnapBuildId:
      snapLastError = "written by another build"; return -2
    var obs: ObservationContractVersion
    var n: int
    r.get(obs); r.get(n)
    if obs != env.obsVersion or n != env.n:
      snapLastError = "observation version / seat count differ from the handle's"; return -2
    # The trailer: an 8-byte length and the 64-hex sha256 of everything before it.
    let body = r.data.len - 72
    if body < r.at: r.fail("truncated")
    var tail = SnapReader(data: r.data, at: body)
    var sum: string
    tail.get(sum)
    if tail.at != r.data.len or sum != snapChecksum(r.data, body): r.fail("checksum mismatch")
    r.data.setLen(body)
    var tmp = env[]
    var botBlobs: array[2, seq[(int, seq[byte])]]
    for name, f in fieldPairs(tmp):
      when name == "scriptBots" or name == "decoders":
        let k = when name == "scriptBots": 0 else: 1
        let count = r.getU64()
        if count != uint64(n): r.fail("bot count")
        f = newSeq[Bot](n)
        for slot in 0..<n:
          var present: bool
          r.get(present)
          if present:
            let start = r.at
            discard r.getBytes()                       # runtime
            var hasStrings: bool
            r.get(hasStrings)
            if hasStrings: discard r.getBytes()
            var failed: bool
            var error: string
            r.get(failed); r.get(error)
            var neural: NeuralSeat
            var rnd: RndStream
            r.get(neural); r.get(rnd)
            botBlobs[k].add (slot, r.data[start ..< r.at])
      else:
        r.get(f)
    if r.at != r.data.len: r.fail("trailing bytes")
    # Rebuild the bots on the copy from its own scripts and decoder contract, then restore their state. Scripts
    # compile against the blob's game mode, kinship, rules and map (FFA-kin host functions), so the copy's are
    # installed first; a refusal below re-installs the handle's.
    ready(addr tmp)
    for (slot, blob) in botBlobs[0]:
      # installScript resets the seat's status, error and last orders, which the blob already restored
      let (status, error, orders) = (tmp.scriptStatus[slot], tmp.scriptErrors[slot], tmp.scriptOrders[slot])
      installScript(addr tmp, slot)
      if tmp.scriptBots[slot].isNil: r.fail("script for slot " & $slot & " did not build")
      tmp.scriptStatus[slot] = status; tmp.scriptErrors[slot] = error; tmp.scriptOrders[slot] = orders
      var br = SnapReader(data: blob)
      br.loadBot(tmp.scriptBots[slot])
    for (slot, blob) in botBlobs[1]:
      let b = decoderFor(addr tmp, slot)
      var br = SnapReader(data: blob)
      br.loadBot(b)
    env[] = tmp
  except SnapError, ValueError:
    snapLastError = getCurrentExceptionMsg()
    ready(handle)
    return -3
  ready(handle)
  0

proc pw_world_load_error*(output: ptr UncheckedArray[char], capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## Why the calling thread's last pw_world_load was refused ("" after a success), NUL-terminated and truncated to
  ## capacity. Returns the full message length; -1 for bad arguments.
  if output == nil or capacity <= 0: return -1
  let m = snapLastError
  let k = min(m.len, capacity.int - 1)
  for i in 0..<k: output[i] = m[i]
  output[k] = '\0'
  m.len.cint
