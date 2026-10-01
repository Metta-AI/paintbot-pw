Porting Paintbot BASIC to Bassy

Paintbot now uses Bassy's compiler, JIT, and record accessors. Update policy
source for the new numeric semantics and observation records. The shipped
`examples/paintbot/players/base.bas` shows the complete conversion.

Use the host-provided `me` record for your seat and `agents(i)` for another
seat's observations. Paintbot declares these records before your source, so
policies should not redeclare them. Agent fields follow SeatView's visibility
and disguise rules.

| Previous expression | Record accessor |
| --- | --- |
| `selfId`, `selfTeam` | `me.id`, `me.team` |
| `selfX`, `selfY`, `selfHp` | `me.x`, `me.y`, `me.hp` |
| `worldTick` | `me.tick` |
| `carrying`, `hasGrenade` | `me.carrying`, `me.hasGrenade` |
| `homeX`, `homeY` | `me.homeX`, `me.homeY` |
| `visible(i)` | `agents(i).visible` |
| `playerX(i)`, `playerY(i)` | `agents(i).x`, `agents(i).y` |
| `playerHp(i)`, `playerTeam(i)` | `agents(i).hp`, `agents(i).team` |
| `playerCarrying(i)` | `agents(i).carrying` |

For example, an observation loop can use the fields directly:

```basic
i = 0
while i < 16
  if i <> me.id and agents(i).visible then
    dx = agents(i).x - me.x
    dy = agents(i).y - me.y
    distanceSquared = dx * dx + dy * dy
  end if
  i = i + 1
wend
```

Replace parallel arrays for persistent memory with typed record arrays:

```basic
TYPE MotionMemory
  x AS INTEGER
  y AS INTEGER
  seen AS INTEGER
END TYPE
DIM motion(16) AS MotionMemory

i = me.id
motion(i).x = agents(i).x
motion(i).y = agents(i).y
motion(i).seen = me.tick
```

Record memory persists between decisions. Observation fields refresh each
active decision. Writing an observation field changes only the policy's local
copy; actions still use `walkTo`, `lookAt`, `shootAt`, and `chargeGrenade`.
`DIM motion(16)` retains the inclusive upper bound of the old BASIC arrays.

Review arithmetic as part of the port. `/` now performs fixed-point division,
so `3 / 2` is 1.5. Use `\` for integer division, as in `3 \ 2`, which is 1.
Coordinates and indices passed to host functions must be exact integers.
Comparisons and `TRUE` produce -1; `FALSE` produces 0. `AND`, `OR`, and `NOT`
operate on bits. For numeric host flags, replace a test such as `NOT carrying`
with `me.carrying = 0`. Normalize general numeric conditions with comparisons
before combining them, and review arithmetic that used comparisons as 0/1
counters. Avoid replacing operators inside strings or comments.

The host integration uses Bassy's bound accessors in
`examples/paintbot/observations.nim`. Scalar record fields bind with
`runtime.globalView("me.x")`; the resulting `GlobalView.value` reads or writes
a `Value` without resolving the name each tick. Set an integer with
`view.value = toValue(x)`. A numeric record-array field binds as a flat column:
`runtime.arrayView("agents.x", writable = true)` returns an `ArrayView` whose
`view[i]` accesses `agents(i).x`, with the declaration's type coercion.

Paintbot registers `setArrayLoader("agents.x", loader)` for each roster field.
The loader receives a writable `ArrayView` and fills it through SeatView on
first access. `invalidateArrays()` makes those columns refresh on their next
access in a new decision. Bind loaders before `compileNative()`, because
changing a loader invalidates previously compiled machine code. Only referenced
scalar observations are refreshed, and each loaded roster column costs four
work units per seat. JIT and interpreter paths use the same record storage and
budgets.

Use `python3 tools/bench_paintbot_bassy.py --runs 6 --ticks 1200` to compare the
old public baseline with the ported baseline and Jev policy. The runner builds
both runtimes against the same local dependencies and alternates timed runs.
The recorded results and startup cost are in `docs/bassy-benchmarks.md`.
