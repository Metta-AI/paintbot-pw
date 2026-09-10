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
