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
