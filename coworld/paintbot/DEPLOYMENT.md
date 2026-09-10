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

## Certification blocker

Two hosted certification runs failed because the completed smoke episode had no replay URL in its database record. The game itself completed with results and a valid replay artifact. The first hosted replay was downloaded through the job artifact API and verified locally: 240 ticks, hash `3045561490`.

- First certifier job: `47222b00-32c0-421e-a04b-5c4a3a71d76a`
- First episode request: `ereq_b0f25d26-f794-4e0b-b474-24ba71905d95`
- First game job: `04955dea-2852-4193-97c3-e9de17697204`
- Retry certifier job: `6a92dcf8-16e2-4789-afbe-e03f7d6d7721`
- Retry episode request: `ereq_56ed39dd-d725-4613-8543-6996e92fb0af`

The first game job's completion metadata includes only `results_url`; its replay artifact endpoint returns valid bytes. In Metta's `app_backend/src/metta/app_backend/job_runner/event_processor.py`, `_reconcile_completed_coworld_job_from_results` creates a completion update with only `results_url`. The normal completion path includes `replay_url`. This recovery path is consistent with the observed missing metadata; confirming which path handled these jobs requires platform telemetry.

Certification must pass before the server permits creating a league for this game. No `paintbot-pw` campaign league was created. Prepared campaign configuration uses the `1v1` and `2v2` variants and the BASIC/WASM policies above as seed opponents. Existing leagues were not modified.
