## In-process training ABI. Build with --app:lib --mm:arc --threads:on -d:pwTraining.
## A handle may migrate between threads but must never be used concurrently.
## The caller owns flat buffers; no Nim-managed values cross the C boundary.
import sim, neural_contract, bots
import polyworld/rngs
import polyworld/basic

when not defined(pwTraining): {.error: "native_env requires -d:pwTraining".}

type
  NativeEnv = object
    world: World
    resets: array[Seats,float32]
    # Apparent identities per seat, valid for the current unchanged world only: the
    # observer, the action decoder and the training bot all resolve the same bodies on
    # one tick, so each seat's fog is computed at most once between steps.
    bodies: array[Seats,array[Seats,int]]
    bodiesReady: array[Seats,bool]
    stats: CombatTelemetry # Cumulative since the last create/reset; see pw_seat_stats.
    # BASIC seats: the production interpreter, host functions, limits and per-decision
    # budget from bots.nim drive these slots instead of the caller's actions.
    scripts: array[Seats,string]
    scriptBots: array[Seats,Bot]
    scriptStatus: array[Seats,int32] # 0 none, 1 running, 2 compile failed, 3 disabled at runtime
    scriptErrors: array[Seats,string]
    scriptHeard: array[Seats,seq[HeardMessage]] # Speech carried from the previous decision.
    scriptOrders: array[Seats,Command] # What each scripted seat ordered on the last step.
    scriptCount: int
    # Curriculum knobs, kept across resets like scripts. A fire period above 1 lets a
    # seat's shoot order through only once per that many cooldown windows; a damage
    # scale below or above 1000 permille changes what the seat deals.
    firePeriod: array[Seats,int32]
    lastHonouredShot: array[Seats,int32]
    damagePermille: array[Seats,int32]
    # Action contract the caller's actions are decoded under (pw_set_action_contract;
    # v1 unless asked, kept across resets) and, for contract v2, each seat's one-tick
    # memory the lead-compensated identity aim reads (recorded after every decode,
    # cleared by create/reset; never part of the world or its hash).
    contract: ActionContractVersion
    aimMemory: array[Seats,AimMemory]
    # Mapping-ceiling diagnostics (pw-bc): a scripted seat with a non-zero override mask
    # still runs its script every step (its orders are reported by pw_seat_orders) but
    # executes the caller's decoded action for the masked heads: 1 walk/goal/direct,
    # 2 aim, 4 shoot, 8 grenade, 16 sneak. pw_script_decide runs the scripts' decision
    # for the current tick ahead of pw_step so the caller can read the orders, map them
    # and hand the mapped action to the same step.
    overrideMask: array[Seats,int32]
    # Decoder fire hold (pw_set_seat_fire_hold, kept across resets like the knobs): the
    # seat's final shoot order, whoever issued it (caller, Nim bot, script, override
    # mix), goes through neural_contract.holdFire; fireHeld counts the orders held since
    # the last create/reset. Off on every seat = byte-identical to a library without it.
    fireHold: array[Seats,bool]
    # Hold radius per seat (pw_set_seat_fire_hold_radius, kept across resets): 0 = the
    # default FireHoldRadius (55), so a zeroed handle is today's rule.
    fireHoldRadius: array[Seats,int32]
    fireHeld: array[Seats,int32]
    # Decoder sampling (pw_set_seat_sampling, kept across resets like the knobs): the
    # seat's draw stream, seeded from the match seed and the slot exactly as the hosted
    # seat seeds its own (neural_contract.samplingRng) on every create/reset, so a probe
    # that feeds pw_sample_actions the logits the hosted actor would produce takes the
    # hosted seat's draws. Never part of the world or its hash; pw_step is untouched.
    sampling: array[Seats,SamplingOptions]
    sampleRng: array[Seats,Rng]
    sampleDraws: array[Seats,int32]
    # Decoder objective forbid (pw_set_seat_forbid_objectives, kept across resets): the
    # movement-head indices pw_sample_actions never selects for the seat and pw_step
    # refuses from the caller for it (the hosted bundle option decoder.forbid_objectives).
    forbidden: array[Seats,ObjectiveMask]
    forbidAny: array[Seats,bool]
    # Decoder strafe legs (pw_set_seat_strafe, kept across resets): applied to the
    # caller's selected heads in pw_step before they are decoded, with the seat's own
    # stream seeded from the match seed and the slot exactly as the hosted seat seeds its
    # own (neural_contract.strafeRng) on every create/reset. strafeLast is the movement
    # index the strafe executed on the last pw_step (-1 = the caller's stood).
    strafe: array[Seats,StrafeOptions]
    strafeState: array[Seats,StrafeState]
    strafeRng: array[Seats,Rng]
    strafeLast: array[Seats,int32]
    # Decoder aim snap (pw_set_seat_aim_snap) and steady shot (pw_set_seat_steady_shot),
    # both kept across resets and both stateless rules applied to the caller's selected
    # heads in pw_step before they are decoded, in the hosted seat's order: aim snap,
    # strafe, steady shot. The counts belong to the match; *Last is the head index the
    # rule executed on the last pw_step (-1 = the caller's stood).
    aimSnap: array[Seats,AimSnapOptions]
    aimSnaps: array[Seats,int32]
    aimSnapLast: array[Seats,int32]
    steadyShot: array[Seats,bool]
    steadyShots: array[Seats,int32]
    steadyTicks: array[Seats,int32]
    steadyLast: array[Seats,int32]
    # Decoder aim retarget (pw_set_seat_aim_retarget) and shot gate (pw_set_seat_shot_gate),
    # both kept across resets and both stateless rules applied to the caller's selected
    # heads in pw_step in the hosted seat's order: aim retarget, aim snap, shot gate,
    # strafe, steady shot. The counts belong to the match; aimRetargetLast is the aim index
    # the retarget executed on the last pw_step and shotGateLast the shoot head the gate
    # executed (0), -1 = the caller's stood.
    aimRetarget: array[Seats,AimRetargetOptions]
    aimRetargets: array[Seats,int32]
    aimRetargetLast: array[Seats,int32]
    shotGate: array[Seats,ShotGateOptions]
    shotGates: array[Seats,int32]
    shotGateLast: array[Seats,int32]
    # Decoder spray aim (pw_set_seat_spray_aim) and spray gate (pw_set_seat_spray_gate):
    # stateless rules for a seat holding a ready spray can, in the hosted order (retarget,
    # snap, spray aim, shot gate, spray gate, strafe, steady). Counts belong to the match;
    # *Last as above (-1 = the caller's stood).
    sprayAim: array[Seats,SprayAimOptions]
    sprayAims: array[Seats,int32]
    sprayAimLast: array[Seats,int32]
    sprayGate: array[Seats,SprayGateOptions]
    sprayGates: array[Seats,int32]
    sprayGateLast: array[Seats,int32]
    # Raw commands (pw_set_seat_command): a seat with a pending command executes it on the
    # next pw_step instead of its decoded heads or its script's order (no forbid check, no
    # head decode or decoder option for it); commandShown marks an unscripted seat whose
    # pw_seat_orders echo holds a command, cleared on its next step without one. Nothing
    # here is part of the world or its hash; unused, every flag stays false.
    commandPending: array[Seats,bool]
    commandNext: array[Seats,Command]
    commandShown: array[Seats,bool]
    decided: array[Seats,Command]
    decidedTick: int32
    decidedValid: bool
    # Observation contract the handle encodes (chosen at create, kept across resets):
    # v1 (pw_create, 448 floats per seat) or v2 (pw_create_observation, v1's 448 floats
    # followed by the terrain block). pw_observe/pw_observe_seats rows are
    # observationSize(obsVersion) floats apart. The world never reads it.
    obsVersion: ObservationContractVersion
  FloatBuffer = ptr UncheckedArray[cfloat]
  ActionBuffer = ptr UncheckedArray[int32]

const NativeRules* = 39

proc ready() =
  setupForeignThreadGc()
  configureRules(NativeRules)

proc invalidateBodies(env: ptr NativeEnv) =
  for slot in 0..<Seats: env.bodiesReady[slot] = false
proc resetAimMemories(env: ptr NativeEnv) =
  for slot in 0..<Seats: env.aimMemory[slot].resetAimMemory()
proc resetStats(env: ptr NativeEnv) =
  for slot in 0..<Seats:
    env.stats[slot] = SeatStats(firstFriendlyFireTick: -1)
    env.fireHeld[slot] = 0
proc resetSampling(env: ptr NativeEnv) =
  ## Fresh streams for the new match (options persist); draw counts belong to the match.
  for slot in 0..<Seats:
    env.sampleRng[slot] = samplingRng(env.world.seed, slot)
    env.sampleDraws[slot] = 0
proc resetStrafe(env: ptr NativeEnv) =
  ## Fresh leg state and streams for the new match (options persist).
  for slot in 0..<Seats:
    env.strafeState[slot] = initStrafeState(slot)
    env.strafeRng[slot] = strafeRng(env.world.seed, slot)
    env.strafeLast[slot] = -1
proc resetSnapSteady(env: ptr NativeEnv) =
  ## Counts belong to the match (options persist).
  for slot in 0..<Seats:
    env.aimSnaps[slot] = 0
    env.aimSnapLast[slot] = -1
    env.steadyShots[slot] = 0
    env.steadyTicks[slot] = 0
    env.steadyLast[slot] = -1
    env.aimRetargets[slot] = 0
    env.aimRetargetLast[slot] = -1
    env.shotGates[slot] = 0
    env.shotGateLast[slot] = -1
    env.sprayAims[slot] = 0
    env.sprayAimLast[slot] = -1
    env.sprayGates[slot] = 0
    env.sprayGateLast[slot] = -1
proc resetCurriculum(env: ptr NativeEnv) =
  ## Knob values persist; the shot history belongs to the match.
  for slot in 0..<Seats:
    env.lastHonouredShot[slot] = low(int32) div 2
    if env.firePeriod[slot] < 1: env.firePeriod[slot] = 1
proc initCurriculum(env: ptr NativeEnv) =
  for slot in 0..<Seats:
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
proc installScript(env: ptr NativeEnv, slot: int) =
  ## A fresh runtime for the seat's source, as a new match loads its bots.
  env.scriptBots[slot] = nil
  env.scriptErrors[slot] = ""
  env.scriptOrders[slot] = Command()
  if env.scripts[slot].len == 0:
    env.scriptStatus[slot] = 0
    return
  try:
    env.scriptBots[slot] = loadScriptBot(env.scripts[slot], slot)
    env.scriptStatus[slot] = 1
  except BasicError as e:
    env.scriptStatus[slot] = 2
    env.scriptErrors[slot] = e.msg
proc resetScripts(env: ptr NativeEnv) =
  env.scriptCount = 0
  env.decidedValid = false
  for slot in 0..<Seats:
    env.scriptHeard[slot] = @[]
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
  for slot in 0..<Seats:
    if env.scripts[slot].len == 0: continue
    let b = env.scriptBots[slot]
    if b != nil and b.failed and env.scriptStatus[slot] == 1:
      env.scriptStatus[slot] = 3
      env.scriptErrors[slot] = b.error
    env.scriptOrders[slot] = decided[slot]
  env.decided = decided
  env.decidedTick = env.world.tick
  env.decidedValid = true
proc bodiesFor(env: ptr NativeEnv, slot: int): array[Seats,int] =
  if not env.bodiesReady[slot]:
    env.bodies[slot] = env.world.observedBodies(slot)
    env.bodiesReady[slot] = true
  env.bodies[slot]

proc decodeSeat(env: ptr NativeEnv, slot: int, actions: ActionBuffer): Command =
  ## The caller's five head indices for one seat through the selected contract. Under
  ## v1 the bodies are resolved only for an identity aim, as before; v2 always resolves
  ## them because the seat's memory must be recorded on every decided tick. A seat with
  ## the aim retarget, the aim snap, the shot gate, the strafe or the steady shot on
  ## decodes its heads after neural_contract.aimRetargetActions, aimSnapActions,
  ## shotGateActions, strafeActions and steadyShotActions, in that order, as the hosted
  ## seat does.
  let offset = slot*ActionSizes.len
  if env.strafe[slot].enabled or env.aimSnap[slot].enabled or env.steadyShot[slot] or
      env.aimRetarget[slot].enabled or env.shotGate[slot].enabled or env.sprayAim[slot].enabled or
      env.sprayGate[slot].enabled:
    var heads: array[ActionSizes.len, int32]
    for head in 0..<ActionSizes.len: heads[head] = actions[offset+head]
    let bodies = env.bodiesFor(slot)
    env.aimRetargetLast[slot] = -1
    env.aimSnapLast[slot] = -1
    env.shotGateLast[slot] = -1
    env.sprayAimLast[slot] = -1
    env.sprayGateLast[slot] = -1
    env.strafeLast[slot] = -1
    env.steadyLast[slot] = -1
    if env.world.aimRetargetActions(slot, heads, bodies, env.contract, env.aimMemory[slot],
        env.aimRetarget[slot]):
      env.aimRetargetLast[slot] = heads[1]
      inc env.aimRetargets[slot]
    let beforeSnap = heads
    var snapped = env.world.aimSnapActions(slot, heads, bodies, env.aimSnap[slot])
    var sprayAimed = env.world.sprayAimActions(slot, heads, bodies, env.contract, env.aimMemory[slot],
      env.sprayAim[slot])
    if env.world.shotGateActions(slot, heads, beforeSnap, snapped, bodies, env.contract,
        env.aimMemory[slot], env.shotGate[slot]):
      # The dropped order was never a shot: the snap and the spray aim (which rewrite only
      # shoot orders) did not execute on it.
      snapped = false
      sprayAimed = false
      env.shotGateLast[slot] = 0
      inc env.shotGates[slot]
    if snapped:
      env.aimSnapLast[slot] = heads[1]
      inc env.aimSnaps[slot]
    if sprayAimed:
      env.sprayAimLast[slot] = heads[1]
      inc env.sprayAims[slot]
    if env.world.sprayGateActions(slot, heads, bodies, env.contract, env.aimMemory[slot], env.sprayGate[slot]):
      env.sprayGateLast[slot] = 0
      inc env.sprayGates[slot]
    if env.world.strafeActions(slot, heads, bodies, env.strafe[slot], env.strafeState[slot],
        env.strafeRng[slot], env.forbidden[slot]):
      env.strafeLast[slot] = heads[0]
    let held = env.world.steadyShotActions(slot, heads, env.steadyShot[slot])
    if held != ssNone:
      # The steady shot overrides the strafe's leg for this decision: the strafe's index
      # was not executed (its leg and counts advance as without the steady shot).
      env.strafeLast[slot] = -1
      env.steadyLast[slot] = heads[0]
      inc env.steadyTicks[slot]
      if held == ssOrder: inc env.steadyShots[slot]
    if env.contract == acV1:
      result = decodeActions(env.world,slot,heads,bodies)
    else:
      result = decodeActions(env.world,slot,heads,bodies,env.contract,env.aimMemory[slot])
      env.aimMemory[slot].recordAimMemory(env.world,slot,bodies)
    return
  if env.contract == acV1:
    if actions[offset+1] in 1'i32..16'i32:
      result = decodeActions(env.world,slot,actions.toOpenArray(offset,offset+ActionSizes.len-1),env.bodiesFor(slot))
    else:
      result = decodeActions(env.world,slot,actions.toOpenArray(offset,offset+ActionSizes.len-1))
  else:
    let bodies = env.bodiesFor(slot)
    result = decodeActions(env.world,slot,actions.toOpenArray(offset,offset+ActionSizes.len-1),
      bodies,env.contract,env.aimMemory[slot])
    env.aimMemory[slot].recordAimMemory(env.world,slot,bodies)
proc pw_env_version*(): cint {.exportc, cdecl, dynlib.} = 1
proc pw_observation_size*(): cint {.exportc, cdecl, dynlib.} = ObservationSize
proc pw_action_count*(): cint {.exportc, cdecl, dynlib.} = ActionSizes.len

proc createEnv(seed, maxTicks: int32, obsVersion: ObservationContractVersion): pointer =
  ready()
  if maxTicks < 0 or maxTicks > HeartMeterMatchTicks: return nil
  let env = cast[ptr NativeEnv](allocShared0(sizeof(NativeEnv)))
  try:
    env.obsVersion = obsVersion
    env.world = newWorld(seed,maxTicks)
    for i in 0..<Seats: env.resets[i] = 1
    env.invalidateBodies()
    env.resetStats()
    env.initCurriculum()
    env.contract = acV1
    env.resetAimMemories()
    env.resetSampling()
    env.resetStrafe()
    env.resetSnapSteady()
    result = env
  except CatchableError:
    `=destroy`(env[])
    deallocShared(env)

proc pw_create*(seed, maxTicks: int32): pointer {.exportc, cdecl, dynlib.} =
  ## Observation contract v1 (448 floats per seat), as before.
  createEnv(seed, maxTicks, ocV1)

proc pw_create_observation*(seed, maxTicks, obsVersion: int32): pointer {.exportc, cdecl, dynlib.} =
  ## pw_create with the observation contract chosen: 1 = v1 (identical to pw_create),
  ## 2 = v2 (v1 + terrain block). nil for any other version or a bad max_ticks.
  if obsVersion notin [ocV1.int32, ocV2.int32]: return nil
  createEnv(seed, maxTicks, ObservationContractVersion(obsVersion))

proc pw_observation_size_for*(obsVersion: int32): cint {.exportc, cdecl, dynlib.} =
  ## Floats per seat under observation contract `obsVersion`; -1 if unknown.
  if obsVersion notin [ocV1.int32, ocV2.int32]: return -1
  observationSize(ObservationContractVersion(obsVersion)).cint

proc pw_observation_contract*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## The handle's observation contract version (1 or 2); -1 for a nil handle.
  if handle == nil: return -1
  cast[ptr NativeEnv](handle).obsVersion.cint

proc pw_handle_observation_size*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## Floats per seat this handle's pw_observe writes (the row stride); -1 for nil.
  if handle == nil: return -1
  observationSize(cast[ptr NativeEnv](handle).obsVersion).cint

proc pw_observation_contract_hash*(obsVersion: int32, output: ptr UncheckedArray[char],
    capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## The 64-hex SHA-256 an actor and manifest carry for observation contract
  ## `obsVersion`, NUL-terminated; capacity must be >= 65. 0, or -1 bad args.
  if output == nil or capacity < 65 or obsVersion notin [ocV1.int32, ocV2.int32]: return -1
  let hash = observationContractHash(ObservationContractVersion(obsVersion))
  for i, c in hash: output[i] = c
  output[hash.len] = '\0'
  0

proc pw_destroy*(handle: pointer) {.exportc, cdecl, dynlib.} =
  if handle == nil: return
  ready()
  let env = cast[ptr NativeEnv](handle)
  `=destroy`(env[])
  deallocShared(env)

proc pw_reset*(handle: pointer, seed, maxTicks: int32): cint {.exportc, cdecl, dynlib.} =
  if handle == nil or maxTicks < 0 or maxTicks > HeartMeterMatchTicks: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  try:
    env.world = newWorld(seed,maxTicks)
    for i in 0..<Seats: env.resets[i] = 1
    env.invalidateBodies()
    env.resetStats()
    env.resetScripts()
    env.resetCurriculum()
    env.resetAimMemories()
    env.resetSampling()
    env.resetStrafe()
    env.resetSnapSteady()
    for slot in 0..<Seats:
      env.commandPending[slot] = false
      env.commandShown[slot] = false
    return 0
  except CatchableError: return -1

proc pw_observe_seats*(handle: pointer, seats: uint32, observations, resets: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## Encode only the seats whose bit is set; the other seats' buffer rows are left as
  ## they are. A host training one side against built-in bots need not pay for the
  ## bots' observations. Bit s is slot s. Same bytes as pw_observe for chosen seats.
  if handle == nil or observations == nil or resets == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  try:
    if env.obsVersion == ocV1:
      for slot in 0..<Seats:
        if (seats and (1'u32 shl slot)) == 0: continue
        encodeObservation(env.world,slot,observations.toOpenArray(slot*ObservationSize,(slot+1)*ObservationSize-1),
          env.bodiesFor(slot))
        resets[slot] = env.resets[slot]
    else:
      let n = observationSize(env.obsVersion)
      for slot in 0..<Seats:
        if (seats and (1'u32 shl slot)) == 0: continue
        encodeObservation(env.world,slot,observations.toOpenArray(slot*n,(slot+1)*n-1),
          env.bodiesFor(slot),env.obsVersion)
        resets[slot] = env.resets[slot]
    return 0
  except CatchableError: return -1

proc pw_observe*(handle: pointer, observations, resets: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  pw_observe_seats(handle, 0xffff'u32, observations, resets)

proc pw_step*(handle: pointer, actions: ActionBuffer, rewards, terminals: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## Settled score reward only, normalized by 1000. Optional shaping belongs in
  ## the training adapter, never hidden in the game ABI. No implicit auto-reset.
  ## -3: a live seat whose actions are decoded from the caller chose a movement index
  ## its forbid mask lists (pw_set_seat_forbid_objectives); nothing is stepped.
  if handle == nil or actions == nil or rewards == nil or terminals == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  if env.world.winner != -1 or env.world.tick >= env.world.endTick: return -2
  for slot in 0..<Seats:
    if not env.forbidAny[slot] or env.world.cogs[slot].hp <= 0 or env.commandPending[slot] or
        (env.scripts[slot].len > 0 and env.overrideMask[slot] == 0): continue
    let movement = actions[slot*ActionSizes.len]
    if movement in 0'i32..<ActionSizes[0].int32 and env.forbidden[slot][movement]: return -3
  try:
    var commands: array[Seats,Command]
    var wasDead: array[Seats,bool]
    for slot in 0..<Seats:
      wasDead[slot] = env.world.cogs[slot].hp <= 0
      if env.commandPending[slot] or (env.scripts[slot].len > 0 and env.overrideMask[slot] == 0): continue
      commands[slot] = env.decodeSeat(slot, actions)
    if env.scriptCount > 0:
      # The production tick: every BASIC seat decides on the pre-step world (hearing
      # what was shouted last tick), shouts are delivered for next tick, then the world
      # steps. Unscripted seats hold no bot and shout nothing. A decision already taken
      # for this tick by pw_script_decide is used as it is.
      if not (env.decidedValid and env.decidedTick == env.world.tick): env.scriptDecide()
      env.decidedValid = false
      for slot in 0..<Seats:
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
    for slot in 0..<Seats:
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
    for slot in 0..<Seats:
      if env.fireHold[slot] and env.world.holdFire(slot, commands[slot],
          if env.fireHoldRadius[slot] > 0: env.fireHoldRadius[slot] else: FireHoldRadius.int32):
        inc env.fireHeld[slot]
      env.gateFire(slot, commands[slot])
    combatTelemetry = addr env.stats
    damageScale = addr env.damagePermille
    try: env.world.step(commands)
    finally:
      combatTelemetry = nil
      damageScale = nil
    env.invalidateBodies()
    let done = env.world.winner != -1 or env.world.tick >= env.world.endTick
    for slot in 0..<Seats:
      rewards[slot] = if done: float32(env.world.glory[team(slot)])/1000 else: 0
      terminals[slot] = float32(done.int)
      env.resets[slot] = float32((wasDead[slot] or env.world.cogs[slot].hp<=0 or done).int)
    return 0
  except CatchableError: return -1

proc pw_state_hash*(handle: pointer): uint32 {.exportc, cdecl, dynlib.} =
  if handle == nil: return 0
  ready()
  cast[ptr NativeEnv](handle).world.stateHash()

proc pw_results*(handle: pointer, output: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## [tick, winner, glory0, glory1, meter0, meter1, hearts0, hearts1].
  if handle == nil or output == nil: return -1
  ready()
  let w = cast[ptr NativeEnv](handle).world
  output[0] = w.tick.float32
  output[1] = w.winner.float32
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
  ## Write only the selected team's slots in a full 16-seat action buffer.
  if handle == nil or actions == nil or side notin 0..1 or level notin 1..2: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  for slot in 0..<Seats:
    if team(slot) == side:
      if level == 2 and env.world.cogs[slot].hp > 0:
        trainingBotActions(env.world,slot,level.int,
          actions.toOpenArray(slot*ActionSizes.len,(slot+1)*ActionSizes.len-1),env.bodiesFor(slot))
      else:
        trainingBotActions(env.world,slot,level.int,
          actions.toOpenArray(slot*ActionSizes.len,(slot+1)*ActionSizes.len-1))
  return 0

proc pw_seat_stats*(handle: pointer, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Per-seat combat telemetry, 16 seats x 8 int32 in seat order:
  ## [damage_dealt_enemy, damage_dealt_team, hits_enemy, hits_taken, kills, deaths,
  ##  captures, first_friendly_fire_tick (-1 if none)]. Cumulative since the last
  ## create/reset. Damage is health removed (armor absorbs first); a hit is a damage
  ## event past shield and life checks; captures are the world's own credit for
  ## flipping a heart. Pure telemetry: reading or ignoring it changes no state.
  if handle == nil or output == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  for slot in 0..<Seats:
    let s = env.stats[slot]
    let o = slot*8
    output[o] = s.damageDealtEnemy; output[o+1] = s.damageDealtTeam
    output[o+2] = s.hitsEnemy; output[o+3] = s.hitsTaken
    output[o+4] = s.kills; output[o+5] = s.deaths
    output[o+6] = env.world.cogs[slot].captures; output[o+7] = s.firstFriendlyFireTick
  return 0

proc pw_set_seat_script*(handle: pointer, seat: cint, source: ptr UncheckedArray[char],
    length: int32): cint {.exportc, cdecl, dynlib.} =
  ## Drive one seat from BASIC source text with the production interpreter, host
  ## functions, limits and per-decision budget; the caller's actions for that seat are
  ## ignored while a script is installed. Compiles now; a fresh runtime with cleared
  ## persistent variables is installed here and again on every pw_reset. length 0
  ## removes the script. Returns 0 (running), 1 (compile failed: the seat is disabled and
  ## idles, as a hosted seat would), -1 (bad arguments).
  if handle == nil or seat notin 0..<Seats or length < 0 or (length > 0 and source == nil): return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  if env.scripts[seat].len > 0: dec env.scriptCount
  env.scripts[seat] = newString(length)
  if length > 0: copyMem(addr env.scripts[seat][0], source, length)
  env.scriptHeard[seat] = @[]
  env.installScript(seat)
  if env.scripts[seat].len > 0: inc env.scriptCount
  if env.scriptStatus[seat] == 2: 1 else: 0

proc pw_seat_script_status*(handle: pointer, seat: cint, message: ptr UncheckedArray[char],
    capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## 0 unscripted, 1 running, 2 compile failed, 3 disabled by a runtime error (budget
  ## overrun, bad host call, ...), exactly the errors that disable a hosted seat. The
  ## error text is copied, NUL-terminated and truncated to capacity, when given.
  if handle == nil or seat notin 0..<Seats: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  if message != nil and capacity > 0:
    let n = min(capacity.int-1, env.scriptErrors[seat].len)
    if n > 0: copyMem(message, unsafeAddr env.scriptErrors[seat][0], n)
    message[n] = '\0'
  env.scriptStatus[seat]

proc pw_seat_orders*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## The command a scripted seat issued on the last pw_step, ten int32:
  ## [walk, goal_x, goal_z, shoot, aim_x, aim_z, charge_grenade, sneak, direct, scripted].
  ## walkTo sets walk+goal; lookAt sets aim; shootAt sets shoot+aim (the last call of
  ## each kind wins, as in the game). aim (0,0) means no aim order, as the game reads
  ## it. A seat given a raw command (pw_set_seat_command) for the last step reports that
  ## command instead. Other unscripted seats report zeros with scripted=0.
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
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
  ## point), lookAt/shootAt's aim clamped to the map (aim (0,0) = no aim order). For that
  ## step the seat's heads are not decoded and not checked against its forbid mask (no
  ## decoder option runs for it; its contract-v2 aim memory is not recorded), and a
  ## scripted seat's script still runs but its order is replaced. The fire hold and the
  ## fire period apply only if already set on the seat (both off by default).
  ## pw_seat_orders echoes the command after the step (an unscripted seat reports zeros
  ## again after a step without one). A later call before the step replaces it; pw_reset
  ## drops it. Never calling it is byte-identical to a library without it. Returns 0, -1
  ## for bad arguments.
  if handle == nil or seat notin 0..<Seats or nine == nil: return -1
  for i in [0, 3, 6, 7, 8]:
    if nine[i] notin 0'i32..1'i32: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.commandNext[seat] = Command(walk: nine[0] == 1, goal: Point(x: nine[1], z: nine[2]), shoot: nine[3] == 1,
    aim: Point(x: clamp(nine[4], minX().int32, maxX().int32), z: clamp(nine[5], minZ().int32, maxZ().int32)),
    chargeGrenade: nine[6] == 1, sneak: nine[7] == 1, direct: nine[8] == 1)
  env.commandPending[seat] = true
  0

proc pw_set_action_contract*(handle: pointer, version: int32): cint {.exportc, cdecl, dynlib.} =
  ## Select the action contract the caller's actions (and the Nim bot's, and any
  ## override-mapped scripted seat's) are decoded under: 1 = v1 (identity aim is the
  ## body's position; the default and byte-identical to a library without this call),
  ## 2 = v2 (identity aim is the body's lead-compensated aim point, see
  ## neural_contract.nim). Kept across pw_reset; every seat's aim memory is cleared here
  ## and on every reset. Returns 0, -1 for a bad handle or version.
  if handle == nil or version notin 1..2: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.contract = ActionContractVersion(version)
  env.resetAimMemories()
  0

proc pw_action_contract*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## The selected action contract version, 1 or 2; -1 for a bad handle.
  if handle == nil: return -1
  ready()
  cint(cast[ptr NativeEnv](handle).contract)

proc pw_action_contract_hash*(version: int32, output: ptr UncheckedArray[char],
    capacity: int32): cint {.exportc, cdecl, dynlib.} =
  ## The 64-hex SHA-256 contract hash an actor and its manifest must carry to be decoded
  ## under `version` (1 or 2), NUL-terminated into output (capacity >= 65). Returns 0,
  ## -1 for a bad version or buffer.
  if version notin 1..2 or output == nil or capacity < 65: return -1
  let hash = actionContractHash(ActionContractVersion(version))
  copyMem(output, unsafeAddr hash[0], hash.len)
  output[hash.len] = '\0'
  0

proc pw_action_candidates*(handle: pointer, seat: cint, movement, sneak: int32,
    goals, aims: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Diagnostic for demonstration mapping: the point every head index of the movement
  ## head (51 x {x, z}) and the aim head (25 x {x, z}) resolves to for this seat on the
  ## current pre-step world under the selected contract, from the seat's own fog and,
  ## under v2, its aim memory and the planned move of the given movement and sneak
  ## heads (a v2 identity aim depends on them), exactly as the coming pw_step would
  ## decode them. Index 0 is the seat's position / current aim (the "keep" candidates).
  ## A candidate that does not exist now (missing heart, unavailable or unseen pickup,
  ## identity nobody visible carries) and every entry of a dead seat is INT32_MIN in both
  ## coordinates. Reading changes no state. Returns 0, -1 on bad arguments.
  if handle == nil or seat notin 0..<Seats or goals == nil or aims == nil or
      movement notin 0..<ActionSizes[0].int32 or sneak notin 0..1: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  let slot = seat.int
  for i in 0..<ActionSizes[0]*2: goals[i] = low(int32)
  for i in 0..<ActionSizes[1]*2: aims[i] = low(int32)
  if env.world.cogs[slot].hp <= 0: return 0
  let bodies = env.bodiesFor(slot)
  var chosenGoal = env.world.cogs[slot].pos
  for index in 0..<ActionSizes[0]:
    let (found, p) = if index == 0: (true, env.world.cogs[slot].pos)
                     else: env.world.goalCandidate(slot, index)
    if found:
      goals[index*2] = p.x; goals[index*2+1] = p.z
      if index == movement.int: chosenGoal = p
  let ownStep = if env.contract == acV2: env.world.plannedStep(slot, chosenGoal, sneak != 0)
                else: Point()
  for aim in 0..<ActionSizes[1]:
    let (found, p) = if aim == 0: (true, env.world.cogs[slot].aim)
                     else: env.world.aimCandidate(slot, aim, bodies, env.contract, env.aimMemory[slot], ownStep)
    if found:
      aims[aim*2] = p.x; aims[aim*2+1] = p.z
  0

proc pw_script_decide*(handle: pointer): cint {.exportc, cdecl, dynlib.} =
  ## Diagnostic: run the scripted seats' decision for the current tick now (once;
  ## repeated calls before the next pw_step are no-ops) so pw_seat_orders reports the
  ## orders the coming pw_step will execute. With every override mask 0 the world is
  ## byte-identical whether or not this is called. Returns 1 when a decision was taken,
  ## 0 when nothing was needed, -1 on a bad handle.
  if handle == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  if env.scriptCount == 0 or env.world.winner != -1 or env.world.tick >= env.world.endTick: return 0
  if env.decidedValid and env.decidedTick == env.world.tick: return 0
  env.scriptDecide()
  1

proc pw_set_seat_override*(handle: pointer, seat: cint, mask: int32): cint {.exportc, cdecl, dynlib.} =
  ## Diagnostic: heads of a scripted seat taken from the caller's decoded action instead
  ## of the script's order (bits: 1 walk/goal/direct, 2 aim, 4 shoot, 8 grenade, 16
  ## sneak; 0 = exact script play). Kept across pw_reset like the curriculum knobs.
  if handle == nil or seat notin 0..<Seats or mask < 0 or mask > 31: return -1
  ready()
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
  if handle == nil or seat notin 0..<Seats or period < 1: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.firePeriod[seat] = period
  0

proc pw_set_seat_damage_scale*(handle: pointer, seat: cint, permille: int32): cint {.exportc, cdecl, dynlib.} =
  ## Curriculum: damage dealt BY this seat is scaled by permille/1000 (floor: with
  ## 1-point gun hits, anything below 1000 means no damage; grenade 2/6 and spray 3
  ## scale in steps). Hits still land (shield, cooldown relief, telemetry, glory as
  ## before). 1000 restores exact behaviour. Kept across pw_reset.
  if handle == nil or seat notin 0..<Seats or permille < 0: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.damagePermille[seat] = permille
  0

proc pw_set_seat_fire_hold*(handle: pointer, seat: cint, enabled: int32): cint {.exportc, cdecl, dynlib.} =
  ## The decoder fire hold for one seat (the hosted bundle option
  ## decoder.fire_hold_teammates): with 1, the seat's final shoot order on every pw_step,
  ## whoever issued it (the caller's decoded action, the Nim bot, a script, an override
  ## mix), is dropped when a teammate it can see stands within the gun's hit tolerance
  ## of the segment from the seat to the aim the order leaves and no farther along it
  ## than the aim point (neural_contract.holdFire); the aim and everything else in the
  ## order stand. 0 (the default) is byte-identical to a library without this call.
  ## Kept across pw_reset. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats or enabled notin 0..1: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.fireHold[seat] = enabled == 1
  0

proc pw_set_seat_fire_hold_radius*(handle: pointer, seat: cint, radius: int32): cint {.exportc, cdecl, dynlib.} =
  ## The fire hold's radius for one seat (the hosted bundle option
  ## decoder.fire_hold_teammates {"radius": r}): with radius in 1..2000, the hold
  ## (pw_set_seat_fire_hold) drops the seat's shoot order when a teammate it can see stands
  ## within `radius` of the line of fire instead of the gun's hit tolerance (55). 0 restores
  ## the default 55 (the default; byte-identical to a library without this call). It does
  ## not turn the hold on or off. Kept across pw_reset. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats or radius < 0 or radius > MaxFireHoldRadius: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.fireHoldRadius[seat] = radius
  0

proc pw_seat_fire_hold_radius*(handle: pointer, seat: cint): cint {.exportc, cdecl, dynlib.} =
  ## The seat's effective fire-hold radius (55 unless set). Returns -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats: return -1
  ready()
  let r = cast[ptr NativeEnv](handle).fireHoldRadius[seat]
  cint(if r > 0: r else: FireHoldRadius.int32)

proc pw_seat_fire_held*(handle: pointer, seat: cint): cint {.exportc, cdecl, dynlib.} =
  ## Shoot orders the fire hold dropped for the seat since the last create/reset (0 with
  ## the hold off). Pure telemetry. Returns -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats: return -1
  ready()
  cint(cast[ptr NativeEnv](handle).fireHeld[seat])

proc pw_set_seat_sampling*(handle: pointer, seat: cint, temperaturePermille, headMask: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder sampling for one seat (the hosted bundle option decoder.sampling): with
  ## temperaturePermille > 0 (10 .. 10000 = 0.01 .. 10.0), pw_sample_actions draws the
  ## heads in headMask (bit h = head h; 0 = every head) from softmax(logits / T) with the
  ## seat's stream and takes argmax for the rest; 0 (the default) makes it plain argmax
  ## with no draw. Only pw_sample_actions is affected: pw_step takes the caller's actions
  ## as before, so a library with this call is byte-identical when it is never made.
  ## Kept across pw_reset (the stream itself is reseeded). Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats: return -1
  if temperaturePermille < 0 or temperaturePermille > 10_000 or headMask < 0 or headMask >= (1 shl ActionSizes.len): return -1
  if temperaturePermille != 0 and temperaturePermille < 10: return -1
  ready()
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
  ## or non-finite logits.
  if handle == nil or seat notin 0..<Seats or logits == nil or actions == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
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
  if handle == nil or seat notin 0..<Seats: return -1
  ready()
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
  if handle == nil or seat notin 0..<Seats or count < 0 or count >= ActionSizes[0].int32: return -1
  if count > 0 and indices == nil: return -1
  var mask: ObjectiveMask
  for i in 0..<count.int:
    let index = indices[i]
    if index notin 0'i32..<ActionSizes[0].int32 or mask[index]: return -1
    mask[index] = true
  ready()
  let env = cast[ptr NativeEnv](handle)
  if env.steadyShot[seat] and mask[SteadyMovement]: return -1  # the steady shot stands on index 0
  env.forbidden[seat] = mask
  env.forbidAny[seat] = mask.forbidsAny
  0

proc pw_seat_forbidden_objectives*(handle: pointer, seat: cint, mask: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## The seat's forbid mask: mask (int32[51], may be NULL) gets 1 for each forbidden
  ## movement-head index and 0 otherwise, the logit mask a trainer applies before it
  ## samples. Returns the number forbidden, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  var n = 0
  for index in 0..<ActionSizes[0]:
    let on = env.forbidden[seat][index]
    if mask != nil: mask[index] = on.int32
    if on: inc n
  cint(n)

proc pw_set_seat_strafe*(handle: pointer, seat: cint, range, legMin, legMax, shotLegMin, shotLegMax,
    reversePermille: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder strafe legs for one seat (the hosted bundle option decoder.strafe_legs; see
  ## neural_contract.strafeActions): with range > 0, on every pw_step while the seat sees
  ## an apparent enemy within `range` and is not in a trench, the caller's movement index
  ## for it is replaced by a compass leg perpendicular to the nearest such enemy (3/4
  ## lateral plus the direction to the heart or pickup the movement index names), held
  ## legMin..legMax ticks, or shotLegMin..shotLegMax when a shoot order the gun can take
  ## starts it (a ready shot with fewer than shotLegMin ticks left on the leg starts a new
  ## one), reversing with probability reversePermille/1000 per new leg. The draws come
  ## from the seat's own stream, seeded from the match seed and the slot as the hosted
  ## seat seeds it. The pw-diag / base.bas values are 5250, 3, 6, 6, 9, 800. range 0 turns
  ## it off (the other arguments are then ignored); off on every seat is byte-identical
  ## to a library without this call. Kept across pw_reset (the leg state and stream are
  ## reset). Returns 0, -1 for bad arguments (1 <= min <= max <= 72 for legs,
  ## 6 <= min <= max <= 72 for shot legs, range <= 20000, 0 <= permille <= 1000).
  if handle == nil or seat notin 0..<Seats: return -1
  var options: StrafeOptions
  if range != 0:
    options = StrafeOptions(enabled: true, range: range, legTicks: [legMin, legMax],
      shotLegTicks: [shotLegMin, shotLegMax], reversePermille: reversePermille)
    if strafeOptionsError(options).len > 0: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.strafe[seat] = options
  0

proc pw_seat_strafe_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Strafe telemetry, three int32: [legs started, decisions whose movement index the
  ## strafe replaced (both since the last create/reset), the movement index it executed
  ## on the last pw_step or -1 when the caller's index stood]. The third is what a
  ## trainer records as the executed movement. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  output[0] = env.strafeState[seat].legs
  output[1] = env.strafeState[seat].ticks
  output[2] = env.strafeLast[seat]
  0

proc pw_set_seat_aim_snap*(handle: pointer, seat: cint, maxAngleMillideg: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder aim snap for one seat (the hosted bundle option decoder.aim_snap, angle in
  ## millidegrees: 22500 = 22.5 degrees; see neural_contract.aimSnapActions): with
  ## maxAngleMillideg in 1..90000, on every pw_step a live caller-decoded seat's shoot order
  ## with a compass aim (17..24) takes the aim index of the apparent enemy identity (1..16)
  ## it can see within that angle of the compass heading, the nearest in angle (then the
  ## nearer body, then the lower identity). 0 turns it off (the default; off on every seat
  ## is byte-identical to a library without this call). Kept across pw_reset. Returns 0,
  ## -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats: return -1
  var options: AimSnapOptions
  if maxAngleMillideg != 0:
    if aimSnapOptionsError(maxAngleMillideg).len > 0: return -1
    options = aimSnapOptions(maxAngleMillideg)
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.aimSnap[seat] = options
  0

proc pw_seat_aim_snap_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Aim-snap telemetry, three int32: [decisions snapped since the last create/reset, the
  ## aim index executed on the last pw_step or -1 when the caller's stood, the integer
  ## threshold round(cos(angle) * 32768) or 0 when off]. The second is what a trainer
  ## records as the executed aim. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  output[0] = env.aimSnaps[seat]
  output[1] = env.aimSnapLast[seat]
  output[2] = int32(env.aimSnap[seat].cosQ15)
  0

proc pw_set_seat_steady_shot*(handle: pointer, seat: cint, enabled: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder steady shot for one seat (the hosted bundle option decoder.steady_shot; see
  ## neural_contract.steadyShotActions): with 1, on every pw_step a live caller-decoded seat
  ## carrying the gun stands still (movement index 0) on the tick a shoot order the gun
  ## takes is decided (windup 0, cooldown <= 1 on the pre-step world) and on every tick its
  ## windup is running (windup > 0), i.e. from the order until the ray leaves. 0 (the
  ## default) is byte-identical to a library without this call. Kept across pw_reset.
  ## Returns 0, -1 for bad arguments or when the seat's forbid mask lists index 0.
  if handle == nil or seat notin 0..<Seats or enabled notin 0..1: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  if enabled == 1 and env.forbidden[seat][SteadyMovement]: return -1
  env.steadyShot[seat] = enabled == 1
  0

proc pw_seat_steady_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Steady-shot telemetry, three int32: [order ticks held, decisions held (order and
  ## windup ticks), both since the last create/reset, the movement index executed on the
  ## last pw_step (0) or -1 when it did not hold]. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  output[0] = env.steadyShots[seat]
  output[1] = env.steadyTicks[seat]
  output[2] = env.steadyLast[seat]
  0

proc pw_set_seat_aim_retarget*(handle: pointer, seat: cint, enabled, maxRange, hpWeight,
    carryWeight: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder aim retarget for one seat (the hosted bundle option decoder.aim_retarget; see
  ## neural_contract.aimRetargetActions): with enabled 1, on every pw_step a live
  ## caller-decoded seat's shoot order with an identity or compass aim (1..24) takes the
  ## aim index of the visible apparent enemy identity minimising
  ## d^2 - (3 - hp) * hpWeight - carrying * carryWeight with d <= maxRange, d measured to
  ## the identity's aim candidate (pw_action_candidates); none qualifies = the order
  ## stands. maxRange 1..20000, both weights 0..1e9 (5250, 160000, 2500000 = base.bas's
  ## rule, the bundle defaults). enabled 0 turns it off (the default; off on every seat is
  ## byte-identical to a library without this call; the other arguments are then
  ## ignored). Kept across pw_reset. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats or enabled notin 0..1: return -1
  var options: AimRetargetOptions
  if enabled == 1:
    if aimRetargetOptionsError(maxRange, hpWeight, carryWeight).len > 0: return -1
    options = aimRetargetOptions(maxRange, hpWeight, carryWeight)
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.aimRetarget[seat] = options
  0

proc pw_seat_aim_retarget_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Aim-retarget telemetry, three int32: [decisions whose aim it replaced since the last
  ## create/reset, the aim index it executed on the last pw_step or -1 when the caller's
  ## stood, maxRange or 0 when off]. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  output[0] = env.aimRetargets[seat]
  output[1] = env.aimRetargetLast[seat]
  output[2] = if env.aimRetarget[seat].enabled: env.aimRetarget[seat].maxRange else: 0
  0

proc pw_set_seat_shot_gate*(handle: pointer, seat: cint, maxRange: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder shot gate for one seat (the hosted bundle option decoder.shot_gate; see
  ## neural_contract.shotGateActions): with maxRange in 1..20000 (5250 = the bundle
  ## default), on every pw_step a live caller-decoded seat's shoot order, after the aim
  ## retarget and the aim snap, is dropped when its aim is still a compass index, when
  ## the snap aimed it at an enemy whose body lies beyond maxRange, or when its identity
  ## aim candidate lies beyond maxRange; the dropped decision keeps its pre-snap aim. 0
  ## turns it off (the default; off on every seat is byte-identical to a library without
  ## this call). Kept across pw_reset. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats: return -1
  var options: ShotGateOptions
  if maxRange != 0:
    if shotGateOptionsError(maxRange).len > 0: return -1
    options = shotGateOptions(maxRange)
  ready()
  let env = cast[ptr NativeEnv](handle)
  env.shotGate[seat] = options
  0

proc pw_seat_shot_gate_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Shot-gate telemetry, three int32: [shoot orders dropped since the last create/reset,
  ## the shoot head it executed on the last pw_step (0) or -1 when the caller's stood,
  ## maxRange or 0 when off]. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  output[0] = env.shotGates[seat]
  output[1] = env.shotGateLast[seat]
  output[2] = if env.shotGate[seat].enabled: env.shotGate[seat].maxRange else: 0
  0

proc pw_set_seat_spray_aim*(handle: pointer, seat: cint, maxRange: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder spray aim for one seat (the hosted bundle option decoder.spray_aim; see
  ## neural_contract.sprayAimActions): with maxRange in 1..850 (850 = the bundle default),
  ## on every pw_step a live caller-decoded seat's shoot order with a ready spray can aims at
  ## the visible apparent enemy (within maxRange + Radius, clear line) whose cone holds the
  ## most enemies. 0 turns it off (the default; byte-identical). Kept across pw_reset.
  ## Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats: return -1
  var options: SprayAimOptions
  if maxRange != 0:
    if sprayAimOptionsError(maxRange).len > 0: return -1
    options = sprayAimOptions(maxRange)
  ready()
  cast[ptr NativeEnv](handle).sprayAim[seat] = options
  0

proc pw_seat_spray_aim_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Spray-aim telemetry, three int32: [shoot orders re-aimed since the last create/reset,
  ## the aim index it executed on the last pw_step or -1, maxRange or 0 when off].
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  output[0] = env.sprayAims[seat]
  output[1] = env.sprayAimLast[seat]
  output[2] = if env.sprayAim[seat].enabled: env.sprayAim[seat].maxRange else: 0
  0

proc pw_set_seat_spray_gate*(handle: pointer, seat: cint, maxTeammates, minEnemies: int32): cint {.exportc, cdecl, dynlib.} =
  ## Decoder spray gate for one seat (the hosted bundle option decoder.spray_gate; see
  ## neural_contract.sprayGateActions): with maxTeammates in 0..7 and minEnemies in 0..8
  ## (0, 1 = the bundle defaults), on every pw_step a live caller-decoded seat's shoot order
  ## with a ready spray can is dropped unless the cone it would produce holds at least
  ## minEnemies apparent enemies and at most maxTeammates apparent teammates the seat can
  ## see. maxTeammates -1 turns it off (the default; byte-identical; minEnemies is then
  ## ignored). Kept across pw_reset. Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats: return -1
  var options: SprayGateOptions
  if maxTeammates != -1:
    if sprayGateOptionsError(maxTeammates, minEnemies).len > 0: return -1
    options = sprayGateOptions(maxTeammates, minEnemies)
  ready()
  cast[ptr NativeEnv](handle).sprayGate[seat] = options
  0

proc pw_seat_spray_gate_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Spray-gate telemetry, four int32: [shoot orders dropped since the last create/reset,
  ## the shoot head it executed on the last pw_step (0) or -1, maxTeammates or -1 when off,
  ## minEnemies or -1 when off].
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  let g = env.sprayGate[seat]
  output[0] = env.sprayGates[seat]
  output[1] = env.sprayGateLast[seat]
  output[2] = if g.enabled: g.maxTeammates else: -1
  output[3] = if g.enabled: g.minEnemies else: -1
  0

proc pw_seat_spray_stats*(handle: pointer, seat: cint, output: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Spray-can combat counters for one seat (training library only), four int32:
  ## [enemy damage, teammate damage, enemy kills, teammate kills] dealt by the seat's spray
  ## since the last create/reset. Damage is health removed (armor absorbs first), as in
  ## pw_seat_stats; attribution is the damage's owner and the spray burst. Pure telemetry.
  ## Returns 0, -1 for bad arguments.
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
  let s = cast[ptr NativeEnv](handle).stats[seat]
  output[0] = s.sprayDamageEnemy
  output[1] = s.sprayDamageTeam
  output[2] = s.sprayKillsEnemy
  output[3] = s.sprayKillsTeam
  0

proc pw_terrain_cache_blocks*(): cint {.exportc, cdecl, dynlib.} =
  ## Diagnostic: resident 64x64 terrain blocks (16 KiB each) across all tables.
  cint(terrainCacheResidentBlocks())
