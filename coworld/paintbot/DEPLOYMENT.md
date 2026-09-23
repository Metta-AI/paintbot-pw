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

### Released in 0.3.28

0.3.28 (Deploy Coworld run 35632280384, from `53aae22`, 2026-09-21) was built, certified, uploaded
and promoted to canonical. It is the first hosted release with the sidecar route, 24-tick hosted
spacing and the missing-route breaker, and with the BASIC oracle functions a script such as
`cogames/paintbot/jev/players/jevbot.bas` needs to compile. Until the platform sidecar serves
`/v1/systemone` (Metta-AI/metta#24299), the first ask of an episode is answered 404 and logged,
and the oracle asks nothing further: advised scripts play unadvised, and nothing else changes.

### Hardening after review

A review of the hosted path found, and these changes close: a reply holding a number the host
cannot scale (JSON `1e999` parses as infinity) or a malformed `probabilities` raised out of
`basic_oracle_round` and ended the episode for all sixteen seats, where a trapping policy forfeits
only itself; a reply with no usable answer was sent to the engine as status 0, which a BASIC script
reads as "still pending" and waits on for the rest of the episode; and the per-request deadline
bounded each socket read, not the request, so a dripping reply never failed. Now `flatten` drops
what it cannot scale and never raises, the bridge turns any flattening error or empty result into
that ask's failure (`-1`, counted and logged), and `poll` fails a request past twice its deadline
and drops the late reply. Also: a sidecar is never sent a credential; a refused
`COGAME_ORACLE_URL` says so in the log; the failure log says once when it stops; the 429 comment
no longer claims a spend limit clears. Runtime tests cover each, and pin that only a missing route
(404, 405, 501, sidecar only) stops the asking: 400, 403 and 5xx do not.

Released in 0.3.29 (Deploy Coworld run 35640041740, from `5b9a9f1`, 2026-09-21): built, certified,
uploaded and canonical. The hosted path itself was confirmed on 0.3.28 the same day, from the seat
logs of league episode `ereq_aa233dfe-9805-47fe-bea0-0a2b5f95fae6`: eight advised BASIC seats, 71
asks, 70 answered and one still open when the episode ended, no failure. Answers landed a median
28 ticks after the ask (p90 51, max 84, n=70) against about 8 on a paced local machine. Whether
that is provider and sidecar latency or a hosted game ticking faster than 24 a second is not
established; a script should not assume an answer is fresh.

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
no seat errors. This changes the opponent every league entrant meets; deployed in 0.3.27 below.

## WASM baseline as a port of base.bas, and direct orders for WASM seats — 0.3.27

`coworld/paintbot/players/base_wasm.nim` replaces the CTF-era WASM baseline with a
section-for-section port of `base.bas`. Because the sprite gamepad capped any WASM policy
(8-way steps without pathing, a turret turning 5 brads per tick), WASM seats gained reply packet
`0x85`, a direct order the host maps to exactly the BASIC command (`walkTo` with engine
pathing, `lookAt`, `shootAt`, `chargeGrenade`, `sneak`; see the guide). Gamepad packets are
unchanged, so existing WASM submissions play as before. Measured through the hosted runtime,
side-swapped: the new baseline is 17-15 against `base.bas` over 32 matches (95% CI 36-69%,
interchangeable combat totals) and 16-0 against the previous `baseline.wasm`.

Merged to main as `490fd1a`/`bfd1c5f` (with `33ffd22`, the gamepad-only port it supersedes).
Version 0.3.27 was built from `7a5b5a2` (which also carries the stronger BASIC baseline and the
WASM and BASIC advisor oracles, #39-#42) after a dry run on the branch. It is certified and
canonical as `cow_db70d493-9a07-473c-863a-ec115ba7b588` (manifest
`sha256:55b321c6ad7e1f3744af84432ac912e23aae08a9f30a6d1789ae174b225a1f21`); hosted
certification and all five hosted smoke episodes passed (`ereq_5df3eeb7`, `ereq_7ca4fb64`,
`ereq_7e69fd81`, `ereq_7f9bf736`, `ereq_9288d5c5`). Linux, macOS and Windows CI passed on the
deployed commit, including `test_baseline.py` and the runtime tests.

## A fair Heartwick — rules 35, 0.3.30

With the same policy on both sides red had won 27 of 32 hosted matches. An audit of every
static feature under the half turn found the ground unmirrored (the organic deformation, coast
and lake waves are in absolute coordinates: one team's trench on a 2.5 m plateau over the lake,
its mirror at the plateau's foot; 18% of the shore with a dry mirror; groves jittered per side;
hearts and supplies nudged free per side), two engine-side biases (seat order acted red-first
every tick; path-search tie-breaks made blue's routes non-mirrors of red's; the yield side was
team-keyed), and — the largest effect — the baseline's own absolute-direction habits (priority
squad north of home and an east-first sweep for both teams). Rules 35 mirror all of it; the
baseline plays the half turn of itself; `tests/test_paintbot_symmetry.nim` guards the map. See
the guide's "A fair map" section. Validation, same file on both sides, 400 distinct seeds each:
`base.bas` red 51.7% (95% CI 47-57%), a minimal capture-and-shoot policy red 52.0%; on the old
map the baseline mirror gave red 43%. The WASM baseline against the BASIC one through the hosted
runtime on the new engine: 11-5, 5-3 as red and 6-2 as blue. The league champion source
(`heartwick.bas`) runs on rules 35 without seat errors; policies read the map through the API
and need no change. Older recordings keep their terrain, order and hashes; the replay loader
accepts rules 35.

Merged to main as `3fb68af`. Version 0.3.30 is certified and canonical as
`cow_8baf80da-08ee-4f76-ad98-ccad0554dd1c` (manifest
`sha256:fbcbc1b7db044353c3316c6842bbc1ba1651235ef50336b7af3add726a8d7ded`), deployed by the
Deploy Coworld workflow after a dry run on main; hosted certification and all five hosted smoke
episodes passed (`ereq_0d1378e0`, `ereq_5685fbfc`, `ereq_7ba95cd0`, `ereq_921324b4`,
`ereq_a47d78d3`). All 27 paintbot Nim suites, the Python runtime and WASM baseline tests, and
Linux/macOS/Windows CI passed on the deployed commit.

## Top-bar heart strip — 0.3.31

The viewer's header now shows the ten territory hearts between the Ember and Azure plates,
ordered along the camp-to-camp axis so the strip mirrors the map: owned hearts fill in the
team color, unclaimed hearts stay outlined, a capture in progress traces the outline in the
capturing team's color, and a contested heart pulses (#48). Viewer only; rules, recordings and
hashes are unchanged.

Merged to main as `491ae56`. Version 0.3.31 is certified and canonical as
`cow_1fa948f7-11dd-4925-8ba2-a016b980da30` (manifest `sha256:54a09ab25c7d6641f5c05db4b5babf223e7f692c7903bfbdfbb0dadd2d3b22a0`), deployed by the Deploy
Coworld workflow (run 35682382373) after build.yml passed on the merge commit; hosted
certification and all five hosted smoke episodes passed (`ereq_2ff98632`, `ereq_70212521`,
`ereq_8f243930`, `ereq_a6e4c3ba`, `ereq_ba8b8574`).

## Glory scoring — 0.3.32 (rules 36)

The match score is now per-team glory: it starts at the match length in seconds (600),
loses one per second, and grows on events — a heart capture +5, an enemy tag +2, thirty
seconds without collecting a supply +10 (per team, repeating), friendly fire taken in the
opening thirty seconds +30 per hit. At the end the loser's glory is zeroed and a draw pays
nobody, so `scores()` and the ladder rank by a winner's glory; the heart meter still decides
who wins. BASIC `glory(team)`, a WASM `glory team <t> value <g>` sprite, a viewer toast at the
very top for each award, glory in the header and the rule in the scoreboard dialog (#49).
Glory joins the rules 36 hash; older recordings are unchanged.

Merged to main as `a2b1afd`. Version 0.3.32 is certified and canonical as
`cow_092d93c2-c367-4c9c-8640-62e96d78960d` (manifest
`sha256:445e5edce429a422130fad7a88669630e118ef73f46e252a6e8d38e2081effd1`), deployed by the
Deploy Coworld workflow (run 35698209569) after build.yml passed on the merge commit; hosted
certification and all five hosted smoke episodes passed (`ereq_071b7be8`, `ereq_20bd9df9`,
`ereq_72fc45d5`, `ereq_a8dcc08e`, `ereq_ea9a54bf`). The paintbot-pw league follows the canonical
version (not locked), so round 1293, created four seconds after promotion, is the first glory round.

## Jev-advised BASIC baseline

`coworld/paintbot/players/jev.bas` (manifest player `basic-jev`, copied to
`examples/paintbot/players/jev.bas`) is the BASIC baseline with the Jev advisor layer that plays
in the league as `daveey1-jevbot-v2` (daveey/cogamer `cogames/paintbot/jev`, jevbot v2). It is
generated by `coworld/paintbot/tools/make_jev_baseline.py` from `players/base.bas`, so it carries
the rules 35 mirror play; `--check` runs in CI so the committed file cannot drift from the
baseline. No engine, rules, observation or API change.

Where no oracle is configured the layer's asks are refused and the file plays exactly like
`base.bas`: `tests/test_paintbot_jev_baseline.nim` runs both files on all sixteen seats and
requires the same state hash tick for tick and no seat disabled; with the engine's oracle
switched on and no replies, it requires the drafted requests to stay inside three quarters of
the BASIC budget. Certification seats 1 and 2 play `basic-jev`, so the hosted engine compiles
and runs it on every release. Porting found one difference: the asker's "keep current" shout
fired at tick 0 for every cog (its timer starts at 0), and the baseline's turn-to-speech habit
then played a different match; the generator now shouts it only after an answer. In the native
engine, same file on both sides, seeds 1-8 at 4,800 ticks: identical hashes to `base.bas` on
every seed. Peak per decision without an oracle about 10,300 instructions, 14,500 work units and 22
string handles; drafting requests with the oracle on, about 12,600 / 26,700 / 131 (limits
20,000 / 50,000 / 1,024). Not yet deployed; it ships with the next version.

## BASIC only: the WASM lane is removed — 0.3.33

Every seat is now a BASIC script. The WASM policy lane (a Wasmtime instance per seat fed the
CTF sprite protocol by a host-side renderer, answering with gamepad or direct-order packets)
is gone: `runtime/wasm_policy.py`, `runtime/sprite.py`, the WASM baseline
(`players/base_wasm.nim`, `baseline.wasm`, its provenance and build tool) and
`test_baseline.py` are deleted, the pod image no longer installs `wasmtime`, and the engine's
policy bridge carries advisor-oracle traffic only (`{"rulesVersion","tick","oracle"}` out,
`{"oracle"}` back; no world snapshot, no external commands). A WASM upload now forfeits its
seat at episode start with "WASM modules are no longer accepted; submit a BASIC source file",
exactly as a malformed BASIC file does, and the other fifteen seats play on. Rules, recordings
and hashes are unchanged; older episodes keep their viewers.

Why: with the direct-order packet, a WASM seat already acted through BASIC's actuators, so the
lane amounted to a second hand-maintained observation encoding (kept in parity by thousands of
terrain samples), a compute budget about a million times BASIC's, and a build chain that needed
a coworld-ctf checkout and wasi-sdk 33. Every runtime-specific incident in this log (the CTF
flag destination, the gamepad cap) was on that side.

League follow-up after the deploy: the filler list drops `paintbot-pw-territory-wasm:v1`
(`adcd246b-8a85-47b6-b63e-7f0dfcb7c40a`) and keeps `paintbot-pw-basic-v22:1`
(`c51834df-5ce1-4307-9134-b6e80211dece`); the WASM memberships (`daveey-cogamer-paintbot-cdx`
and the territory-wasm filler) are retired rather than left to forfeit three rounds into
disqualification. `daveey-heartwick` is a BASIC script (`heartwick.bas`) and stays.

Merged to main as `733d632` (PR #51). Version 0.3.33 is certified and canonical as
`cow_1ecd4d02-7d0e-4d95-9649-7ebaf3efdd20` (manifest
`sha256:7ed6bdf3901c498e279e8b85dcdb0382d42da0e4db02f4a854070ffe2ca0d882`), deployed from `b2f2977` by
the Deploy Coworld workflow (run 35702798901) after a dry run on the branch (run 35699963916) and
build.yml on the merge commit; hosted certification and all five hosted smoke episodes passed
(`ereq_0138d206`, `ereq_04c1d71a`, `ereq_3cfb62f8`, `ereq_da0f9794`, `ereq_de5c1ffd`). The league
follow-ups above were applied the same hour: the filler list is `paintbot-pw-basic-v22:1` alone, and
the `paintbot-pw-territory-wasm:v1` and `daveey-cogamer-paintbot-cdx:1` memberships are retired.

## Glory actually plays: rules 37 — 0.3.34

0.3.32 and 0.3.33 stamped recordings rules 36 while the live engine still played rules 35
(`replayRulesVersion` was bumped, `visionRulesVersion` was not), so hosted matches scored
heart-meter points, no glory was earned, and every replay of those versions failed
"Replay hash mismatch at 1". #52 moves glory and its hash fields to rules 37, sets both
defaults to 37, and reads a 36 header as rules 35, so the 0.3.32/0.3.33 recordings play back
(verified on hosted episode `1406ea7e`, 986 ticks). Glory is a self-imposed handicap: the
capture and tag awards from #49 are gone, and only thirty seconds without supplies (+10) and
friendly fire taken in the opening thirty seconds (+30 per hit) pay. The header shows glory as
the headline score in its own column, with the meter's count beside the bar.

Deployed from main `2bc6809` (which also carries #53 and #54) after a pinned-branch attempt
was refused (real uploads must run from main). Version 0.3.34 is certified and canonical as
`cow_d21b3259-63c6-47aa-995f-51a7b979318e` (manifest
`sha256:69382d28962c11afb887c9a9066cf63fc85b845912ab902a4b44ee08fcdac132`), Deploy Coworld run
35704966436; hosted smoke passed (`ereq_123e2fc0`, `ereq_658db8bd`, `ereq_6f961a9d`,
`ereq_d0bf299d`, `ereq_dae658eb`); the `ereq_123e2fc0` replay carries a rules 37 header and plays
natively for all 240 ticks (a 240-tick smoke match draws, so glory is zero for both teams). The
paintbot-pw league, paused at 07:35Z to stop recording unplayable 0.3.32 episodes, was unpaused
once 0.3.34 was canonical.

## Action contract v2, lead-compensated identity aim — 0.3.35

#61 adds action contract v2 (`paintbot-pw.rules37.action.v2.51-25-2-2-2`, `51f602ef…`): a
neural bundle's identity aim resolves to the target's lead-compensated point instead of its
body position. The v1 decoder is kept and selected by the bundle's embedded contract hash, so
every existing v1 bundle plays exactly as before; manifests may use schema
`paintbot-neural-basic/2`. Decoder-only: no `sim.nim` change, no rules bump, replays and
hashes of earlier versions are unaffected, and the league was not paused (every competing
membership is plain BASIC).

Deployed from main `e30c12a` (build.yml run 35765037969 green; dry run 35766589038 first).
Version 0.3.35 is certified and canonical as `cow_ad9eb10f-f539-4e42-8278-c4e9d1a79f83`
(manifest `sha256:b031962fe583ef295278db78d2476183883c7f322ad610a0591dd9432e5e95f9`),
Deploy Coworld run 35767016530; hosted smoke passed (`ereq_96cea902`, `ereq_9fb25f8d`,
`ereq_b146885a`, `ereq_cdbc5ed9`, `ereq_d097790f`). The paintbot-pw league picked the row up
with round #1354.

Neural canaries on the new version, both 16 seats exit 0 with hash-verified replays:

- v1 preserved: the contract-v1 bundle that produced `ereq_15c41877` on 0.3.34 re-ran on
  0.3.35 as `ereq_280e00ba` and produced a byte-identical replay (993 ticks, hash 301441621).
- v2 runs: a schema-2, contract-v2 bundle ran as `ereq_895e3c3c` (1139 ticks, hash
  3871687001); each neural seat's log carries #59's `neural: peak_ops=… budget=4000000
  model=w128` line.

## Decoder option `fire_hold_teammates` — 0.3.36

#65 adds a per-bundle decoder option under manifest schema `paintbot-neural-basic/2`:
`"decoder": {"fire_hold_teammates": true}` drops a shoot order aimed through a visible teammate.
Default off is byte-identical to 0.3.35 (option-off parity proven over 100 807 ticks in the PR; here
the R17a bundle's option-off replay is whole-file identical between a 0.3.35 and a 0.3.36 engine).
Decoder-only: no `sim.nim` change, no rules bump, replays and hashes of earlier versions are
unaffected, and the league was not paused (every competing membership is plain BASIC).

Deployed from main `d529636` (build.yml run 35774926860 green on all three OSes). Two sessions
dispatched the release in parallel: runs 35776537613 (dry) and 35776950564 (real) uploaded the
version; a second pair, 35776637751 (dry, green) and 35777253640 (real), was stopped by the
workflow's own version guard ("0.3.36 is not newer than the latest uploaded version") and uploaded
nothing. Version 0.3.36 is certified and canonical as `cow_abd8cb4a-2601-4f1d-80a0-fb973fd2487e`
(manifest `sha256:09c231baa1222116acfa083882e0dec8159571c2b32b76bc0430cd46bf4f9b0c`), Deploy
Coworld run 35776950564; hosted smoke passed (`ereq_50b4d7de`, `ereq_82253922`, `ereq_99003a6e`,
`ereq_ba5064a2`, `ereq_db0159f9`). The paintbot-pw league picked the row up with round #1364.

Neural canaries on the new version, all 16 seats exit 0 with hash-verified replays:

- v1 preserved: the contract-v1 bundle behind `ereq_15c41877` (0.3.34) and `ereq_280e00ba` (0.3.35)
  re-ran as `ereq_0594ef14` and produced the same replay file (993 ticks, hash 301441621).
- option on: the same contract-v2 weights that ran option-off as `ereq_f7e7870a` on 0.3.35 (996 ticks,
  hash 3385542036) re-packaged with `fire_hold_teammates` ran as `ereq_bc730dad` (1661 ticks, hash
  2301985526); each neural seat log now carries `fire_holds=N` beside the peak-ops telemetry, and the
  replay's per-seat telemetry shows the neural team's damage to its own side falling from 21 to 4
  against the same opponent and seed.
- schema-2 fixture without the option: `ereq_54ee9b00` (1287 ticks, hash 1085495096).

## Decoder option `sampling` — 0.3.37

#69 adds a second per-bundle decoder option under manifest schema `paintbot-neural-basic/2`:
`"decoder": {"sampling": {"mode": "categorical", "temperature": t, "heads": [...]}}` draws the
categorical action heads from a stream seeded by the match seed and the seat, so a sampled seat is
still replay-deterministic. Bundles without the key decode exactly as before (headwise argmax).
Decoder-only: no `sim.nim` change, no rules bump, replays and hashes of earlier versions are
unaffected, and the league was not paused.

Deployed from main `488a066` (build.yml run 35822523754 green on all three OSes) by one Deploy
Coworld run, 35823868854 (`Deploy Coworld 0.3.37 (upload)`). Before dispatch, the pre-dispatch
check found no other deploy run in flight or in the previous 30 minutes, and `next-version`
returned 0.3.37 in the same minute. Version 0.3.37 is certified and canonical as
`cow_6e2f8488-b9cb-4afd-a38a-6e76b62936b7`
(manifest `sha256:122874aa30f77e65a9752da4bfa36a4d4c76b3c8073c8b58befecb05c66ab690`). Hosted smoke
passed (`ereq_000223a1`, `ereq_0f7c78fd`, `ereq_1af8accf`, `ereq_91047a71`, `ereq_aab32d0b`). The
paintbot-pw league picked the row up with round #1422.

Neural canaries on the new version, all 16 seats exit 0 with hash-verified replays:

- v1 preserved: the contract-v1 bundle re-ran as `ereq_fd819894` and produced the same replay file
  as `ereq_0594ef14` on 0.3.36 (993 ticks, hash 301441621).
- fire hold preserved (argmax): the schema-2 fixture with `fire_hold_teammates` re-ran as
  `ereq_979d468e` and produced the same replay file as `ereq_e532f165` on 0.3.36 (1404 ticks, hash
  2920536881).
- sampling on: one bundle with `{"fire_hold_teammates": true, "sampling": {"mode": "categorical",
  "temperature": 1.0}}` ran twice with the same body (seed 2026, same fillers), as `ereq_4ec66116`
  and `ereq_405cae9b`. The two hosted replay files are identical (1347 ticks, hash 3896881393), and
  they match a local reproduction on a `488a066` engine in every frame. Each neural seat log
  carries `sampling=categorical t=1.000 heads=01234 seed=0x… draws=N` next to the peak-ops and
  `fire_holds` telemetry, with a different stream seed for each seat.

From this release on, the league has a schema-2 neural ZIP competing, so a future decoder or
contract change must canary a copy of the live bundle before it ships.
