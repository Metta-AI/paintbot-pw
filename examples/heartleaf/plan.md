# Heartleaf — a village dinner-party week

## Context

The first three examples are about fighting: an arena, an RTS, a dungeon
crawl. Heartleaf proves the same engine handles a *social* game: nine BASIC
villagers on one procedurally generated village map, where the only thing
that scores points is throwing and attending dinner parties. The design is
borrowed from the 2D game of the same name; the code is not.

## The game

A game is a week. Days run 9:00 to 21:00 on an accelerated clock (one real
second is three game minutes, a day is four real minutes). Every morning
each of the 27 garden plots grows one of 24 vegetables; gathering a plot
takes everything it holds and the plot stays bare until tomorrow.

At exactly 18:00 every house holds its dinner tally at once. A party is
valid when the owner is inside their own house with at least one visitor:

- The host banks **items carried × visitor count**, then the pantry feeds
  host and visitors alike for three bite rounds — one bite per diner per
  round, in one seating order shuffled by the world rng.
- A bite of a vegetable the diner has **never tasted this week is worth 3**;
  a repeat is worth 1. The draw itself is deterministic: the best-stocked
  untasted kind, then the best-stocked kind, ties to the lowest index.
- Hosting **empties the pantry**. Guests eat for free.
- Anyone alone, or outdoors, scores nothing that night.

Inventories persist across days and are cleared only by hosting; the tasted
list persists all week. Highest cumulative score after the last score
screen wins.

Invitations are a real simulation verb here (the 2D original left them to
chat): `invite` within three tiles declares the caller a host tonight and
registers the invitation; `accept` remembers a host. But nothing *binds*
anyone — attendance is purely who is physically inside which house when the
bell rings, which is the interesting part of the original design.

Houses have no interiors. Entering removes the villager's body from the
map — occupants show as portrait icons floating over the roof — and exiting
puts it back on the doorstep.

## The map

`maps.nim` generates the village with integers from one seed: a gentle
meadow pressed flat inside the village ring, nine houses on a jittered
ring of unit-circle points around a round paved plaza with a one-tile
dirt apron, two-wide dirt roads from every door to the plaza plus a
one-wide ring path, three garden plots in the grass near each house, and
a noise-gated forest thickening to a solid wall at the map edge. A flood fill from the plaza must reach every door and
every garden or the generator retries the seed deterministically.

## What is different from the other examples

| | the war games | heartleaf |
|---|---|---|
| Agents | 2–10 VMs | nine VMs, one villager each |
| Conflict | damage | garden races and party attendance |
| Map | mirrored / dungeon | one ring village, no symmetry needed |
| Walkability | changes (build, fell) | fixed at generation, forever |
| Clock | cosmetic | the mechanic: 18:00 is everything |

Because nothing ever changes walkability, the whole class of
rebake/desync problems the RTS fights simply does not exist: terrain and
props bake exactly once.

## The scripted villager

`players/base.bas` plays the known-strong plan from the original game:
gather all day; three villagers are due to host each night by rotation
(`(day + slot) mod 3 == 0`); hosts wave invitations at anyone passing
within three tiles; guests walk to the nearest due host; everyone budgets
about two game minutes per tile plus a half-hour margin and never stands
outside at six.

## Determinism notes

- `orderFailed` is hashed **out**: it is an agent mailbox that bots read
  and clear, so a live game and its replay legitimately differ there while
  the simulation itself stays bit-exact. This showed up as 41k hash
  mismatches on the very first record/replay run.
- The dinner shuffle is the only rng the tally consumes; the bite draw is
  deterministic so the divergence surface stays small.
- The 17:59 door crush is real: nine bodies shove on one doorstep, so
  `enterHouse` accepts from a king-move of one around the door tile and
  `tests/test_hlf_sim.nim` sends all nine through one door.

## Plaza paving

The plaza's stone material is not a shipped texture. `graphics.nim` crops
the square-stone swatch out of the enchanted meadow atlas at startup, tiles
it into a sheet, derives a height map from its luminance, and swaps it in
over the engine's flagstone layer. Roads use the cartoon pack's dirt. In
the viewer, `D` flips roads between dirt and the engine's sand and rebakes
the terrain, so the two can be compared live.

## Commands

```bash
nim r examples/heartleaf/heartleaf.nim --bot examples/heartleaf/players/base.bas:9
```

```bash
nim r -d:headless examples/heartleaf/heartleaf.nim --seed 1988 --bot examples/heartleaf/players/base.bas:9 --record examples/heartleaf/replays/demo.replay
```

```bash
nim r examples/heartleaf/heartleaf.nim --replay examples/heartleaf/replays/demo.replay
```

```bash
SIM_SECONDS=177 CAM_DIST=55 CAM_X=64 CAM_Z=64 SCREENSHOT_PATH=/tmp/heartleaf.png nim r -d:takeScreenshot examples/heartleaf/heartleaf.nim -- --bot examples/heartleaf/players/base.bas:9
```

Tests, none of which need a window:

```bash
nim r tests/test_hlf_content.nim
```

```bash
nim r tests/test_hlf_maps.nim
```

```bash
nim r tests/test_hlf_replays.nim
```

```bash
nim r tests/test_hlf_sim.nim
```
