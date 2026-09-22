## In-process training ABI. Build with --app:lib --mm:arc --threads:on -d:pwTraining.
## A handle may migrate between threads but must never be used concurrently.
## The caller owns flat buffers; no Nim-managed values cross the C boundary.
import sim, neural_contract

when not defined(pwTraining): {.error: "native_env requires -d:pwTraining".}

type
  NativeEnv = object
    world: World
    resets: array[Seats,float32]
  FloatBuffer = ptr UncheckedArray[cfloat]
  ActionBuffer = ptr UncheckedArray[int32]

const NativeRules* = 36

proc ready() =
  setupForeignThreadGc()
  configureRules(NativeRules)

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
    return 0
  except CatchableError: return -1

proc pw_observe*(handle: pointer, observations, resets: FloatBuffer): cint {.exportc, cdecl, dynlib.} =
  if handle == nil or observations == nil or resets == nil: return -1
  ready()
  let env = cast[ptr NativeEnv](handle)
  try:
    for slot in 0..<Seats:
      encodeObservation(env.world,slot,observations.toOpenArray(slot*ObservationSize,(slot+1)*ObservationSize-1))
      resets[slot] = env.resets[slot]
    return 0
  except CatchableError: return -1

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
      commands[slot] = decodeActions(env.world,slot,actions.toOpenArray(slot*ActionSizes.len,(slot+1)*ActionSizes.len-1))
    env.world.step(commands)
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
      trainingBotActions(env.world,slot,level.int,
        actions.toOpenArray(slot*ActionSizes.len,(slot+1)*ActionSizes.len-1))
  return 0
