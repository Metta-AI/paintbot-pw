# Owned BASIC native decision evidence

This is a **training-library-only** interface (`-d:pwTraining`), separate from replay inspection. It records decisions made by owned local BASIC controllers; it does not recover controller state from public replays or establish hosted parity. Checkpoints contain source and controller memory: callers must restrict their storage and access.

## C interface

Declared in `examples/paintbot/native_env.h`:

```c
int pw_debug_set_trace(void *handle, int enabled);
int pw_debug_status_json(void *handle, char *out, int32_t capacity);
int pw_debug_trace_json(void *handle, char *out, int32_t capacity);
int pw_debug_observation_json(void *handle, int seat, char *out, int32_t capacity);
```

All JSON documents carry `schema_version: "paintbot_native_debug_v1"`. Reads return the byte length and write compact UTF-8 **without a NUL** only if the entire document fits. Use `(NULL, 0)` to size; undersized buffers remain untouched. Invalid arguments return `-1`. Trace reads return `-2` when disabled or no traced step has completed. Reads never decide or draw RNG. `set_trace` accepts exactly 0/1, returns 0, and discards the previous record and any partial capture.

### Status and supported checkpoints

Status fields, in order: `schema_version`, `tick`, `terminal`, `phase`, `supported`, `reasons`, `pending_override`, `trace_enabled`, `seats`, `rules_version`, `snapshot_build_id`, `program_sha256`, `controller_sha256`, `world_hash`.

`phase` is `pre_decision` or `post_decision_pre_step`. `tick` is the next world-step tick. Flags are JSON booleans. `world_hash` is the unsigned `pw_state_hash` rendered as a decimal string. Program digests hash exact source bytes, or are empty strings for absent programs. The controller digest covers BASIC VM/string-pool state, failure/error state, neural seat records, per-seat RNG, script status/errors and carried speech. The snapshot build ID is not a substitute for an executable/dependency/config provenance record.

Owned exact-restore callers must require `supported == true`: nonterminal, all BASIC seats, pre-decision, no pending command, and no unsupported controller/configuration. Reasons include:

- `terminal`, `phase_not_pre_decision`, `pending_override`;
- `no_basic_program:N`, `compile_failed:N`, `policy_seat:N`;
- `advisor_reference:N`, `neural_reference:N`: compiled host calls, not words in comments/strings;
- `decoder_seat:N`, `shadow_script:N`;
- `teacher_classes`, `damage_scale:N`, `fire_period:N`, `action_override:N`, `handicap`.

This is a capability check, **not a change to the legacy save/load API**. `pw_world_save/load` still support their existing wider configurations. The caller must reject unsupported owned-run checkpoints rather than silently accepting a partial continuation.

### Observation

`pw_debug_observation_json` returns `schema_version`, `seat`, `tick`, `phase`, `observation`.

An observation has `visibility: "seat"`, `as_of_tick`, `source: "seat_view"`, `self` and `agents`. `self` contains the 21 BASIC DATA fields in `DataNames` order. `agents` contains one entry per seat: `slot`, `visible`, `x`, `y`, `hp`, `team`, `carrying`, all integers. These are SeatView values, not unmasked world state.

### Last completed step

Trace fields: `schema_version`, `tick`, `decided_ahead`, `world_hash_before`, `world_hash_after`, `controller_sha256_before`, `controller_sha256_after`, `seats`.

Each seat contains `seat`, `program` (`basic` or `none`), `decided`, `observation`, `observation_missing_reason`, `intended`, `normalized`, `applied`, `replaced_by_raw_command`, `vm`, `source_trace`.

- `tick` names the pre-step decision. `decided_ahead` distinguishes `pw_script_decide` from an in-step decision; an ahead decision is not executed twice.
- `intended` is the BASIC order. `normalized` clamps aim exactly like the raw-command ABI, leaving goals verbatim.
- `applied` is captured **after raw-command replacement and `gateFire`, immediately before simulation**, not inferred from `scriptOrders`.
- Commands contain exactly `walk`, `goal_x`, `goal_z`, `shoot`, `aim_x`, `aim_z`, `charge_grenade`, `sneak`, `direct`, `self_destruct`, in that order. Coordinates are integers; flags are booleans.
- Missing observation reasons are `no_program`, `program_failed`, or `dead`. Missing observations/intention/VM evidence are explicit nulls as applicable.
- VM evidence: `ran`, `failed`, `error` (string or null), `instructions`, `work_units`, `max_instructions`, `max_work_units`. A failed program produces zero intended commands and recorded failure, not a fabricated explanation.
- `source_trace` is always null: source-line/branch explanations are not implemented.

Tracing starts disabled. Trace data is excluded from snapshot bytes. Reset, successful load, script/policy/shadow changes, and toggling trace invalidate its record. Successful load preserves the destination tracing switch; refused loads preserve its state and record.

## Deterministic snapshot correction

Bassy renews text-storage owners using a process-global counter at restart. Serializing those allocation IDs verbatim made identical restored continuations differ in save bytes and controller digests. Runtime snapshot serialization now uses owner 1 for live string references and owner 0 for stale references, preserving handle indices and stale-reference invalidity without mutating live state. The snapshot build ID changes, so old builds are refused normally.

The regression first failed on controller digest and byte equality after each future decision while world hashes still matched. Existing Bassy tests compared string contents after continuation but did not compare subsequent full snapshot bytes; the older native fixture mainly exercised integer memory. The new public string/RNG checkpoint fixture closes that gap. It also checks early corrupt/wrong-build refusal and a checksummed invalid-source late rebuild refusal without changing the destination.

## Verification commands

With Nim 2.2.10 and `POLYWORLD_DEPS` pointing at dependencies matching `coworld/dependencies.lock`:

```sh
nim r -d:release --mm:arc --threads:on -d:pwTraining tests/test_paintbot_debug_trace.nim
nim r -d:release --mm:arc --threads:on -d:pwTraining tests/test_paintbot_debug_checkpoint.nim
nim r -d:release --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_save_load.nim
nim r -d:release --mm:arc --threads:on -d:pwTraining tests/test_paintbot_bassy_snapshots.nim
nim r -d:release --mm:arc --threads:on -d:pwTraining -d:bassyNoJit tests/test_paintbot_bassy_snapshots.nim
nim r -d:release --mm:arc --threads:on -d:pwTraining tests/test_paintbot_native_seat_command.nim
nim r -d:release --mm:arc --threads:on -d:pwTraining -d:headless tests/test_paintbot_native_seat_command_ex.nim
nim r -d:release tests/test_paintbot_seat_view_boundary.nim
nim r -d:release -d:headless tests/test_paintbot_seat_view_parity.nim
nim c --app:lib --mm:arc --threads:on -d:pwTraining -d:headless -d:release \
  --nimcache:tmp/m3/lib --out:tmp/m3/libpaintbot_pw.so examples/paintbot/native_env.nim
```

Use `--nimcache` and `--out` under `tmp/` to keep generated artifacts out of source directories. The trace parity test compares 400 interleaved steps (including toggling capture), every seat's orders/world hashes, and complete save bytes. This is intentionally heavier than a world-hash-only check.

No neural/advisor exact continuation, arbitrary mid-game source replacement, replay/native transfer, source-level explanation, private ACL service, hosted execution or deployment is supplied by this interface.
