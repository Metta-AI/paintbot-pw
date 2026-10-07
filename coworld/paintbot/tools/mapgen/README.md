# Paintbot map generator

`mapgen.py` builds seeded Paintbot maps in the engine's own units, using the rules-40 world
(`examples/paintbot/sim.nim`, `topography.nim`, `mechanics.nim`):

- **Terrain**: centimetre heights on a 50 cm grid over the rules-22 span `[-4800, 11200] x [-2800, 6800]`,
  plus an island-margin grid (a cog is off the island below `Radius div 3 + 40`). Water is height below
  `RiverWaterHeight` (-162, quarter speed). A wall is a rise of more than 25 cm per 20 cm, as in `traversable`.
- **Items**: the rules-40 set: 2 home and 8 neutral control hearts, 4 grenades, 2 sprays, 2 armors,
  4 medkits, 2 uniforms, and 6 trenches (280 x 280). All come in half-turn mirrored pairs, like rules 35.
- **Cover**: round cover (`h: 0`, `w` = diameter), tagged tree / house / prop / rock.

Where items go is decided by path distance from each home. `ratio = dA / (dA + dB)` measures how far
a spot is toward the enemy (wading counts 4x). Every item has to sit on flat, dry, inland ground that
both homes can reach, clear of cover.

| item | where |
|---|---|
| home hearts | the flattest dry spot near each end |
| centre / forward / flank / prize hearts | contested middle; a forward post; far flanks; high or remote ground |
| grenades | behind your own lines (ratio 0.1-0.34), near cover |
| spray | close quarters: the densest cover in midfield |
| armor | exposed high ground just short of the middle |
| medkits | one near the centre, one on a flank |
| uniform | midfield, in cover |
| trenches | open, flat ground on the approach, where there is no other cover |

```bash
python3 mapgen.py --out maps            # the ten catalogue maps (+ PNG previews, index.json)
python3 mapgen.py --out maps --only crater --seed 7
# Big maps: ten times the area, one control heart per ~730 m2 of land (the shipped maps' density)
python3 mapgen.py --out maps --scale 3.1623 --prefix big- --heart-area 730 --engine ../../../../examples/paintbot/maps
python3 -m unittest test_mapgen
```

**Training arenas (`train-*`, training library only).** `--layout-scale s` shrinks the archetype's layout
by `s` about the half-turn centre while the world keeps the standard bounds (the observation divides
distances by the map span, so the span must not change); everything off the shrunk island is sea, and
item / heart spacing shrinks with the layout. `--extra-weapons n` adds n mirrored grenade pairs and n spray
pairs (drawn after the rules-40 items, before the rules-49 ones; 20 + 4n pickups, keep it <= 32 so every
pickup has an observation row). `--name` renames a single `--only` map. The arenas are not compiled into
the engine: a training process loads them with `pw_register_map` (examples/paintbot/native_env.h) before
it creates any world, and the hosted game never sees them.

```bash
# train-arena-4 (1/4 area) and train-arena-9 (1/9 area): twin-mesas, seed 8, 16 seats, 28 pickups
python3 mapgen.py --out train --only twin-mesas --seed 8 --layout-scale 0.5 --extra-weapons 2 \
  --name train-arena-4 --engine ../../../../examples/paintbot/maps/train
python3 mapgen.py --out train --only twin-mesas --seed 8 --layout-scale 0.3333333333 --extra-weapons 2 \
  --name train-arena-9 --engine ../../../../examples/paintbot/maps/train
```

Map format: `paintbot-map/1` JSON. Heights and margins are base64 int16le, row-major (z, then x).
The engine does not load these maps yet; that needs a config-gated loader in `topography.nim`/`sim.nim`
and in `viewer.js`'s `islandMargin`.
