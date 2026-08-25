# Light vs Dark — a small RTS example

## Context

`gods_of_the_arena` proved PolyWorld's core contract with one BASIC VM driving
one hero. This example proves the same engine handles a different control
shape: **one overlord VM commanding a whole side**. It is a small RTS —
a town hall, peons on gold and wood, farms for supply, barracks for soldiers.

Two bot-authored `.bas` overlords fight a deterministic 1v1 that records to a
replay and verifies bit-exactly on playback, and can be watched and scrubbed in
a spectator viewer.

## What is different from the arena

| | gods_of_the_arena | light_vs_dark |
|---|---|---|
| Agents | one VM per hero, ten of them | one VM per player, two of them |
| Position | continuous `WorldPoint` | **a tile**; movement is a tick countdown |
| Collision | pairwise separation push | one unit per tile, no push at all |
| Visibility | none, every bot sees everything | per-team fog from sight radii |
| Observation | live index into world state | a snapshot taken once per decision |
| Commands | 2 | 7 |
| Files | one 2400-line `game.nim` | six modules, testable without GL |

## Files

```
lvd.nim       entry, branches on -d:headless
content.nim   enums, stat tables, tech, economy constants, contentHash
world.nim     integer map generation, symmetry, mapHash, validation
sim.nim       World, tick, movement, economy, combat, orders, stateHash
bots.nim      BASIC host surface, per-player VMs, observation snapshot
game.nim      command line, match setup, headless runner, replay wiring
graphics.nim  spectator viewer, fog rendering, HUD, replay transport
replays.nim   POLYLVD action schema and playback cursor
players/base.bas   reference overlord
```

Dependency order is strict and acyclic: `content → replays → world → sim →
bots → game → graphics`. Nothing below `game` knows the command line exists,
which is what lets `tests/test_lvd_*.nim` drive the whole simulation with no
window and no GL context.

## The integer rule

**No float ever enters `World`.** A unit's authoritative position is a tile;
movement is `stepTicks` counting down; health, timers, and resources are
`int32`. Map generation is integer too — layered value noise on a seeded
lattice, the same approach the arena uses, not `noisy`'s float simplex.

The renderer interpolates between `fromTile` and `tile` by how much of the step
remains and samples `surfaceHeight` for the vertical. `surfaceHeight` is called
in exactly one place, and its result never flows back. `sim.nim` must not
import anything that returns a float.

`polyworld/fixed` is available and deliberately unused: with tile positions and
tick timers there is nothing that needs a fractional part.

## Movement and the one-unit-per-tile rule

A unit owns exactly one tile at all times — the tile it is moving *into*.
`occupancy` is therefore the reservation itself, with no second array to leak.
While `stepTicks > 0` the unit is in transit and does nothing else.

Strict one-unit-per-tile plus four-tile-wide fords is the classic gridlock
scenario, so blocked units escalate on fixed thresholds:

| ticks blocked | action |
|---|---|
| 12 | **shove** an idle friendly bystander out of the doorway |
| 24 | **swap** atomically with a friendly unit walking straight at us |
| 90 | **re-path**, then hold a cooldown |
| 300 | **abandon**, set `orderFailed`, let the overlord re-decide |

`tests/test_lvd_sim.nim` pushes forty units both ways through the middle ford
and requires all forty to arrive with none still grinding.

## Pathing

A local integer A* over the world's own grids, not `pathing.findPathPoints`.
The shared one is deterministic, but it answers questions about
`layerWalkable`, which is computed once at startup and cannot see structures
raised during a match; it is also four-neighbour where movement here is eight.

`computeWalkable()` runs exactly once, at map generation. It reallocates seven
full-grid sequences and wipes the edge cache, so calling it per building would
be ruinous.

**The plan called for flow fields and they turned out not to be needed.**
Measurement showed the cost was blocked units re-pathing, not harvest traffic:
every search was hitting the 3000-expansion cap because the fords funnel A*
into a wide fan. Raising the re-path thresholds took a 130-unit late-game load
from 22× to 43× real time. Raising the expansion cap instead made it *worse*
(5×). Partial paths plus greedy stepping still get armies across the map —
20/20 units cross the river in the regression test.

## Fog of war

Per player: a `visibleStamp` grid compared against a generation counter, plus a
sticky `explored` grid. Generation stamping needs no clear pass and cannot
overflow the way reference counts do when two hundred units stack on a base.

Vision is rebuilt **whole** every six ticks rather than updated incrementally.
Incremental vision needs a matching decrement for every increment across
movement, death, spawning, and construction, and one missed case is a silent
permanent leak. A full rebuild is about six microseconds per tick amortised.

`VisionTicks` divides `DecisionTicks` and vision runs first, so no overlord
ever sees stale ground.

**Fog hides what the enemy is doing, not what the map is.** Neutral gold mines
and trees are always observable; enemy units and structures are not. Making a
player scout for its own forest would be tedious rather than interesting.

## The overlord surface

One VM per player. The `playerId` captured in the host closures is the entire
authorisation boundary: every command takes an entity id and is refused unless
that entity belongs to the caller.

Observations come from a snapshot built once per decision, in a canonical
order, rather than from live state. That keeps indices stable while a script
issues commands that kill things, and it is the single place fog is applied.

Two things about this BASIC that shaped the API:

- **`and`, `or` and `not` are logical, not bitwise.** `16 and 1` is `1`. A
  script cannot test a bit, so conditions are separate calls (`obsIdle`,
  `obsCarrying`, …) instead of one packed flags word. The first version used a
  bitfield and every peon read as idle.
- **Host functions take and return scalars only.** Arrays cannot cross the
  boundary, so each observation field needs its own accessor.

Static tables are exposed as calls (`unitCostGold`, `canBuild`, …) rather than
documented constants, so retuning is one edit to `content.nim` and existing
scripts keep working — with `contentHash` making a stale replay fail by name.

The budget (300k instructions, 400k work per decision) is deliberately
reachable: a naive scan of every unit against every other exceeds it and fails
the script. That is the pressure pushing authors onto `nearestEnemy`.

## Determinism

`stateHash` is FNV-1a over a canonical walk of everything that can influence a
later tick, computed every tick and stored in the replay. Every `World` field
carries a `# HASH: include` or `# HASH: derived` comment.

Included but non-obvious: `path` and `pathQueue`, because the pathing service
*is* simulation state and a re-path firing one tick early must show up
immediately; `animation` and `animationTicks`, because a divergence there means
the viewer and the headless build disagree visually even when play matches.

**This caught a real bug on its first run.** A replay reproduced an *identical
final state* — same resources, units, buildings, winner — while diverging at
tick 24192. `applyMove` and `applyHarvest` were mutating the world and then
returning `false`, so those commands were never recorded. Every validator now
follows one rule: **decide and record before touching anything.**

## Known rough edges

- **The 3D ground shroud is not implemented.** Fog is applied to entities and
  to the minimap, and the HUD toggle switches between omniscient, Light, and
  Dark views. Darkening the terrain itself needs a dedicated blended pass, in
  the manner of the arena's selection-outline program.
- **`nearestTree` and `nearestMine` break exact ties by lowest tile index**,
  which is not mirror-symmetric: for Light that points toward the map corner
  and for Dark toward the centre. It only bites on exact ties, but it is a real
  reason two identical scripts do not produce mirrored matches.
- **`base.bas` is a reference, not a good player.** It opens sensibly and
  fights, but it does not scout, expand to a second mine, or build past a
  barracks, and it frequently strands itself on wood.

## Commands

```bash
nim c -d:release -d:headless -o:lvd examples/light_vs_dark/lvd.nim
```

```bash
./lvd --bot examples/light_vs_dark/players/base.bas:2 --seconds 600 --record examples/light_vs_dark/replays/demo.replay
```

```bash
./lvd --replay examples/light_vs_dark/replays/demo.replay
```

```bash
nim c -d:release -o:lvdview examples/light_vs_dark/lvd.nim
```

```bash
SIM_SECONDS=200 CAM_DIST=42 CAM_X=22 CAM_Z=22 VIEW_MODE=1 SCREENSHOT_PATH=/tmp/base.png nim r -d:takeScreenshot examples/light_vs_dark/lvd.nim -- --bot examples/light_vs_dark/players/base.bas:2
```

Tests, none of which need a window:

```bash
nim r tests/test_lvd_content.nim
```

```bash
nim r tests/test_lvd_world.nim
```

```bash
nim r tests/test_lvd_replays.nim
```

```bash
nim r tests/test_lvd_sim.nim
```

Compile with `-d:lvdTrace` to narrate one peon's economy decisions when
something inexplicable is happening.
