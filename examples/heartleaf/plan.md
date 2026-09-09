# Heartleaf — a village dinner-party week

## Context

The first three examples are about fighting: an arena, an RTS, a dungeon
crawl. Heartleaf proves the same engine handles a *social* game: nine BASIC
villagers on one procedurally generated village map, where the only thing
that scores points is throwing and attending dinner parties. The design is
borrowed from the 2D game of the same name; the code is not.

## The game

A game is a week. Days run 9:00 to 21:00 on an accelerated clock (one real
second is four game minutes, a day is three real minutes). Every morning
each of the 27 garden plots grows one of 24 vegetables; gathering a plot
takes everything it holds and the plot stays bare until tomorrow.

At exactly 18:00 every house holds its dinner tally at once. A party is
valid when the owner is inside their own house with at least one visitor:

- The host banks **items carried × visitor count**, then the pantry feeds
  host and visitors alike for three bite rounds — one bite per diner per
  round, in one seating order shuffled by the world rng.
- A bite of a vegetable the diner has **never tasted this week is worth 3**;
  a repeat is worth 1. Each bite chooses uniformly among untasted types,
  or among remaining individual items when all available types were tasted.
  The simulation RNG makes both choices reproducible.
- Hosting **empties the pantry**. Guests eat for free.
- Anyone alone, or outdoors, scores nothing that night.

At 21:00, every villager outside their own house loses three points,
including visitors inside another house. Scores can go negative. Everyone
is then sent home for the score screen; the next morning starts at their
own doorstep.

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

## Demo camera

The spectator starts at a fixed distance of 40, following the outdoor
villager nearest the town centre. It stays with that villager through
gathering, walking, and conversation, framing their house while indoors.
Each shot lasts at least 60 real seconds. Three seconds
idle or indoors allow a handoff after that minimum; at 90 seconds, any
activity permits a handoff. The next outdoor villager is the least recently
followed, with distance and slot breaking ties. With nobody else outdoors,
the camera stays put. Focus changes snap immediately to the next subject.

The camera tracks the same interpolated position used to draw the gnome,
centred at body height, without additional camera damping or a speed cap.
Zooming adjusts the distance without leaving demo following or restarting
the shot. Shot timing uses real seconds at every playback speed. Pausing freezes automatic tracking and shot timers. Seeking snaps
to the selected subject at the restored position. Pan, minimap input,
and clicking a villager take manual control; C or the camera button resume
the demo by snapping to a selected or nearby outdoor villager, preserving
zoom. Clicking any speed button, including the already selected speed,
recentres the manual or last demo subject without changing camera ownership
or restarting the shot. Manual villager following also tracks body position
without lag. The human-player action camera remains unchanged.

## The map

`maps.nim` generates the village with integers from one seed: a gentle
meadow pressed flat inside the village ring, nine houses on a jittered
ring of unit-circle points around a round paved plaza with a one-tile
dirt apron and a blocked three-by-three well footprint at its centre,
five-by-five house footprints, two-wide dirt roads from every door to the plaza plus a
one-wide neighborhood links, three garden plots in the grass near each house, and
a noise-gated forest thickening to a solid wall at the map edge. A flood fill from the plaza must reach every door and
every garden or the generator retries the seed deterministically.

Neighborhood links use a deterministic cardinal route search within four
tiles of the rectangle between neighboring doors. Existing streets cost less
than fresh paving, and new paving close to a street costs extra. This favors
shared streets over narrow parallel routes while keeping links local rather
than sending every neighbor trip through the plaza. The wide plaza spokes
use doglegs; doors within four tiles of a central axis join that street
before the long leg so they do not create a parallel approach to the plaza.

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

`players/base.bas` chooses the nearest crop it can plausibly win. Another
outdoor villager counts as a competitor only while gathering that same plot;
a lead of at least three grid tiles makes the race a clear loss. Ties and
smaller leads remain competitive. Active gatherers reconsider clear losses
every two seconds, keeping their target otherwise. Walking villagers also
check for newly winnable crops, without inventory caps or harvesting breaks.
These are grid-distance estimates, not exact path travel times.

When no crop looks winnable, the bot looks for nearby company. A conversation
is an explicit, replayed `talk` action: the caller stops and greets a neighbor,
who can choose to answer. Participants face their conversation partner and
show the greeting indicator while talking. An unanswered offer ends after
two seconds. Conversations do not create dinner invitations or change scores.

A conversation can include up to four connected participants, including
joining existing pairs or trios. Each bot leaves after its own twelve to
twenty-four-second stay and waits ten to twenty seconds before socializing
again. It avoids immediately seeking the same partner. Harvesting a winnable
crop, dinner, and curfew override socializing.

Social approaches seek available neighbors within fourteen tiles and stop
if the target becomes busy, departs, or the group fills. Longer walks have
a social destination; otherwise free-time walks remain short and within
eight tiles of the local area, with five-to-ten-second rests and no immediate
backtracking. Groups of four are allowed; larger nearby crowds encourage
moving on. No generated dialogue or LLM calls are involved.

Three villagers are due to host each night by rotation
(`(day + slot) mod 3 == 0`); hosts wave invitations at anyone passing
within three tiles; guests walk to the nearest due host; everyone budgets
about two game minutes per tile plus a half-hour margin and never stands
outside at six. After dinner they collect leftovers, then return to their
own house before curfew using the same travel margin and a 20:00 latest
departure. Once heading home, they stay committed until the next morning.
House approaches are retried after two seconds without meaningful tile
progress, allowing recovery from a stuck approach.

## Determinism notes

- `orderFailed` is hashed **out**: it is an agent mailbox that bots read
  and clear, so a live game and its replay legitimately differ there while
  the simulation itself stays bit-exact. This showed up as 41k hash
  mismatches on the very first record/replay run.
- Dinner seating and bite selection use the deterministic world RNG.
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
  so no edge is a ruler line. House pads join that mask as rounded squares:
  solid cobble beneath each building, then ragged whole-stone dropout over
  dirt into grass, merging directly into the doorway road. Gardens do not
  add soil to the ground mask.

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
texel. Roads wear the meadow pack dirt, loaded at startup into the unused
marsh slot.

## Houses

Neither toon kit ships a whole cottage, so `houses.nim` builds them from
the golden valley parts. A cottage first chooses one coherent style:
thatch on one brick course, blue shingles on a timber sill, or the framed
roof on the other brick course. Foundations never mix materials within a
house. Their front runs leave an opening for the kit's complete framed-door
wall module; plain and windowed panels fill the remaining walls, with each
side and corner turned so its finished face points outside. The roof eaves
overlap only the top of the three-metre walls. Length, window placement,
paint drift, and compatible roof furniture provide the variation.

One house in three is a longhouse: three coherent courses of meadow stone
with a grounded door in their opening, under four joined segments of straw
thatch tinted to turf with grass along the ridge and slopes.
Every recipe is checked over a magenta ground for holes. The village
pack houses are gone and the blocked footprint is five tiles square,
which a ten metre house fills. The house lab,
`nim r experiments/houses/houses.nim`, shows a grid of houses from
consecutive seeds with `R` to reroll, `K` to switch kinds, and `P` for a
magenta ground that shows any hole in a house.

## Crops

Every plot has a permanent Meadow flower pot, varying among three shapes.
A stocked pot grows one toon kit plant, drawn textured per frame above the
soil opening so it can appear and vanish as villagers gather. Harvested pots
remain visible on the surrounding grass; plots add no dark terrain tint or
dirt mask. Neither kit has a literal lettuce or corn, so the
twenty-four kinds share plants by silhouette, grassy stalks, root tops, a
bush, seedling leaves, broad leaves, and a wheat clump, and a tint per
kind tells them apart. The old village-pack farm building is gone.

## Decorations

`decor.nim` dresses the village from the map and seed alone, so a replay
dresses exactly like the live game, and nothing it places has any bearing
on the simulation. Everything comes from the two toon kits and is baked
into the terrain mesh once with the houses.

- Plaza: the golden valley well at the centre; between each pair of road
  entrances one of a market stand with a canopy and crates, a bench and
  table, a bench with pots, a cart with barrels, or sacks and a crate; a
  signpost, a fence pole with the sign board hung on it, beside every
  third entrance.
- Houses: a mailbox beside the door, flower pots flanking it, five
  flower beds and two bushes in the yard.
- Gardens: permanent pots at every plot, with flowers beside some plots.
- Road verges: lamp posts spaced along the roads, and tufts, bushes,
  small rocks, and flowers on every other grass tile. Everything that
  grew or was left lying varies in size; everything gnomes made does not.
- Meadow: each eight-by-eight tile area gets up to three low plants,
  spreading bushes, flowers, and tufts between the town roads as well as
  outside the houses. Only the actual plaza and local road, crop, and
  doorway clearances are excluded. At most 243 low plants and five medium
  rocks cover the meadow, with up to six trees spaced twelve tiles
  apart and set back from roads. Alternating sectors have small trees
  (2.4 tiles tall) and medium trees (4.2 tiles tall), at most three of each.
- Outskirts: small rocks at the feet of the forest trees and the odd
  medium one.
- Forest floor: low bushes and grass tufts bridge the outer meadow and
  forest clearings. Three bands each sample four locations per side,
  adding at most 96 props between radii 36 and 58.

Every height and probability is a const at the top of `decor.nim`. The
loader keeps only the named nodes from each kit and draws them textured,
through the same cutout path as the trees, because the toon kits are
painted rather than palette coloured and a per-vertex colour bake turns
their detail to blotches and their foliage cards to gradients.

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
