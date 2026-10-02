# Paintbot tournaments

Build with Nim and use an existing `softmax login`:

```
nim r --nimcache:tmp/build-cache examples/paintbot/tools/build_tournament.nim
tmp/paintbot/tools/tournament --run top10-100-20260930 --games 100 --seed 20260930
```

The runner requires Nim's `jsony` and `yaml` packages and uses synchronous TLS
HTTP requests. It runs on macOS and Linux, where atomic saves use `fsync`.

The runner freezes the current Competition division's top ten active champion
policies, excluding league fillers, and the canonical Paintbot release's
Competition configuration. It submits direct Experience Requests. It does not
edit league rules, releases, memberships, or ratings.

The total budget is split between mixed and mono teams, with an odd extra game
assigned to mixed. Both use the native sixteen-cog, interleaved 8v8 setup:

- Mixed: five distinct policies per side and three balanced duplicate cog slots
  on each side. A policy never plays against itself. Teams, duplicates, and
  positions are shuffled using the saved seed.
- Mono: one policy fills all eight slots on each side. Opponents and sides are
  balanced across games.

Each policy counts once per game, averaging its slots first. Win rate uses the
explicit winning team, even if it wins at the time limit or earns a zero score.
The second ladder uses Paintbot's native match score, including losses and draws as zero.
No extra XP or elapsed-time adjustment is applied. Equal averages are marked as
ties and ordered consistently by the frozen policy-version ID. Stability counts
policies whose displayed rank changed every ten games within each format; the
first checkpoint is a baseline. Stability never ends a run early.

Output lives under the sibling `polyworld/tmp/paintbot/tournaments/<run>/`:

- `run.json`: frozen roster, release, configuration, and ordered schedule.
- `games/*.json`: submission intents, attempts, remote IDs, and original results.
- `summary.json`, `report.html`, `exports/*.csv`: derived results.

Ctrl+C pauses after saving the current response. Repeat `--run NAME` to reconcile
submitted requests and resume. Completed games are never replayed. Files are
flushed and atomically replaced, and abandoned `.tmp` files are ignored. Assume
one runner per directory. `--retry-failed` adds attempts for failed games only.
An interrupted submission without a saved receipt is searched for by its unique
request note. If no receipt is visible, the runner pauses instead of risking a
duplicate; investigate the saved request before retrying manually.

Use `--report-only` to regenerate results without network access. Frozen options
cannot change on resume; operational options such as `--concurrency` can.
Defaults are `--top 10 --format both --check-every 10 --concurrency 4`.
Use `--help` for the full interface.

Reports embed Rubik fonts and original game icons from `POLYWORLD_ART` (defaults
to the sibling `polyworld_art`), plus the included Paint Crew image. They work
offline and refresh manually. If the sibling `polyworld-buff` checkout exists,
each update also writes `Paintbot/standings/index.html` and a dated run HTML
archive, copies assets to `Paintbot/assets/`, and links standings from its guide.
`--site PATH` selects a checkout; `--no-site` disables this. Publication to GitHub
Pages requires committing and pushing the generated site files.

Run checks and focused fault-recovery tests:

```
nim check examples/paintbot/tools/tournament.nim
nim check examples/paintbot/tools/test_tournament.nim
nim r --nimcache:tmp/test-cache examples/paintbot/tools/test_tournament.nim
```
