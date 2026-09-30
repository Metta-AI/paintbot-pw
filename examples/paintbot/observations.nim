import
  bassy,
  seat_view

const
  SelfFields = [
    "id", "team", "x", "y", "hp", "carrying", "homeX", "homeY",
    "heartX", "heartY", "tick", "ownHeartX", "ownHeartY",
    "ownHeartStolen", "hasGrenade", "hasSpray", "armorHp",
    "livesLeft", "grenadeCharge", "trenchId"
  ]
  AgentFields = ["visible", "x", "y", "hp", "team", "carrying"]

type
  DataBinding = object
    field: int
    id: int32
  SelfBinding = object
    field: int
    view: GlobalView
  Observations* = object
    data: seq[DataBinding]
    selves: seq[SelfBinding]

proc recordSource*(): string =
  ## Declares the seat's scalar and fog-gated roster records.
  result = "TYPE SelfState\n"
  for field in SelfFields:
    result.add "  " & field & " AS INTEGER\n"
  result.add "END TYPE\nDIM me AS SelfState\nTYPE AgentState\n"
  for field in AgentFields:
    result.add "  " & field & " AS INTEGER\n"
  result.add "END TYPE\nDIM agents(" & $(Seats - 1) & ") AS AgentState\n"

proc loadField(slot, field: int, values: ArrayView) =
  ## Fills one roster field exclusively through this tick's SeatView.
  let view = seatView(slot)
  for i in 0 ..< values.len:
    let value =
      case field
      of 0: view.visible(i)
      of 1: view.playerX(i)
      of 2: view.playerY(i)
      of 3: view.playerHp(i)
      of 4: view.playerTeam(i)
      else: view.playerCarrying(i)
    values[i] = toValue(value)

proc fieldLoader(runtime: Runtime, slot, field: int): ArrayLoader =
  ## Captures one field independently from the binding loop.
  result = proc(values: ArrayView) =
    ## Charges and refreshes one fog-gated column on first access.
    runtime.chargeWork(int64(values.len) * 4)
    loadField(slot, field, values)

proc bindObservations*(
    runtime: Runtime,
    program: Program,
    slot: int
): Observations =
  ## Binds referenced scalar fields and lazy roster columns before JIT setup.
  for i, name in DataNames:
    let id = program.hostDataIndex(name)
    for instruction in program.bytecode:
      case instruction.op
      of LoadHostDataOp, AddGlobalHostDataOp:
        if instruction.b == id:
          result.data.add DataBinding(field: i, id: id)
          break
      else:
        discard
  for i, field in SelfFields:
    let name = "me." & field
    if program.referencesGlobal(name):
      result.selves.add SelfBinding(field: i, view: runtime.globalView(name))
  for i, field in AgentFields:
    let name = "agents." & field
    runtime.setArrayLoader(name, fieldLoader(runtime, slot, i))

proc refresh*(
    observations: Observations,
    runtime: var Runtime,
    values: openArray[int32]
) =
  ## Refreshes referenced scalar observations through their bound accessors.
  for binding in observations.data:
    runtime.setData(binding.id, toValue(values[binding.field]))
  for binding in observations.selves:
    binding.view.value = toValue(values[binding.field])
