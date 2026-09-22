## Action contract v2 through the native training ABI: selection and defaults, a v2
## handle against the reference engine driven by the same shared decoder and memory,
## the candidate diagnostic against the decoder, and the mapping-ceiling diagnostics
## (pw_script_decide / pw_set_seat_override) reproducing exact scripted play with mask 0.
## Build with --mm:arc --threads:on -d:pwTraining.
import std/[unittest, os]
import polyworld/[cli, basic]
import ../examples/paintbot/[sim, neural_contract, native_env, bots]

when not defined(pwTraining): {.error: "the native ABI exists only under -d:pwTraining".}

const Root = currentSourcePath().parentDir.parentDir
const Base = Root / "coworld/paintbot/players/base.bas"
type Buffer = ptr UncheckedArray[cfloat]
template fbuf(a: untyped): Buffer = cast[Buffer](addr a[0])
template ibuf(a: untyped): ptr UncheckedArray[int32] = cast[ptr UncheckedArray[int32]](addr a[0])
template cbuf(a: untyped): ptr UncheckedArray[char] = cast[ptr UncheckedArray[char]](addr a[0])

proc setScript(handle: pointer, seat: int, source: string): cint =
  let text = if source.len > 0: cast[ptr UncheckedArray[char]](unsafeAddr source[0]) else: nil
  pw_set_seat_script(handle, seat.cint, text, source.len.int32)

proc mixedActions(w: World, actions: var array[Seats*ActionSizes.len, int32], seed: int) =
  ## Identity aims at the nearest apparent enemy, else a changing compass aim; heart
  ## objectives; fire, grenade and sneak on schedules.
  for slot in 0..<Seats:
    let o = slot*ActionSizes.len
    actions[o] = int32(1+(slot div 2+seed) mod 10)
    actions[o+1] = int32(17+(w.tick.int div 24+slot) mod 8)
    let bodies = w.observedBodies(slot)
    var best = high(int64)
    for identity, body in bodies:
      if body < 0 or w.observedTeam(slot, body) == team(slot): continue
      let d = distance2(w.cogs[slot].pos, w.cogs[body].pos)
      if d < best:
        best = d
        actions[o+1] = int32(identity+1)
    actions[o+2] = int32(w.tick mod 3 == 0)
    actions[o+3] = int32(w.tick mod 48 < 12)
    actions[o+4] = int32(slot mod 3 == 0)

suite "Native action contract v2":
  configureRules(NativeRules)
  test "selection, default, hashes and reset semantics":
    let handle = pw_create(1, 240)
    require handle != nil
    check pw_action_contract(handle) == 1
    check pw_set_action_contract(handle, 3) == -1
    check pw_set_action_contract(nil, 2) == -1
    check pw_set_action_contract(handle, 2) == 0
    check pw_action_contract(handle) == 2
    check pw_reset(handle, 2, 240) == 0
    check pw_action_contract(handle) == 2 # kept across reset, like the curriculum knobs
    var text: array[65, char]
    check pw_action_contract_hash(1, cbuf(text), 65) == 0
    check $cast[cstring](addr text[0]) == ActionContractHash
    check pw_action_contract_hash(2, cbuf(text), 65) == 0
    check $cast[cstring](addr text[0]) == ActionContractV2Hash
    check pw_action_contract_hash(2, cbuf(text), 64) == -1
    check pw_action_contract_hash(0, cbuf(text), 65) == -1
    pw_destroy(handle)
  test "a v2 handle matches the reference engine driven by the shared decoder and memory":
    for seed in [0'i32, 1, 2]:
      var reference = newWorld(seed+41, 720)
      let handle = pw_create(seed+41, 720)
      require handle != nil
      check pw_set_action_contract(handle, 2) == 0
      var memories: array[Seats, AimMemory]
      for m in memories.mitems: m.resetAimMemory()
      var actions: array[Seats*ActionSizes.len, int32]
      var commands: array[Seats, Command]
      var rewards, terminals: array[Seats, float32]
      var leads = 0
      for pass in 0..1:
        if pass == 1:
          reference = newWorld(seed+41, 720)
          check pw_reset(handle, seed+41, 720) == 0
          for m in memories.mitems: m.resetAimMemory()
        while reference.winner == -1 and reference.tick < reference.endTick:
          mixedActions(reference, actions, seed.int)
          for slot in 0..<Seats:
            let o = slot*ActionSizes.len
            let bodies = reference.observedBodies(slot)
            commands[slot] = decodeActions(reference, slot, actions.toOpenArray(o, o+4), bodies, acV2, memories[slot])
            if actions[o+1] in 1'i32..16'i32 and bodies[actions[o+1]-1] >= 0 and
                commands[slot].aim != reference.cogs[bodies[actions[o+1]-1]].pos: inc leads
            memories[slot].recordAimMemory(reference, slot, bodies)
          reference.step(commands)
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == reference.stateHash()
      check leads > 0 # The lead changed real aims; this was not a v1 world.
      pw_destroy(handle)
  test "v1 and v2 handles diverge only through identity aims":
    # Same seed, same mixed actions: the v1 handle matches the plain reference (contract
    # v1 unchanged), the v2 handle differs once an identity aim was issued at a mover.
    let a = pw_create(9, 480)
    let b = pw_create(9, 480)
    require a != nil and b != nil
    check pw_set_action_contract(b, 2) == 0
    var reference = newWorld(9, 480)
    var actions: array[Seats*ActionSizes.len, int32]
    var commands: array[Seats, Command]
    var rewards, terminals: array[Seats, float32]
    var diverged = false
    while reference.winner == -1 and reference.tick < reference.endTick:
      mixedActions(reference, actions, 0)
      for slot in 0..<Seats:
        let o = slot*ActionSizes.len
        commands[slot] = decodeActions(reference, slot, actions.toOpenArray(o, o+4))
      reference.step(commands)
      require pw_step(a, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_step(b, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
      require pw_state_hash(a) == reference.stateHash()
      if pw_state_hash(b) != reference.stateHash(): diverged = true
    check diverged
    pw_destroy(a); pw_destroy(b)
  test "candidates report what the decoder resolves, under both contracts":
    let handle = pw_create(5, 480)
    require handle != nil
    var actions: array[Seats*ActionSizes.len, int32]
    var rewards, terminals: array[Seats, float32]
    var goals: array[ActionSizes[0]*2, int32]
    var aims: array[ActionSizes[1]*2, int32]
    var reference = newWorld(5, 480)
    var memories: array[Seats, AimMemory]
    for m in memories.mitems: m.resetAimMemory()
    for version in [1'i32, 2]:
      check pw_set_action_contract(handle, version) == 0
      reference = newWorld(5, 480)
      check pw_reset(handle, 5, 480) == 0
      for m in memories.mitems: m.resetAimMemory()
      var identityCandidates = 0
      for tick in 0..<200:
        for slot in 0..<Seats:
          let bodies = reference.observedBodies(slot)
          for movement in 0..<ActionSizes[0]:
            if (movement + tick) mod 5 != 0: continue # A thinned grid keeps the test fast.
            let sneak = int32((movement + slot) mod 2)
            require pw_action_candidates(handle, slot.cint, movement.int32, sneak, ibuf(goals), ibuf(aims)) == 0
            for aim in 0..<ActionSizes[1]:
              let a = [movement.int32, aim.int32, 0'i32, 0, sneak]
              let c = decodeActions(reference, slot, a, bodies, ActionContractVersion(version), memories[slot])
              if reference.cogs[slot].hp <= 0:
                check goals[movement*2] == low(int32) and aims[aim*2] == low(int32)
                continue
              if goals[movement*2] != low(int32):
                check c.goal == point(goals[movement*2].int, goals[movement*2+1].int)
              else:
                check c.goal == reference.cogs[slot].pos
              if aims[aim*2] != low(int32):
                check c.aim == point(aims[aim*2].int, aims[aim*2+1].int)
                if aim in 1..16: inc identityCandidates
              else:
                check c.aim == reference.cogs[slot].aim
        mixedActions(reference, actions, 0)
        var commands: array[Seats, Command]
        for slot in 0..<Seats:
          let o = slot*ActionSizes.len
          let bodies = reference.observedBodies(slot)
          commands[slot] = decodeActions(reference, slot, actions.toOpenArray(o, o+4), bodies, ActionContractVersion(version), memories[slot])
          memories[slot].recordAimMemory(reference, slot, bodies)
        reference.step(commands)
        require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
        require pw_state_hash(handle) == reference.stateHash()
      check identityCandidates > 0
    check pw_action_candidates(handle, 16, 0, 0, ibuf(goals), ibuf(aims)) == -1
    check pw_action_candidates(handle, 0, 51, 0, ibuf(goals), ibuf(aims)) == -1
    check pw_action_candidates(handle, 0, 0, 2, ibuf(goals), ibuf(aims)) == -1
    pw_destroy(handle)
  test "mask 0 with pw_script_decide reproduces exact scripted play; a masked head follows the caller":
    let baseSource = readFile(Base)
    for seed in [4'i32, 8]:
      var expected: seq[uint32]
      block plain:
        let handle = pw_create(seed, 600)
        require handle != nil
        for slot in 0..<Seats: check setScript(handle, slot, baseSource) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var rewards, terminals: array[Seats, float32]
        while terminals[0] == 0 and expected.len < 600:
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          expected.add pw_state_hash(handle)
        pw_destroy(handle)
      block preDecided:
        let handle = pw_create(seed, 600)
        require handle != nil
        for slot in 0..<Seats:
          check setScript(handle, slot, baseSource) == 0
          check pw_set_seat_override(handle, slot.cint, 0) == 0
        check pw_set_seat_override(handle, 0, 32) == -1
        var actions: array[Seats*ActionSizes.len, int32]
        var rewards, terminals: array[Seats, float32]
        var orders: array[10, int32]
        for hash in expected:
          check pw_script_decide(handle) == 1
          check pw_script_decide(handle) == 0 # once per tick
          check pw_seat_orders(handle, 0, ibuf(orders)) == 0
          check orders[9] == 1
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          require pw_state_hash(handle) == hash
        pw_destroy(handle)
      block masked:
        # Team 0's shoot and grenade heads from the caller (never fire): the world diverges and the
        # scripted team lands no hits while its orders are still reported.
        let handle = pw_create(seed, 600)
        require handle != nil
        for slot in 0..<Seats:
          check setScript(handle, slot, baseSource) == 0
          if team(slot) == 0: check pw_set_seat_override(handle, slot.cint, 12) == 0
        var actions: array[Seats*ActionSizes.len, int32]
        var rewards, terminals: array[Seats, float32]
        var orders: array[10, int32]
        var stats: array[Seats*8, int32]
        var diverged = false
        var shootOrders = 0
        for hash in expected:
          require pw_step(handle, ibuf(actions), fbuf(rewards), fbuf(terminals)) == 0
          if pw_state_hash(handle) != hash: diverged = true
          check pw_seat_orders(handle, 0, ibuf(orders)) == 0
          if orders[3] == 1: inc shootOrders
          if terminals[0] != 0: break
        check pw_seat_stats(handle, ibuf(stats)) == 0
        var hitsTeam0 = 0
        for slot in 0..<Seats:
          if team(slot) == 0: hitsTeam0 += stats[slot*8+2]
        check shootOrders > 0
        check hitsTeam0 == 0
        check diverged
        pw_destroy(handle)
