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

Cobbles are discrete objects, not a blended material. `ground.nim` builds
two things at startup, on the CPU, from nothing but the seed and the map:

- A tiling cobble sheet of square-ish cells. Every stone carries one fixed
  height in the sheet's height channel, mortar carries zero. Colours sit
  near the square-stone swatch in the enchanted meadow atlas.
- A ground mask at eight texels per tile with two channels. Stone coverage
  is full inside the plaza, stepping off underneath the curb, and runs down
  the middle of every road: a distance field from the road tiles' centre
  lines, blurred so the corners of the tile doglegs round off, then
  thresholded with a band. Dirt coverage comes from a distance transform
  of every road and plaza tile. Both carry a little low-frequency wobble
  so no edge is a ruler line. Gardens and house
  pads are left to the ordinary tile materials.

A curb of larger cut stones rings the plaza. It is a second, cleaner
sheet sampled in polar coordinates around the plaza centre, one stone row
across the band and sixty-four stones around, so the stones follow the
circle and the sheet seam lands on a mortar line. It drops out past its
outer edge like the cobbles do.

The terrain shader keeps a stone only where coverage still beats the
stone's height, so wherever coverage tapers the rim is ragged whole stones
with dirt between them: road cobbles fray into the dirt at their sides,
while on the plaza the curb is the hard edge and the cobbles run straight
up to it. Dirt then height-blends into grass. Roads ride the same dirt field, so
they get rounded edges and join the plaza apron without a seam. Road and
plaza tiles bake as grass underneath; the mask owns every stone and dirt
texel. Roads wear the meadow pack dirt. In the viewer, `D` cycles the dirt
layer through meadow dirt, cartoon dirt, the golden valley forest floor,
and the engine's sand, printing the choice to the terminal. The two toon textures load at startup
into the unused marsh and volcanic slots.

## Decorations

`decor.nim` dresses the village from the map and seed alone, so a replay
dresses exactly like the live game, and nothing it places has any bearing
on the simulation. Everything comes from the two toon kits and is baked
into the terrain mesh once with the houses.

- Plaza: the golden valley well at the centre; between each pair of road
  entrances one of a market stand with a canopy and crates, a bench and
  table, a lamp post, a cart with barrels, or sacks and a crate; lamp posts
  beside every third entrance and a signpost beside the next.
- Houses: a mailbox beside the door, flower pots flanking it, a run of
  fence along the back, three flower beds and a bush in the yard.
- Gardens: a fence piece on one side of every plot, flowers beside some.
- Road verges: tufts, bushes, small rocks, and flowers on one grass tile
  in seven along the roads.
- Outskirts: boulders in the meadow before the forest wall.

Every height and probability is a const at the top of `decor.nim`. The
loader keeps only the named nodes from each kit.

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
