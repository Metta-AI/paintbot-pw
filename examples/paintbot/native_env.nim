## In-process training ABI. Build with --app:lib --mm:arc --threads:on -d:pwTraining.
## A handle may migrate between threads but must never be used concurrently.
## The caller owns flat buffers; no Nim-managed values cross the C boundary.
import sim, neural_contract, bots
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
    decided: array[Seats,Command]
    decidedTick: int32
    decidedValid: bool
  FloatBuffer = ptr UncheckedArray[cfloat]
  ActionBuffer = ptr UncheckedArray[int32]

const NativeRules* = 37

proc ready() =
  setupForeignThreadGc()
  configureRules(NativeRules)

proc invalidateBodies(env: ptr NativeEnv) =
  for slot in 0..<Seats: env.bodiesReady[slot] = false
proc resetAimMemories(env: ptr NativeEnv) =
  for slot in 0..<Seats: env.aimMemory[slot].resetAimMemory()
proc resetStats(env: ptr NativeEnv) =
  for slot in 0..<Seats: env.stats[slot] = SeatStats(firstFriendlyFireTick: -1)
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
  ## them because the seat's memory must be recorded on every decided tick.
  let offset = slot*ActionSizes.len
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

proc pw_create*(seed, maxTicks: int32): pointer {.exportc, cdecl, dynlib.} =
  ready()
  if maxTicks < 0 or maxTicks > HeartMeterMatchTicks: return nil
  let env = cast[ptr NativeEnv](allocShared0(sizeof(NativeEnv)))
  try:
    env.world = newWorld(seed,maxTicks)
    for i in 0..<Seats: env.resets[i] = 1
    env.invalidateBodies()
    env.resetStats()
    env.initCurriculum()
    env.contract = acV1
    env.resetAimMemories()
    result = env
  except CatchableError:
    `=destroy`(env[])
    deallocShared(env)

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
    for slot in 0..<Seats:
      if (seats and (1'u32 shl slot)) == 0: continue
      encodeObservation(env.world,slot,observations.toOpenArray(slot*ObservationSize,(slot+1)*ObservationSize-1),
        env.bodiesFor(slot))
      resets[slot] = env.resets[slot]
    return 0
  except CatchableError: return -1

proc pw_observe*(handle: pointer, observations, resets: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  pw_observe_seats(handle, 0xffff'u32, observations, resets)

proc pw_step*(handle: pointer, actions: ActionBuffer, rewards, terminals: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  ## Settled score reward only, normalized by 1000. Optional shaping belongs in
  ## the training adapter, never hidden in the game ABI. No implicit auto-reset.
  if handle == nil or actions == nil or rewards == nil or terminals == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  if env.world.winner != -1 or env.world.tick >= env.world.endTick: return -2
  try:
    var commands: array[Seats,Command]
    var wasDead: array[Seats,bool]
    for slot in 0..<Seats:
      wasDead[slot] = env.world.cogs[slot].hp <= 0
      if env.scripts[slot].len > 0 and env.overrideMask[slot] == 0: continue
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
    for slot in 0..<Seats: env.gateFire(slot, commands[slot])
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
  ## it. Unscripted seats report zeros with scripted=0.
  if handle == nil or seat notin 0..<Seats or output == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  let c = env.scriptOrders[seat]
  output[0] = c.walk.int32; output[1] = c.goal.x; output[2] = c.goal.z
  output[3] = c.shoot.int32; output[4] = c.aim.x; output[5] = c.aim.z
  output[6] = c.chargeGrenade.int32; output[7] = c.sneak.int32; output[8] = c.direct.int32
  output[9] = int32(env.scripts[seat].len > 0)
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

proc pw_action_candidates*(handle: pointer, seat: cint, goals, aims: ptr UncheckedArray[int32]): cint {.exportc, cdecl, dynlib.} =
  ## Diagnostic for demonstration mapping: the point every head index of the movement
  ## head (51 x {x, z}) and the aim head (25 x {x, z}) resolves to for this seat on the
  ## current pre-step world under the selected contract, from the seat's own fog and,
  ## under v2, its aim memory, exactly as the coming pw_step would decode them. Index 0
  ## is the seat's position / current aim (the "keep" candidates). A candidate that does
  ## not exist now (missing heart, unavailable or unseen pickup, identity nobody visible
  ## carries) and every entry of a dead seat is INT32_MIN in both coordinates. Reading
  ## changes no state. Returns 0, -1 on bad arguments.
  if handle == nil or seat notin 0..<Seats or goals == nil or aims == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  let slot = seat.int
  for i in 0..<ActionSizes[0]*2: goals[i] = low(int32)
  for i in 0..<ActionSizes[1]*2: aims[i] = low(int32)
  if env.world.cogs[slot].hp <= 0: return 0
  let bodies = env.bodiesFor(slot)
  for movement in 0..<ActionSizes[0]:
    let (found, p) = if movement == 0: (true, env.world.cogs[slot].pos)
                     else: env.world.goalCandidate(slot, movement)
    if found:
      goals[movement*2] = p.x; goals[movement*2+1] = p.z
  for aim in 0..<ActionSizes[1]:
    let (found, p) = if aim == 0: (true, env.world.cogs[slot].aim)
                     else: env.world.aimCandidate(slot, aim, bodies, env.contract, env.aimMemory[slot])
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

proc pw_terrain_cache_blocks*(): cint {.exportc, cdecl, dynlib.} =
  ## Diagnostic: resident 64x64 terrain blocks (16 KiB each) across all tables.
  cint(terrainCacheResidentBlocks())
