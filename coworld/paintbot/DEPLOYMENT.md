# Hosted deployment

Uploaded `paintbot-pw:0.1.0` as `cow_0c533f82-e6bf-4298-8810-9ee1ccfe76c6`.

Both file formats uploaded successfully:

| Policy | Version ID |
| --- | --- |
| paintbot-pw-basic:v1 | 947bc78f-622d-405e-9bc9-4bf9627c7b67 |
| paintbot-pw-wasm:v1 | 3d27fe95-be94-4aab-bdc0-899ad2f27994 |

To upload your own file:

```sh
coworld upload-policy --file my-policy.bas --name my-paintbot-basic
coworld upload-policy --file my-policy.wasm --name my-paintbot-wasm
```

## Live campaign league

[Open paintbot-pw](https://softmax.com/observatory/v2?detail=league:league_b9458ff8-0854-4e21-82b8-3c99942902e0).

- Public league with a 10 by 10 hex campaign map, using the retained Paintbot campaign rules.
- BASIC and WASM seed opponents, plus Daveey's existing Focusfire WASM, are active champions.
- Real episode outcomes, 1v1 and 2v2 cells, three invasions and one airdrop per round.
- Five scheduled rounds per day and a $15 daily budget while the field is small.
- The full live configuration is recorded in `campaign.json`.

Submit either file after upload:

```sh
coworld submit my-paintbot-basic --league league_b9458ff8-0854-4e21-82b8-3c99942902e0
coworld submit my-paintbot-wasm --league league_b9458ff8-0854-4e21-82b8-3c99942902e0
```

## Certification

Hosted certification passed all ten steps under contract `main-f49e1bed7407`, job `5871f58e-eb78-44c0-8174-98ee2d3e6207`.

Earlier runs failed because the platform's completion record omitted an uploaded replay URL. During the successful run, the hosted replay was downloaded and all 240 ticks verified (hash `3045561490`); all sixteen seats exited cleanly. The normal lifecycle API attached those actual artifacts before certification continued. No certification checks were bypassed.

The platform's results-only reconciliation path remains a separate infrastructure issue; this game does not alter that shared backend.


## Painted viewer release: 0.1.1

Published as `cow_e43f6f7b-315d-456a-a6b7-16e15bb087d4`, now canonical for the existing Paintbot PW game and campaign league. The campaign configuration and active players are preserved.

Hosted certification `33c0c432-4847-46be-9e42-8d7acf8b5bfd` passed all ten checks under contract `main-195cc9d7ba28`. All six hosted upload-smoke episodes produced valid 240-tick replays with sixteen clean seats. Actual uploaded artifacts were verified and registered through the lifecycle API while the shared completion reconciliation issue remains outstanding.

The published viewer bundle is `sha256:3a9e05d28371ff786e2a536e892759b65a65b870bc7cbd54d65c8b3d412e0fc8`. A real hosted episode, `2aea773a-2de8-4f47-8ddc-34e4b42b1a31`, was used to open the static viewer through the production replay-session API.

See `VIEWER.md` for the CTF feature map, keyboard controls, pinned artwork, and v1/v2 replay compatibility. Existing episodes keep their original viewer; new episodes use 0.1.1.

### Final layout follow-up: 0.1.2

`cow_14b61d5e-ae26-4171-b93e-c5c6d8738bab` is now canonical. This follows 0.1.1 with bounded selector width for real hosted player names and unclipped portrait health pips. Hosted certification `b81745e4-8d37-4f57-a593-c0d1e413a65d` passed all ten checks under `main-195cc9d7ba28`. The production replay-session API serves the final static bundle for hosted episode `b2b0572c-c681-4376-bc4e-3e5c93a1d9ce`.

### Solid-body rules release: 0.1.3

`cow_305225aa-9917-4453-8f3f-4acb865a1530` is certified and canonical for the existing ladder. Certification `ac620e9e-eb63-47e6-8b3c-3b55ca64184a` completed under `main-ddac040c18fb` on 2026-09-10. The published v3 replay viewer was verified against hosted episode `eaff93c7-ce7b-4719-8f80-d5eb5ccbf6c9`. Living cogs now collide and weapons fire once per second. Existing episodes preserve their original physics; newly scheduled episodes use 0.1.3.

### Paint Crew and equipment: 0.1.6

`cow_67b21f5a-2540-4330-b84d-331af4fe81b3` is certified and canonical for the existing ladder. Certification `7c614b81-88f6-48c7-8306-343a796f61de` passed all 10 checks under `main-ddac040c18fb` at 2026-09-10T17:53:18.228993Z. The production viewer loaded hosted replay `91fc37cc-545c-49ec-8cc2-1e75891db89f` and displayed HASH VERIFIED. All sixteen hosted seats exited cleanly and the native verifier reproduced each downloaded replay.

The release includes the approved B Paint Crew cogs, grenades, spray cans, trenches, shields, med kits, finite lives and capture/wipe victories. BASIC and WASM policies remain supported. Ladder mode remains enabled, campaign disabled, and a new ladder run was triggered after canonical publication. Historical episodes retain their pinned viewers and rules.

### Gnomewick Village: 0.1.7

`cow_756c3045-584b-46ed-b122-0dea7af31e61` is certified and canonical. Certification `2cc2d149-42f0-4cef-9577-a8047b9559f7` passed all ten checks under `main-3ea7eef64761` at 2026-09-10T18:02:28.059203Z. Hosted replay `88ae803e-f57d-4da5-a4aa-63a5ed8bbe32` loaded through the production replay-session API with Gnomewick Village and HASH VERIFIED. All sixteen hosted policy seats exited cleanly. The existing ladder configuration was verified and a new run triggered after publication.

### Raised vegetable beds: 0.1.8

`cow_1e2c39f7-5653-4f36-b984-67d057ecb744` is certified and canonical; all ten checks passed in `d87b560b-89c3-43a9-bcad-4665c306cb49`. Timber beds with carrots and tomatoes replace the garden-wall visuals using identical collision footprints. The production viewer loaded hosted replay `4c0261b5-99df-4aeb-805e-db8bfaebe0a7` with HASH VERIFIED, and a ladder run was triggered.

## Heartwick territory release — 2026-09-10

Published **0.2.0**, Coworld `cow_8f19610c-fd09-4051-b30f-4007c6520550`,
manifest `sha256:91851596d1359b7474b6a8007a77cd6c9e792de0e7d98690003208e12882b3a9`.
Confirmed canonical with all ten certification checks and five hosted smoke
matches passing. This replaces the old capture-the-heart game with rules v18:
ten territory towers, the woodland island, current equipment rules, and the
complete compact Heartwick viewer. Both BASIC and WASM file policies work.

The existing paintbot-pw league remains in ladder mode, every 10 minutes,
with its existing $432/day budget. League ID:
`league_b9458ff8-0854-4e21-82b8-3c99942902e0`.

The platform again completed certification without recording its replay URL.
On retry, the real replay/results and sixteen clean player statuses were fetched,
the replay hash was verified natively, and the normal lifecycle endpoint received
the verified artifact URLs. The certification checks then passed normally.
Verified hosted replay job: `dd4fab30-1a27-4cb4-8236-f4afa0a06c6f`, hash 2109017010.
The published viewer was opened and visually checked, including its island,
territory overlay, heart towers, equipment events, and fractional speed controls.

Validation: all eleven Paintbot test suites and five Python runtime tests pass.
The v8 round-cover fixture now explicitly selects v8; current terrain otherwise
changes its line-of-sight premise. Walkability reuses a height raster rather than
computing every slope probe's terrain independently. Vet was unavailable because
its Anthropic credentials were not configured.

Player source and validation remain private in `daveey/cogamer`; they are not
included in this public package.

The separate league credit pool was empty and blocked every scheduled round.
Funded 4,320 credits (the existing $432 budget) and configured a daily refill
with the same 4,320-credit balance cap. Round #5 then started with the newly
placed daveey-heartwick:v1 champion (policy version
`ba035f7e-1f3a-4896-b18f-90157f46b0de`).

## Baseline territory repair — 2026-09-13, 0.3.19

The WASM baseline was navigating to a hard-coded capture-the-flag destination
that is not a Heartwick control heart. It now selects actual unowned hearts,
holds position to capture, and retargets after ownership changes. The source
and reproducible artifact provenance are checked in alongside the baseline.

Implementation `629a6ca` and provenance correction `2c61a0a` were merged into
main by a normal fast-forward push after GitHub PR APIs failed. Linux, macOS,
and Windows CI passed. Both actual-WASM navigation regressions fail against
the former league artifact and pass against the replacement; eight runtime
tests also pass. Vet could not run because its provider credentials were absent.

Version 0.3.19 is certified and canonical; all ten certification steps and five
hosted smoke episodes passed. All smoke replay hashes verified natively, and
a fresh hosted viewer displayed Replay hash verified. The game-owned replacement
baseline is active, the old baseline was retired, and the league filler policy
reference was updated. Exact identifiers are in BASELINE_DEPLOYMENT.json.

Replaying the reported stuck state with only the four affected baseline command
streams replaced made all four leave the cluster within 100 ticks (4.17 seconds)
and capture four hearts. Other seats retained recorded commands, so this is
behavioral recovery evidence, not a competitive win-rate estimate. Private
competitive policy source and active submissions were unchanged.

Fresh league round 306 selected the replacement in all three matches. Episode
`ereq_1e4b5688-ce10-4e13-9883-b300a5156c8d` completed on 0.3.19: all 3,485
frame hashes verified natively and the hosted viewer showed Replay hash verified.
The four replacement baseline seats captured 3, 3, 1, and 4 hearts respectively.

## Shallow river release: 0.3.20

GOTA-style shallow water now winds across Heartwick, with a carved riverbed,
marsh banks, and a mouth that joins the sea. Cogs can wade across. Rules 29
share the new terrain with WASM observations; older replays retain their maps.

PR #31 merged as `51d06c2681cef74b4a684e4fe57bfe707348b7cf`. All 24 Paintbot
Nim suites, runtime/baseline checks, and Linux/macOS/Windows CI passed.
Native and Python terrain match at 9,660 sampled positions.

`cow_9c62356a-917b-4ee2-865b-db307ad727e1` is certified and canonical. All ten
hosted certification checks and five smoke episodes passed; every smoke
reproduced hash `1426543776` over 240 frames. The hosted viewer renders
the river and displays Replay hash verified.

The active private Heartwick v7 source needs no change or resubmission. Its
full river compatibility match verified 3,184 frames, hash `1886620807`;
private PR #115 records the evidence. Active league memberships were read
back after publication. Exact release identifiers are in RIVER_DEPLOYMENT.json.

Fresh league round 520 used 0.3.20 in all three matches. Episode
`ereq_c014500d-5ad2-4d69-ac87-6ca779efb270` completed with all 3,179 native
frame hashes verified (`1225788627`).

## River slowdown — 0.3.21

Rules 30 slows cogs in river water to one-quarter movement speed. Dry banks retain normal speed and old replays preserve their original movement.

Certified and canonical: `cow_2c7a1169-de41-442e-9b94-3bfaf3d7fff5`. All five hosted smokes and the hosted viewer verify. Fresh league round 532 completed verified games of 2,891 ticks (hash `3374707603`) and 2,851 ticks (hash `3140797131`); [watch the replay](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_2c7a1169-de41-442e-9b94-3bfaf3d7fff5/sha256%3A7ca1b727e74d8a631303dec38cbb0d19a53a927674d249943b50e96649e7b216/index.html?v=2#replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2Fd37aeee3-6a6f-4a4f-9228-99f2c0d4bfc8.replay). See `RIVER_SLOWDOWN_DEPLOYMENT.json` for evidence.

## Irregular river and narrow estuaries — 0.3.23

Rules 32 adds bends at multiple scales, uneven banks, and three thin coastal mouths. The river ends inland and retains quarter-speed water movement. Certified and canonical as `cow_a699b645-d014-498e-a9e8-1fa479209006`. All five hosted smoke replays verify; [fresh league round 546 replay](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_a699b645-d014-498e-a9e8-1fa479209006/sha256%3A50ff89ef0d700f7cdacc54b48ae319362955bb6ab6138b659519c1f4748c3000/index.html?v=2#replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F7a56d1c7-382e-4267-a4e9-a799c58af409.replay) verifies ticks=3504 captures=[10, 0] hash=4165800609. See `FRACTAL_RIVER_DEPLOYMENT.json` for evidence.

## Inland lake — 0.3.24

Rules 33 replaces the river with a closed, irregular inland lake. Dry land surrounds the lake; cogs in the water retain quarter-speed movement. Older replays preserve their original terrain.

PR #35 merged as `364399a`. Version 0.3.24 is certified and canonical as `cow_2f181565-e883-45d4-b6bf-561a36767648`. All 24 Nim suites, ten Python/runtime and WASM checks, 9,660 terrain parity samples, and Linux/macOS/Windows CI passed. All ten certification steps and five hosted smoke episodes passed; each replay verifies 240 ticks with hash `616895535`. The hosted viewer displays Replay hash verified.

The active private policy needs no source change or resubmission: its full lake match verifies 3,528 ticks, hash `3599040568`; private PR #119 records compatibility. Active memberships were read back.

[Watch the hosted lake replay](https://api.observatory.softmax-research.net/v2/coworlds/replays/static/cow_2f181565-e883-45d4-b6bf-561a36767648/sha256%3A89c1d31a8f78e01c0833d0721b17cdf8b74ca0f812929c27073a41eeeb006f79/index.html?v=2#replay=https%3A%2F%2Fsoftmax-public.s3.amazonaws.com%2Freplays%2F0adfddc5-b2c0-443b-9b99-c7153fec083a.replay). A fresh league round was triggered; at this verification checkpoint, round 601 still had a running match on 0.3.23, so league evidence for 0.3.24 remains pending. Exact release and verification evidence is in `LAKE_DEPLOYMENT.json`.

## Elimination loses — 0.3.25

Rules 34 makes a team with no living cogs and no respawns left lose on that tick. The survivor's heart meter fills so league scores agree with the winner; mutual elimination ends the match with no bonus and the higher meter wins. Rules 33 and older keep their behavior and replay hashes.

PR #36 merged as `0d643af`. Version 0.3.25 is certified and canonical as `cow_e3d191e5-f707-4761-8135-065ef128cd51`, deployed by the Deploy Coworld workflow after a dry run on the branch. All 25 Nim suites, eight Python runtime tests, and Linux/macOS/Windows CI passed. All ten certification steps and five hosted smoke episodes passed; each smoke replay verifies 240 ticks with hash `616895535`.

League round 815 was the first on 0.3.25. All three matches ended by elimination with the winner's meter at exactly 900: 1,796 ticks (hash `2634814137`), 1,426 ticks (hash `608302538`), and 923 ticks (hash `3174445628`). Round 814's rules-33 replays still verify on the new binary. [Watch a hosted elimination replay](https://d1kovwradqjymp.cloudfront.net/bundles/d4aba273f1d3b375b82e81ac7ce65f556bf11e23afa974e8ccd099cc36d51d5d/28be0bebdf284950b81b9b2801952669/index.html?v=2#replay=https%3A%2F%2Fd1kovwradqjymp.cloudfront.net%2Freplays%2F82504b30-d53d-4e9f-aef6-5b8d3c847216.replay); the viewer displays Replay hash verified.

No private policy match was played for this release: rules 34 changes no policy API or observation. Exact identifiers are in `ELIMINATION_DEPLOYMENT.json`.

## Advisor oracle for WASM seats

The runtime gains two optional host imports, `paintbot.oracle_ask` and `paintbot.oracle_poll`
(`coworld/paintbot/runtime/oracle.py`; see the guide). A seat can ask one operator-configured
HTTPS endpoint for typed judgments through the host; the host answers on a later tick and never
blocks. Per seat: one request in flight, `COGAME_ORACLE_INTERVAL` ticks between asks (default 24),
`COGAME_ORACLE_DEADLINE` seconds per request (default 2), 32 KiB bodies and 64 KiB answers. The
pod must be given network egress to that endpoint plus `COGAME_ORACLE_URL`, `COGAME_ORACLE_KEY`
and `COGAME_ORACLE_MODEL`; without the URL the feature is off and the ask returns 0. No rules
version, observation, replay format or BASIC behavior changes. Four new Python runtime tests
cover the round trip, rate limiting, the deadline, the disabled path and body validation; CI now
runs `test_runtime.py`.

Whether a league enables the oracle is a league decision: an advised seat has a different
compute class from the 20,000-instruction BASIC budget, so either every entrant gets it or an
advised league is scored separately.

### On hosted leagues: through the LLM sidecar

A hosted game pod has no provider credentials and may not set `AWS_*` in its manifest; all model
traffic goes through the platform's per-pod LLM sidecar at `AWS_ENDPOINT_URL_BEDROCK_RUNTIME`.
When `COGAME_ORACLE_URL` is unset and that variable is present, `Oracle.from_env` posts to
`<sidecar>/v1/systemone` (the sidecar's System One route, which forwards to OpenRouter's
`/api/v1/systemone`) with no credential and `X-Coworld-Player-Slot: <seat>`, so spend and the
request-rate bucket are charged to the asking seat. Defaults there: model `typesafe/jev-1.13` (the
sidecar takes canonical slugs only, so no moving `latest`), 24 ticks between asks (the sidecar's
System One bucket admits 120 requests a minute per slot, four times its chat ceiling). `COGAME_ORACLE_MODEL`, `COGAME_ORACLE_INTERVAL` and
`COGAME_ORACLE_DEADLINE` still override, and `COGAME_ORACLE=off` in the manifest's game env turns
the advisor off for a release.

The league decision above is therefore made on the platform, not in this image: the league's
per-episode LLM spend limit applies per seat, and $0 disables the advisor. A sidecar that predates
the System One route answers 404; the oracle then stops asking for the rest of the episode, so
this release is safe to deploy before the platform change. The first eight failed asks are written
to the game log with the HTTP status and response body (model not allowed, spend limit, missing
route), because an advised seat that silently plays unadvised scores like any other episode.

Locally, `COGAME_ORACLE_URL=https://openrouter.ai/api/v1/systemone` with an OpenRouter key in
`COGAME_ORACLE_KEY` is the same wire format as TypeSafe's own endpoint; `jev-latest` resolves on
both. Four more runtime tests cover sidecar discovery and precedence, the slot header and absent
credential, the missing-route breaker, and a 429 failing only its own ask.

## Advisor oracle for BASIC seats

BASIC seats reach the same oracle through typed host functions (`oracleState`, `oracleQuestion`,
`oracleCriterion`, `oracleAsk`, `oraclePoll`, `oracleAnswer`, ...; see the guide). The engine
(`examples/paintbot/oracle.nim`) drafts the JSON and ships accepted asks in its world line as
`"oracle":[{slot,id,body}]`; the host forwards them to the endpoint under the same per-seat limits
and replies `{"commands":[...],"oracle":[{slot,id,status,answers}]}` with answers flattened to
int32 (`oracle.flatten`). The host passes `PW_ORACLE=1` and `PW_ORACLE_INTERVAL` to the engine only
when it has an oracle (a `COGAME_ORACLE_URL`, or the hosted sidecar), so without one BASIC scripts see every ask refused and the
bridge keeps its legacy list reply. No rules version, observation or replay format changes.
Covered by `tests/test_paintbot_oracle.nim` (drafting, delivery, scaling, refusal, limits) and
three more runtime tests (flattening, the bridge round, the engine environment).

### Evaluation aids and a larger string pool

A BASIC oracle draft is text-heavy: a realistic one (state sentences plus nine questions with
criteria) peaks near 250 string handles, the old per-decision limit. The pool now holds 1,024
handles (arena unchanged at 64 KiB). `COGAME_TICK_SECONDS` paces the host bridge for local
real-time evaluation and `PW_BASIC_PEAKS=1` prints per-seat BASIC peaks; both are off by default
and neither changes rules, observations or replays.

## Stronger BASIC baseline

`coworld/paintbot/players/base.bas` and `examples/paintbot/players/base.bas` (now identical) were
rewritten: full-windup aim lead with own-motion compensation, random evasive footwork, two
stateless squads of four that agree on a heart from public ownership alone, and breaking off
when visibly outnumbered (see the guide). No engine, rules, observation or API change. Against
the previous baseline in the native engine: 100-0 over 100 side-swapped matches (seeds 1-50),
peak 5,670 instructions and 8,722 work units per decision against limits of 20,000 and 50,000,
no seat errors. This changes the opponent every league entrant meets; not yet deployed or
certified.
