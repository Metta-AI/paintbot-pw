## Advisor oracle for BASIC seats. The engine never touches the network: a script drafts one
## request through typed host functions, the engine ships it to the Python host over the policy
## bridge, the host asks the operator-configured endpoint, and the flattened answer comes back
## on a later tick. Everything a script sees is int32; probabilities, scores and confidences are
## scaled by 1000. Without a configured oracle every ask is refused and nothing else changes.
import std/[json, tables]
import polyworld/basic
import sim

const
  MaxStateFields* = 128
  MaxNotes* = 16
  MaxQuestions* = 64
  MaxCriteria* = 16
  MaxKeyLength* = 64
  MaxBodyBytes* = 32 * 1024
  MaxStoredAnswers* = 4
  DefaultOracleInterval* = 24
  OraclePending* = 0'i32
  OracleFailed* = -1'i32
  OracleMissing* = -1'i32

type
  QuestionKind* = enum
    noulQuestion = 0, scoreQuestion = 1, choiceQuestion = 2
  Question = object
    kind: QuestionKind
    instructions: string
    labels, texts: seq[string]
  Draft = object
    ints: OrderedTable[string, int32]
    texts: OrderedTable[string, string]
    notes: seq[string]
    questions: OrderedTable[string, Question]
  OracleAnswer* = object
    value*: int32
    confidence*: int32
    probabilities*: Table[string, int32]
  OracleReply* = object
    ## One settled request as the host reports it: status -1 failed, else the answer count.
    slot*, id*, status*: int
    answers*: Table[string, OracleAnswer]
  OracleAsk* = object
    slot*, id*: int
    body*: string ## JSON text: {"state": ..., "questions": ...}
  Stored = object
    status: int32
    answers: Table[string, OracleAnswer]
  Seat = object
    draft: Draft
    inflight: int32
    asked: bool
    lastTick: int32
    nextId: int32
    answers: OrderedTable[int32, Stored]

when defined(pwTraining):
  # Training worlds never have an advisor: every ask is refused. The per-seat drafts are
  # still written by scripts, so they are thread-local like the rest of the seat state.
  var
    oracleEnabled* {.threadvar.}: bool
    oracleInterval* {.threadvar.}: int
    currentTick {.threadvar.}: int32
    seats {.threadvar.}: array[Seats, Seat]
    pendingAsks {.threadvar.}: seq[OracleAsk]
    seatsReady {.threadvar.}: bool
else:
  var
    oracleEnabled*: bool
    oracleInterval* = DefaultOracleInterval
    currentTick: int32
    seats: array[Seats, Seat]
    pendingAsks: seq[OracleAsk]
    seatsReady: bool

proc newDraft(): Draft =
  # Default-initialised OrderedTables cannot be iterated, so build every table explicitly.
  Draft(ints: initOrderedTable[string, int32](), texts: initOrderedTable[string, string](),
      questions: initOrderedTable[string, Question]())

proc newSeat(): Seat =
  Seat(draft: newDraft(), answers: initOrderedTable[int32, Stored]())

proc resetOracle*() =
  ## Forgets every seat's requests and answers (new match or test).
  for s in seats.mitems: s = newSeat()
  pendingAsks = @[]

proc beginOracleTick*(tick: int32) =
  ## Drafts live for one decision only: the string pool that named them resets each tick.
  currentTick = tick
  for s in seats.mitems: s.draft = newDraft()

proc drainOracleAsks*(): seq[OracleAsk] =
  ## Hands this tick's accepted requests to the bridge, oldest first.
  result = pendingAsks
  pendingAsks = @[]

proc deliverOracleReply*(reply: OracleReply) =
  ## Stores a settled request; at most MaxStoredAnswers are kept per seat, oldest dropped.
  if reply.slot < 0 or reply.slot >= Seats: return
  template seat: untyped = seats[reply.slot]
  if seat.inflight == reply.id.int32: seat.inflight = 0
  seat.answers[reply.id.int32] = Stored(status: (if reply.status < 0: OracleFailed
      else: reply.answers.len.int32), answers: reply.answers)
  while seat.answers.len > MaxStoredAnswers:
    var oldest = high(int32)
    for id in seat.answers.keys: oldest = min(oldest, id)
    seat.answers.del oldest

proc validKey(key: string): bool = key.len > 0 and key.len <= MaxKeyLength

proc bodyJson(draft: Draft): string =
  var state = newJObject()
  for key, value in draft.ints: state[key] = %value
  for key, value in draft.texts: state[key] = %value
  if draft.notes.len > 0: state["notes"] = %draft.notes
  var questions = newJObject()
  for key, q in draft.questions:
    var item = newJObject()
    item["type"] = %(case q.kind
      of noulQuestion: "noul"
      of scoreQuestion: "score"
      of choiceQuestion: "choice")
    item["instructions"] = %q.instructions
    if q.kind == scoreQuestion:
      item["criteria"] = %q.texts
    else:
      var criteria = newJObject()
      for i, label in q.labels: criteria[label] = %q.texts[i]
      item["criteria"] = criteria
    questions[key] = item
  $(%*{"state": state, "questions": questions})

proc addOracleFunctions*(host: var Host, slot: int, strings: StringPool) =
  ## Registers the oracle API for one seat. String arguments are pool handles.
  if not seatsReady:
    resetOracle()
    seatsReady = true
  template seat: untyped = seats[slot]
  discard host.addFunction("oracleAvailable", 0, proc(a: openArray[int32]): int32 =
    oracleEnabled.int32, 4)
  discard host.addFunction("oracleState", 2, proc(a: openArray[int32]): int32 =
    let key = strings.getString(a[0])
    if not validKey(key) or seat.draft.ints.len+seat.draft.texts.len >= MaxStateFields: return 0
    seat.draft.texts.del key; seat.draft.ints[key] = a[1]; 1, 8)
  discard host.addFunction("oracleStateText", 2, proc(a: openArray[int32]): int32 =
    let key = strings.getString(a[0])
    if not validKey(key) or seat.draft.ints.len+seat.draft.texts.len >= MaxStateFields: return 0
    seat.draft.ints.del key; seat.draft.texts[key] = strings.getString(a[1]); 1, 16)
  discard host.addFunction("oracleNote", 1, proc(a: openArray[int32]): int32 =
    if seat.draft.notes.len >= MaxNotes: return 0
    seat.draft.notes.add strings.getString(a[0]); 1, 16)
  discard host.addFunction("oracleQuestion", 3, proc(a: openArray[int32]): int32 =
    let key = strings.getString(a[0])
    if not validKey(key) or a[1] < 0 or a[1] > 2: return 0
    if key notin seat.draft.questions and seat.draft.questions.len >= MaxQuestions: return 0
    seat.draft.questions[key] = Question(kind: QuestionKind(a[1]),
        instructions: strings.getString(a[2])); 1, 16)
  discard host.addFunction("oracleCriterion", 3, proc(a: openArray[int32]): int32 =
    let key = strings.getString(a[0])
    if key notin seat.draft.questions: return 0
    if seat.draft.questions[key].texts.len >= MaxCriteria: return 0
    let label = strings.getString(a[1])
    if seat.draft.questions[key].kind != scoreQuestion and
        (label.len == 0 or label in seat.draft.questions[key].labels): return 0
    seat.draft.questions[key].labels.add label
    seat.draft.questions[key].texts.add strings.getString(a[2]); 1, 16)
  discard host.addFunction("oracleAsk", 0, proc(a: openArray[int32]): int32 =
    let draft = seat.draft
    seat.draft = newDraft()
    if not oracleEnabled or seat.inflight != 0 or draft.questions.len == 0: return 0
    if seat.asked and currentTick - seat.lastTick < oracleInterval.int32: return 0
    let body = draft.bodyJson()
    if body.len > MaxBodyBytes: return 0
    inc seat.nextId
    seat.inflight = seat.nextId; seat.asked = true; seat.lastTick = currentTick
    pendingAsks.add OracleAsk(slot: slot, id: seat.nextId, body: body)
    seat.nextId, 68)
  discard host.addFunction("oraclePoll", 1, proc(a: openArray[int32]): int32 =
    if a[0] != 0 and a[0] == seat.inflight: return OraclePending
    if a[0] notin seat.answers: return OracleFailed
    seat.answers[a[0]].status, 4)
  proc answerField(field: int): HostProc =
    result = proc(a: openArray[int32]): int32 =
      if a[0] notin seat.answers: return OracleMissing
      let key = strings.getString(a[1])
      if key notin seat.answers[a[0]].answers: return OracleMissing
      let answer = seat.answers[a[0]].answers[key]
      case field
      of 0: answer.value
      of 1: answer.confidence
      else: answer.probabilities.getOrDefault(strings.getString(a[2]), OracleMissing)
  discard host.addFunction("oracleAnswer", 2, answerField(0), 8)
  discard host.addFunction("oracleConfidence", 2, answerField(1), 8)
  discard host.addFunction("oracleProbability", 3, answerField(2), 8)
