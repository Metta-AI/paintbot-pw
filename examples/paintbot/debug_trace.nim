## Owned-run decision evidence for the native training library (native_env.nim, -d:pwTraining):
## schema `paintbot_native_debug_v1` of pw_debug_status_json / pw_debug_trace_json /
## pw_debug_observation_json. This module holds the trace record, the controller digest, the
## compile-aware advisor/neural reference check, the raw-command ABI normalization and the JSON
## shapes; native_env.nim owns the handle and decides when a step is captured.
##
## Nothing here is part of the world, its hash or a pw_world_save blob, and nothing here decides,
## draws a random number or changes a seat: a trace is a copy of what the step did.
import std/[json, strutils]
import bassy
import sim, bots, snapshot, basic_states, contract_hash

const
  DebugSchema* = "paintbot_native_debug_v1"
  CommandKeys* = ["walk", "goal_x", "goal_z", "shoot", "aim_x", "aim_z", "charge_grenade", "sneak",
    "direct", "self_destruct"]
  AgentKeys = ["visible", "x", "y", "hp", "team", "carrying"]
  # The host builtins whose use makes a seat's decisions depend on state outside the BASIC VM:
  # oracle.nim's addOracleFunctions (an advisor's asynchronous answers) and neural_host.nim's
  # addNeuralFunctions (a model's outputs and sampling streams). The capability check inspects
  # compiled HostCallOp targets; comments, strings and similarly named variables do not count.
  AdvisorBuiltins* = ["oracleAvailable", "oracleState", "oracleStateText", "oracleNote", "oracleQuestion",
    "oracleCriterion", "oracleCriterionField", "oracleAsk", "oracleReady", "oraclePoll", "oracleAnswer",
    "oracleConfidence", "oracleProbability"]
  NeuralBuiltins* = ["neuralModel", "neuralObservation", "neuralLogits", "neuralState", "paintbot_observe",
    "run_neural_net", "neuralInput", "neuralObs", "neuralLogit", "neuralMask", "neuralMaskFrom",
    "neuralTemperature", "neuralSample", "neuralChoice", "neuralSetChoice", "neuralLayout", "neuralRow"]

type
  DebugTrace* = object
    ## One handle's trace (pw_debug_set_trace). A step is captured in two halves: the decision
    ## (digests at pre_decision(t), each seat's evidence and intended order), then the step (the
    ## applied commands, digests at pre_decision(t+1)), rendered into `last`.
    enabled*: bool
    pending*: bool          ## a decision half for `tick` is held
    tick*: int32
    decidedAhead*: bool     ## that decision was taken by pw_script_decide
    hashBefore*: uint32
    controllerBefore*: string
    evidence*: seq[SeatDecisionEvidence]
    intended*: seq[Command]
    last*: string           ## the last completed step's JSON; "" = none

proc drop*(t: var DebugTrace) =
  ## Forgets the record and any half-captured step; tracing stays as it was.
  t = DebugTrace(enabled: t.enabled)

proc calledBuiltins*(b: Bot): seq[string] =
  ## The host builtins the seat's compiled program calls (its HostCallOp targets): what the program
  ## references, whatever its comments, strings or variable names say.
  if b.isNil or b.runtime.isNil: return
  for name, field in fieldPairs(b.runtime[]):
    when name == "program":
      let program = field
      var names: seq[string]
      for pname, pfield in fieldPairs(program[]):
        when pname == "hostFunctions":
          for spec in pfield:
            for sname, sfield in fieldPairs(spec):
              when sname == "name": names.add sfield
      for ins in program.bytecode:
        if ins.op == HostCallOp and ins.b >= 0 and ins.b.int < names.len and names[ins.b] notin result:
          result.add names[ins.b]

proc callsAny*(b: Bot, builtins: openArray[string]): bool =
  ## Bassy identifiers are case-insensitive: the compiled program names its builtins in lower case.
  for name in b.calledBuiltins:
    for builtin in builtins:
      if name == builtin.toLowerAscii: return true

proc normalizeAbi*(c: Command): Command =
  ## A command as pw_set_seat_command(_ex) builds one: goal verbatim, aim clamped to the current
  ## map (aim (0,0) = no aim order, as the ABI reads it), flags as they are.
  result = c
  result.aim = Point(x: clamp(c.aim.x, minX().int32, maxX().int32), z: clamp(c.aim.z, minZ().int32, maxZ().int32))

proc commandJson*(c: Command): JsonNode =
  ## The ten-field command object, in pw_set_seat_command_ex order.
  %*{"walk": c.walk, "goal_x": c.goal.x, "goal_z": c.goal.z, "shoot": c.shoot, "aim_x": c.aim.x,
    "aim_z": c.aim.z, "charge_grenade": c.chargeGrenade, "sneak": c.sneak, "direct": c.direct,
    "self_destruct": c.selfDestruct}

proc observationJson*(tick: int32, values: openArray[int32], agents: openArray[array[6, int32]]): JsonNode =
  ## A seat's SeatView observation: its DATA values (DataNames) and its `agents` roster.
  var self = newJObject()
  for i, name in DataNames: self[name] = %values[i]
  var roster = newJArray()
  for slot, row in agents:
    var a = %*{"slot": slot}
    for k, key in AgentKeys: a[key] = %row[k]
    roster.add a
  %*{"visibility": "seat", "as_of_tick": tick, "source": "seat_view", "self": self, "agents": roster}

proc seatObservation*(slot: int, tick: int32): JsonNode =
  ## The seat's observation from the views beginViews started (no decision, no budget charged).
  let view = seatView(slot)
  var roster = newSeq[array[6, int32]](Seats)
  for i in 0..<Seats:
    roster[i] = [view.visible(i), view.playerX(i), view.playerY(i), view.playerHp(i), view.playerTeam(i),
      view.playerCarrying(i)]
  observationJson(tick, view.dataValues, roster)

proc putBot*(w: var SnapWriter, b: Bot) =
  ## The seat's whole controller state, as pw_world_save records it.
  w.put(not b.isNil)
  if b.isNil: return
  w.putBytes(b.runtime.saveState())
  w.put(not b.strings.isNil)
  if not b.strings.isNil: w.putBytes(b.strings.saveState())
  w.put(b.failed); w.put(b.error)
  w.put(b.neural)
  w.put(b.rnd)

proc controllerDigest*(bots: openArray[Bot], status: openArray[int32], errors: openArray[string],
    heard: openArray[seq[HeardMessage]]): string =
  ## sha256 over every seat's BASIC runtime, string pool, failure, neural record and rnd stream, its
  ## script status/error and the speech it carries into its next decision. A pure read.
  var w: SnapWriter
  w.put(DebugSchema)
  w.put(bots.len)
  for slot in 0..<bots.len:
    w.putBot(bots[slot])
    w.put(if slot < status.len: status[slot] else: 0'i32)
    w.put(if slot < errors.len: errors[slot] else: "")
    w.put(if slot < heard.len: heard[slot] else: @[])
  var s = newString(w.data.len)
  if s.len > 0: copyMem(addr s[0], addr w.data[0], s.len)
  sha256Hex(s)

proc vmJson(e: SeatDecisionEvidence): JsonNode =
  let l = limits()
  %*{"ran": e.ran, "failed": e.failed, "error": (if e.error.len > 0: %e.error else: newJNull()),
    "instructions": e.instructions, "work_units": e.workUnits, "max_instructions": l.maxInstructions,
    "max_work_units": l.maxWorkUnits}

proc renderStep*(t: DebugTrace, hashAfter: uint32, controllerAfter: string, programs: openArray[bool],
    applied: openArray[Command], raw: openArray[bool]): string =
  ## The completed step's trace JSON.
  var seats = newJArray()
  for slot in 0..<applied.len:
    let program = slot < programs.len and programs[slot]
    let e = if slot < t.evidence.len: t.evidence[slot] else: SeatDecisionEvidence()
    var s = %*{"seat": slot, "program": (if program: "basic" else: "none"), "decided": e.ran}
    if e.ran:
      s["observation"] = observationJson(t.tick, e.values, e.agents)
      s["observation_missing_reason"] = newJNull()
    else:
      s["observation"] = newJNull()
      s["observation_missing_reason"] =
        if not program: %"no_program" elif e.captured: %e.skipped else: %"program_failed"
    if program and e.captured and slot < t.intended.len:
      s["intended"] = t.intended[slot].commandJson
      s["normalized"] = t.intended[slot].normalizeAbi.commandJson
      s["applied"] = applied[slot].commandJson
      s["replaced_by_raw_command"] = %(slot < raw.len and raw[slot])
      s["vm"] = e.vmJson
    else:
      s["intended"] = newJNull()
      s["normalized"] = newJNull()
      s["applied"] = applied[slot].commandJson
      s["replaced_by_raw_command"] = %(slot < raw.len and raw[slot])
      s["vm"] = newJNull()
    s["source_trace"] = newJNull()
    seats.add s
  $(%*{"schema_version": DebugSchema, "tick": t.tick, "decided_ahead": t.decidedAhead,
    "world_hash_before": $t.hashBefore, "world_hash_after": $hashAfter,
    "controller_sha256_before": t.controllerBefore, "controller_sha256_after": controllerAfter,
    "seats": seats})

proc phaseName(decided: bool): string =
  if decided: "post_decision_pre_step" else: "pre_decision"

proc statusJson*(tick: int32, terminal, decided: bool, reasons: seq[string], pending, enabled: bool,
    seats, rules: int, buildId: string, programs: seq[string], controller: string, worldHash: uint32): string =
  ## pw_debug_status_json's object.
  $(%*{"schema_version": DebugSchema, "tick": tick, "terminal": terminal, "phase": phaseName(decided),
    "supported": reasons.len == 0, "reasons": reasons, "pending_override": pending, "trace_enabled": enabled,
    "seats": seats, "rules_version": rules, "snapshot_build_id": buildId, "program_sha256": programs,
    "controller_sha256": controller, "world_hash": $worldHash})

proc observationDoc*(seat: int, tick: int32, decided: bool, observation: JsonNode): string =
  ## pw_debug_observation_json's object.
  $(%*{"schema_version": DebugSchema, "seat": seat, "tick": tick, "phase": phaseName(decided),
    "observation": observation})

proc writeJson*(doc: string, output: ptr UncheckedArray[char], capacity: int32): cint =
  ## pw_world_json's convention: the length, the bytes (no NUL) only when capacity holds them.
  if capacity >= doc.len and doc.len > 0: copyMem(output, unsafeAddr doc[0], doc.len)
  doc.len.cint
