#ifndef PAINTBOT_PW_NATIVE_ENV_H
#define PAINTBOT_PW_NATIVE_ENV_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Buffers: 16 seats, 512 floats/seat (observation contract teams.view.1; a handle from
 * pw_create_observation(..., 202) writes a per-match width at any seat count: see
 * pw_set_seats below), 5 int32 actions/seat. Every observation column is a value the seat's
 * BASIC builtins can read (docs/neural/seat-view.md), and pw_step's actions reach the engine
 * only through the reference decoder script (players/neural_decode.bas). The contracts
 * before teams.view.1 / ffa.view.1 were retired for BASIC parity.
 * Output reset masks are independent of match terminals. Handles are exclusive
 * to one call at a time. Caller provides correctly sized non-null buffers. */
int pw_env_version(void);
int pw_observation_size(void);
int pw_action_count(void);
void *pw_create(int32_t seed, int32_t max_ticks);
void pw_destroy(void *handle);
int pw_reset(void *handle, int32_t seed, int32_t max_ticks);
int pw_observe(void *handle, float *observations, float *state_resets);
/* Same bytes as pw_observe for every seat whose bit (1u << slot) is set; the other
 * seats' rows of both buffers are left untouched. Additive to v1. */
int pw_observe_seats(void *handle, uint32_t seats, float *observations, float *state_resets);
int pw_step(void *handle, const int32_t *actions, float *rewards, float *terminals);
uint32_t pw_state_hash(void *handle);
/* pw_results: [tick, winner, glory0, glory1, meter0, meter1, hearts0, hearts1]; in FFA-kin
 * [tick, winner (-1 playing, -3 ended), seats still in the match, total raw score (points),
 * best R_i (points), the seat holding it (lowest on a tie), control hearts owned by any seat,
 * great-heart bounty paid in total (points)]. pw_bot_actions returns -1 in FFA-kin. */
int pw_results(void *handle, float *eight_results);
int pw_bot_actions(void *handle, int side, int level, int32_t *actions);
/* Per-seat combat telemetry, cumulative since the last create/reset; additive to v1.
 * Pure telemetry: reading or ignoring it changes no simulation state or hash.
 * Damage is health removed (armor absorbs first); a hit is a damage event past the
 * shield and life checks; captures are the world's own credit for flipping a heart;
 * first_friendly_fire_tick is -1 until this seat first damages a teammate. */
typedef struct {
    int32_t damage_dealt_enemy, damage_dealt_team, hits_enemy, hits_taken;
    int32_t kills, deaths, captures, first_friendly_fire_tick;
} pw_seat_stats_t;
int pw_seat_stats(void *handle, int32_t *sixteen_seats_times_eight); /* pw_seat_stats_t[16] */
/* BASIC seats (additive to v1). A seat with a script installed is driven by the
 * production interpreter with the hosted host functions, limits and 20,000-instruction
 * per-decision budget; the caller's actions for that seat are ignored. The script is
 * compiled now and re-instantiated (persistent variables cleared) on every pw_reset;
 * length 0 removes it. Returns 0 running, 1 compile failed (seat idles, as hosted),
 * -1 bad arguments. Worlds without scripts are byte-identical to before. Host functions are
 * the current world's mode's; every pw_reset recompiles under the mode it applies, so an
 * FFA-only script (kin, gene, ...) set before the reset that switches to FFA runs from it. */
int pw_set_seat_script(void *handle, int seat, const char *source, int32_t length);
/* 0 unscripted, 1 running, 2 compile failed, 3 disabled by a runtime error (the same
 * errors that disable a hosted seat). Copies the NUL-terminated error text when
 * message/capacity are given. */
int pw_seat_script_status(void *handle, int seat, char *message, int32_t capacity);
/* The command a scripted seat issued on the last pw_step, ten int32:
 * {walk, goal_x, goal_z, shoot, aim_x, aim_z, charge_grenade, sneak, direct, scripted}.
 * walkTo -> walk+goal; lookAt -> aim; shootAt -> shoot+aim; last call of a kind wins;
 * aim (0,0) is "no aim order" (the game reads it that way). Zeros, scripted=0, for an
 * unscripted seat. Mapping to the action contract is exact only when goal equals a
 * heart or visible pickup position or pos+200*compass (clamped), and when aim equals
 * a visible body's position or pos+5000*compass (clamped); anything else has no exact
 * candidate. */
int pw_seat_orders(void *handle, int seat, int32_t *ten);
/* Raw command (additive; command-space opponents and replayed recordings). The seat
 * executes nine = {walk, goal_x, goal_z, shoot, aim_x, aim_z, charge_grenade, sneak,
 * direct} (flags 0/1) on the NEXT pw_step only, built as BASIC's orders build a command:
 * the goal verbatim (walkTo; the world clamps where it walks and stores the point), the aim
 * clamped to the map (lookAt/shootAt; (0,0) = no aim order). For that step the seat's
 * action heads are neither decoded nor checked against its forbid mask; a scripted seat's
 * script still runs but its order is replaced. A harness tool, not a seat. The fire period
 * applies only if already set on the seat (off by default). pw_seat_orders echoes the executed command (an
 * unscripted seat reports zeros again after a step without one). A second call before the
 * step replaces the first; pw_reset drops it. A library whose caller never calls it is
 * byte-identical to one without it. Returns 0, -1 bad args. */
int pw_set_seat_command(void *handle, int seat, const int32_t *nine);
/* Curriculum knobs (additive to v1), kept across pw_reset; defaults 1 and 1000 leave
 * every world byte-identical to a library without them.
 * pw_set_seat_fire_period: the seat's shoot order (script, Nim bot or caller) is honoured
 * only when the seat could fire now (gun: cooldown 0 and no windup; spray can: spray
 * cooldown 0) and at least `period` weapon cooldown windows have passed since its last
 * honoured shot. UNIT: one cooldown window = FireCooldownTicks = 24 ticks (one second),
 * so period 4 = at most one honoured shot per 96 ticks, the same unit as the adapter's
 * fire-gated Nim bot. Only the issued order is gated: the interpreter, the script's
 * state and its aim are untouched. Period 1 never gates. Returns 0, -1 bad args.
 * pw_set_seat_damage_scale: damage dealt BY the seat is scaled by permille/1000, the
 * fraction carried to the seat's next hit (500 = every other 1-point gun hit lands; 0 = no
 * damage), the hit itself still lands (shield, cooldown relief, telemetry and friendly-fire
 * glory as before). 1000 is exact. Returns 0, -1 bad args.
 * Handicaps (all kept across pw_reset; 0 restores the rules' value unless noted):
 * pw_set_seat_max_hp: spawn/respawn/medkit HP, 1..6 (rules: 3 in teams; initial spawn at the
 * next pw_reset). pw_set_seat_lives: lives a match starts with, 1..8 (rules: 4 in teams;
 * next pw_reset). pw_set_seat_damage_taken: damage dealt TO the seat scaled by
 * permille/1000 with the fraction carried, 0..10000, 1000 = exact. pw_set_team_capture_ticks:
 * ticks team 0/1 holds a control heart alone to capture it, 36..144 (rules: 72).
 * pw_set_seat_respawn_ticks: respawn delay, 1..1440 (rules: 72). Each returns 0, -1 bad
 * args. With every knob neutral a match is byte-identical to one without them. */
int pw_set_seat_fire_period(void *handle, int seat, int32_t period);
int pw_set_seat_damage_scale(void *handle, int seat, int32_t permille);
int pw_set_seat_max_hp(void *handle, int seat, int32_t hp);
int pw_set_seat_lives(void *handle, int seat, int32_t lives);
int pw_set_seat_damage_taken(void *handle, int seat, int32_t permille);
int pw_set_team_capture_ticks(void *handle, int side, int32_t ticks);
int pw_set_seat_respawn_ticks(void *handle, int seat, int32_t ticks);
/* pw_set_seat_starts_out (training library only): 1 = from the next pw_reset the seat begins every
 * match already out (hp 0, no lives, never respawns); 0 = a normal start. The call that would put a
 * side's (seat parity's) last seat out is refused. Kept across pw_reset. 0, -1 bad args / refused. */
int pw_set_seat_starts_out(void *handle, int seat, int32_t starts_out);
/* Action contracts. teams.view.1 (version 11, "paintbot-pw.teams.view.1.action.51-25-2-2-2"),
 * its aim-offset variant (13, "paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23": the five
 * heads, then two 23-bin heads x, z; the reference decode adds ((ix - 11) * 28, (iz - 11) * 28),
 * mirrored for team 1, to an identity aim), its movement-offset variant (14,
 * "paintbot-pw.teams.view.1.action.51-25-2-2-2-23-23-23-23": those seven heads, then two 23-bin
 * heads dx, dz; the reference decode adds symmetric log-spaced offsets (bin 11 = 0, bin 11 +- j =
 * +-{16, 28, 48, 84, 146, 253, 439, 763, 1326, 2303, 4000}[j-1]), mirrored for
 * team 1, to the movement goal and clamps it to the map), its target-conditioned aim-offset
 * variant (15, "paintbot-pw.teams.view.1.action.51-25-2-2-2-23x16-23x16": contract 13's seven heads
 * and decode, but heads 5 and 6 carry one 23-logit row per identity, 818 logits per seat, and are
 * drawn from the row of the identity the aim head chose; no draw, the centre bin, for keep or a
 * compass aim), its raw variant (16, "paintbot-pw.teams.view.1.action.51-25-2-2-2-63x16-63x16-256-8-128":
 * 63 x 7 u identity offset rows, then walk direction 256, walk distance 8 and look direction 128 heads the
 * reference decoder reads in place of the compass step and the compass aim; 2490 logits per seat) and ffa.view.1
 * pointer (12,
 * "paintbot-pw.ffa.view.1.action.pointer"). pw_set_action_contract selects the contract
 * pw_step reads the caller's heads under: 11 (default), 13, 14, 15 or 16 on a 201 handle, 12 only on a
 * 202 handle; kept across pw_reset; 0, or -1 bad args. Under 13 a seat's action row is seven
 * int32 and pw_action_layout returns -1: use pw_action_layout_ext (int32[10] = {heads, seven
 * head-size slots, logits per seat, 0}). Under 14 it is nine int32 and pw_action_layout_ext
 * returns -1 too: use pw_action_layout_ext2 (int32[12] = {heads, nine head-size slots, logits
 * per seat, 0}). Under 16 it is ten int32 and pw_action_layout_ext2 returns -1 too: use
 * pw_action_layout_ext3 (int32[13] = {heads, ten head-size slots, logits per seat, 0}). pw_action_contract returns
 * the handle's;
 * pw_action_contract_hash writes the 64-hex SHA-256 an actor and manifest carry
 * (NUL-terminated, capacity >= 65; -1 for another version). What each head index means is
 * the seat's policy.bas's to decide; pw_step decodes a caller-driven seat's heads with the
 * reference decoder script (players/neural_decode.bas, neural_decode_ffa.bas) through the
 * seat's SeatView, as a hosted policy.bas does. */
int pw_set_action_contract(void *handle, int32_t version);
int pw_action_layout_ext(void *handle, int32_t *ten);
int pw_action_layout_ext2(void *handle, int32_t *twelve);
int pw_action_layout_ext3(void *handle, int32_t *thirteen);
int pw_action_contract(void *handle);
int pw_action_contract_hash(int32_t version, char *sixty_five_bytes, int32_t capacity);
/* Mapping-ceiling diagnostics (pw-bc). pw_script_decide runs the scripted seats'
 * decision for the current tick now (once; later calls before the next pw_step are
 * no-ops) so pw_seat_orders reports the orders the coming pw_step will execute; with
 * every override mask 0 the world is byte-identical whether or not it is called.
 * Returns 1 decided, 0 nothing to do, -1 bad handle. pw_set_seat_override makes a
 * scripted seat execute the caller's action (decoded by the reference decoder script) for the masked heads instead of its
 * script's order (bits: 1 walk/goal/direct, 2 aim, 4 shoot, 8 grenade, 16 sneak; 0 =
 * exact script play); the script still runs and reports its orders. Kept across
 * pw_reset. Returns 0, -1 bad args. */
int pw_script_decide(void *handle);
int pw_set_seat_override(void *handle, int seat, int32_t mask);
/* Decoder sampling (additive; the hosted bundle option decoder.sampling so probes and
 * deployment draw alike). pw_set_seat_sampling: temperature_permille 10..10000 (0.01..10.0)
 * turns categorical sampling on for the heads in head_mask (bit h = head h; 0 = every
 * head): pw_sample_actions then draws those heads from softmax(logits / T) with the
 * seat's own SplitMix64 stream, seeded from the match seed and the seat exactly as the
 * hosted seat seeds its own on every create/reset, one draw per sampled head per call;
 * the other heads take argmax. temperature_permille 0 (the default) = plain argmax, no
 * draw. Only pw_sample_actions is affected: pw_step takes the caller's actions as before,
 * so a library with these calls is byte-identical when they are never made. Options are
 * kept across pw_reset; the stream is reseeded. pw_sample_actions: logits float[82],
 * actions int32[5] out; returns 0, -1 bad args or non-finite logits. pw_seat_sample_draws:
 * decisions drawn for the seat since the last create/reset (telemetry; -1 bad args). */
int pw_set_seat_sampling(void *handle, int seat, int32_t temperature_permille, int32_t head_mask);
int pw_sample_actions(void *handle, int seat, const float *logits, int32_t *actions);
int pw_seat_sample_draws(void *handle, int seat);
/* Sampling salt (additive, training library only; a hosted seat has none). Non-zero salt
 * seeds every seat's sampling stream (pw_sample_actions' and each policy seat's own) from
 * neural_contract.samplingRngSalted(match seed, slot, salt) = SplitMix64 initRng(seed,
 * 0x53414d504c450000 ^ (slot+1) << 32 ^ mix(salt)), mix = the SplitMix64 output finalizer
 * (mix(0) = 0), so byte-identical bundles on the same (seed, slot) draw independent samples:
 * an identical-policy null. 0 (the default) is the unsalted stream exactly: a library that
 * never makes the call, or makes it with 0, is byte-identical to one without it. Kept across
 * pw_reset, applied from the next pw_reset and to policy seats installed after the call. The
 * world, its hash and pw_step are untouched. Returns 0, -1 for a nil handle. */
int pw_set_sampling_salt(void *handle, int64_t salt);
/* A hosted seat decides, and so draws, only on ticks it is alive on the pre-step world: a
 * probe that wants the hosted seat's exact draws calls pw_sample_actions for live seats only. */
/* Decoder objective forbid (additive; the hosted bundle option decoder.forbid_objectives).
 * pw_set_seat_forbid_objectives: the `count` movement-head indices (distinct, 0..50, fewer
 * than 51) are never selected for the seat by pw_sample_actions (argmax or draw, as if
 * their logits were -inf), and pw_step returns -3 without stepping when the caller hands
 * one of them for a live caller-driven seat; count 0 clears (indices may be NULL).
 * Kept across pw_reset; -1 bad args. pw_seat_forbidden_objectives: mask int32[51] (may be
 * NULL) gets 1 per forbidden index, 0 otherwise (the trainer's logit mask); returns the
 * count, -1 bad args. No seat forbidding anything = byte-identical to before. */
int pw_set_seat_forbid_objectives(void *handle, int seat, const int32_t *indices, int32_t count);
int pw_seat_forbidden_objectives(void *handle, int seat, int32_t *mask);
/* pw_seat_spray_stats (training library only): int32[4] = {enemy damage, teammate damage,
 * enemy kills, teammate kills} dealt by the seat's spray since the last create/reset. */
int pw_seat_spray_stats(void *handle, int seat, int32_t *stats);
/* pw_seat_weapon_stats (training library only): int32[9] per seat, cumulative since the last
 * create/reset, attributed to the damage's owner, enemy victims only: {gun kills, grenade kills,
 * spray kills, hits from water, hits from high ground, hits from a trench, hits to water, hits
 * to high ground, hits to a trench}. A hit is every enemy damage event past the shield and life
 * checks (pw_seat_stats' hits_enemy event), any weapon; the kill kinds sum to pw_seat_stats'
 * kills and spray kills equal pw_seat_spray_stats[2]. "From" is the shooter's position at the
 * damage event, "to" the victim's: water = in the river's water (rules >= 30, as the wading
 * slowdown), high = terrainHeight >= 216, trench = inside a trench; classes may overlap. Pure
 * telemetry, never part of the world or its hash; -1 bad args. */
int pw_seat_weapon_stats(void *handle, int seat, int32_t *stats);
/* Training telemetry (training library only; pure reads, cumulative since the last
 * create/reset). pw_seat_grenade_stats: int32[6] = {throws released, enemy hits, enemy
 * kills (= weapon_stats[1]), enemy health removed, teammate hits, teammate health removed}.
 * pw_seat_equip_stats: int32[8] = {armor, uniform, medkit, grenade, spray pickups, health
 * the seat's armor soaked, ticks ended disguised, enemy kills + heart captures made while
 * disguised}. pw_heart_terrain: one int32 per control heart, bit 0 = in water, bit 1 =
 * water within one step (16 samples at 50/100 units); writes min(hearts, capacity) and
 * returns the heart count. Each: -1 bad args. */
int pw_seat_grenade_stats(void *handle, int seat, int32_t *six);
int pw_seat_equip_stats(void *handle, int seat, int32_t *eight);
int pw_heart_terrain(void *handle, int32_t *output, int32_t capacity);
/* World snapshots (training library only). pw_world_save: the handle's whole match state as one
 * versioned, deterministic blob (world, per-seat settings and streams, BASIC seats' runtime state,
 * decoders, telemetry; ends with a sha256 trailer); returns its size and writes it only when
 * capacity >= size (capacity 0 sizes it); a pure read; -1 bad args. A policy network's recurrent
 * state is the caller's. pw_world_load: replaces the handle's match state with a blob from the same
 * build, observation version and seat count; 0, -1 bad args, -2 another format / build / handle
 * shape, -3 corrupt or truncated; a refused load leaves the handle unchanged.
 * pw_world_load_error: the calling thread's last refusal reason, NUL-terminated; returns its length. */
int64_t pw_world_save(void *handle, void *output, int64_t capacity);
int pw_world_load(void *handle, const void *data, int64_t length);
int pw_world_load_error(char *output, int32_t capacity);
/* pw_seat_damage_taken_stats (training library only; pure read, cumulative since the last
 * create/reset): int32[8] = {hits, health lost} from enemy guns, enemy grenades, enemy spray,
 * and everything else (own / teammate weapon, map). The hit counts sum to pw_seat_stats'
 * hits_taken; health lost is after armor. -1 bad args. */
int pw_seat_damage_taken_stats(void *handle, int seat, int32_t *eight);
/* pw_seat_privileged_labels (TRAINING-ONLY supervision labels; training_labels.nim): float[21]
 * for the seat on the current pre-step world = {gun cooldown, gun windup, spray cooldown,
 * shield, respawn (ticks), aim x, aim z, own heart meter, enemy heart meter (scoreTicks; 0 in
 * FFA-kin), lead valid, lead x, lead z}: the lead is the retired contract-v2 formula for the
 * nearest visible enemy body (body + 6 * its last-step displacement - 5 * the seat's planned
 * step towards its current goal), then 9 traversable probes (the retired v1 cover probes: the
 * seat's position and the 8 compass points 200 units out, mirrored for team 1; 1 = inside the
 * map, not blocked and traversable from the seat). None of this is perceivable by a seat (docs/neural/
 * seat-view.md): use it only as auxiliary-loss targets, never as a policy input. The hosted
 * engine has no such call. 0, or -1 bad args. */
#define PW_PRIVILEGED_LABELS 21
int pw_seat_privileged_labels(void *handle, int seat, float *twenty_one);

/* pw_seat_state (training library only): float[16 * 8], per seat in seat order {x, z (world
 * units), hp, armor, lives, respawn (ticks until the seat respawns, 0 while alive), carrying (1 =
 * holds a heart), equipment bits (1 = grenade, 2 = spray can)}: every seat's public body state in
 * one call, for training-side critics. Pure read: the world and its hash are unchanged. -1 bad
 * args. */
int pw_seat_state(void *handle, float *sixteen_seats_times_eight);

/* pw_world_json (training library only): the whole world as one JSON object, {"rulesVersion": R,
 * "heard": {}, then every World field} -- the object the engine streamed to PW_POLICY_FD each tick
 * before seats stopped acting through the host (#51) -- for external controllers that plan from
 * world state and act through pw_set_seat_command. Returns the length in bytes and writes the JSON
 * (no NUL) only when capacity >= length, so capacity 0 sizes the buffer. Pure read: the world and
 * its hash are unchanged. -1 bad args. */
int pw_world_json(void *handle, char *output, int32_t capacity);

/* pw_elevation (training library only): the ground height at (x, z) in this handle's world
 * (sim.elevation: terrain plus world features), for controllers that raster line of sight from
 * pw_world_json. Pure read; -1000000 for a nil handle. */
int pw_elevation(void *handle, int32_t x, int32_t z);
/* Observation contract selection. pw_create_observation is pw_create with the observation
 * contract chosen, kept across pw_reset: 201 = teams.view.1 "paintbot-pw.teams.view.1"
 * (identical to pw_create; 512 floats; the teams game only: pw_set_game_mode refuses FFA-kin
 * on the handle), 202 = ffa.view.1 "paintbot-pw.ffa.view.1" (FFA-kin at any seat count; see
 * below), 203 = teams.view.1h "paintbot-pw.teams.view.1h" (teams.view.1's 512 floats, then a 100-float RAW
 * motion-history block the engine keeps per seat: per identity t-1 / t-2 displacement relative to its current
 * position in 28 u steps plus seen flags, then the seat's own t-1 / t-2 displacement; 612 floats; the teams game only;
 * pw_create_observation_inputs_v(..., 203, K) adds K user inputs, "paintbot-pw.teams.view.1hu<K>"; pw_reset starts
 * every history over, pw_world_save / pw_world_load carry it). neural_contract.nim encodeTeamsView / encodeTeamsViewH / encodeFfaView
 * document every column; each
 * is computed from the seat's SeatView. NULL for any other version (1, 2, 3, 101 and 102
 * were retired for BASIC parity) or a bad max_ticks. pw_observe / pw_observe_seats rows are
 * then that many floats apart. pw_observation_size() = 512; pw_observation_size_for(201) =
 * 512, (203) = 612 (-1 otherwise, 202 included: its width follows the match); pw_handle_observation_size
 * and pw_observation_contract read a handle (-1 for NULL); pw_observation_contract_hash
 * writes the 64-hex SHA-256 an actor and manifest carry (NUL-terminated, capacity >= 65;
 * 0, or -1 bad args). */
void *pw_create_observation(int32_t seed, int32_t max_ticks, int32_t obs_version);
int pw_observation_size_for(int32_t obs_version);
int pw_handle_observation_size(void *handle);
int pw_observation_contract(void *handle);
int pw_observation_contract_hash(int32_t obs_version, char *sixty_five_bytes, int32_t capacity);
/* Neural BASIC I/O, training side.
 * pw_create_observation_inputs: observation contract teams.view.1u<K>
 * "paintbot-pw.teams.view.1u<K>" (K = user_inputs, 1..256; 0 = pw_create): every pw_observe
 * row is teams.view.1's 512 floats followed by K floats, a policy seat's user inputs as its
 * policy.bas left them (float32(v) / 1000: what its next decision's observation reads),
 * zeros for every other seat. pw_handle_user_inputs = the handle's K;
 * pw_handle_observation_size = 512 + K; pw_user_inputs_contract_hash writes the
 * teams.view.1u<K> SHA-256 (0, or -1 bad args). The _v forms name the base contract:
 * 201 as above, or 202 = ffa.view.1u<K> "paintbot-pw.ffa.view.1u<K>" (default off; K =
 * 1..256, 0 = pw_create_observation(..., 202)): every row is the match's ffa.view.1 floats,
 * byte for byte, followed by the same K user-input floats; pw_handle_observation_size and
 * pw_observation_layout's row floats = the layout's size + K (the sections are unchanged);
 * pw_net_load_layout resolves the input count to the layout's size + K. Any other
 * obs_version: NULL / -1.
 * pw_set_seat_policy_script: the seat runs a bundle's policy.bas under its manifest.json
 * exactly as the hosted neural seat does (selection options, user inputs, action contract;
 * the seat's own sampling stream from the match seed and slot), with no actor:
 * run_neural_net yields the seat's row of the logits passed to pw_step_logits. The
 * manifest's observation_contract must be the handle's. Rebuilt on pw_reset; length 0
 * removes it; pw_set_seat_script on the seat replaces it. Per-seat selection setters do not
 * apply to it. 0 running, 1 compile failed, 2 manifest rejected (text in
 * pw_seat_script_status), -1 bad args. While any policy seat is installed pw_step and
 * pw_script_decide return -4.
 * pw_step_logits: pw_step with logits = float[n * logits per seat] in seat order (only
 * policy seats' rows are read). Logits per seat is the handle's action contract's (82; 128 / 174
 * under contracts 13 / 14). A policy seat whose own manifest contract is narrower reads the leading
 * logits of its row, so contracts 11, 13 and 14 can share a handle set to the widest of them
 * (pw_seat_policy_extra_choices then reports zeros for a seat without extra heads). The trainer runs the actor on the seat's pw_observe row every
 * tick the seat is alive, its recurrent state cleared as the host clears it (dead, alive
 * after a death, new match).
 * pw_seat_policy_choices: int32[22] of the last step = {decided, selected[5], final[5],
 * temperature_milli[5], mask0 bits 0..31, mask0 bits 32..50, mask1, mask2, mask3, mask4}:
 * decided = the script selected this step (neuralSample); selected = the heads drawn under
 * the applied masks and temperatures (the trainer's log-probability target); final = the
 * choices after the script's neuralSetChoice calls; temperature 0 = argmax; mask bit i =
 * choice i excluded. -1 bad args or not a policy seat. */
void *pw_create_observation_inputs(int32_t seed, int32_t max_ticks, int32_t user_inputs);
int pw_handle_user_inputs(void *handle);
int pw_user_inputs_contract_hash(int32_t user_inputs, char *sixty_five_bytes, int32_t capacity);
void *pw_create_observation_inputs_v(int32_t seed, int32_t max_ticks, int32_t obs_version, int32_t user_inputs);
int pw_user_inputs_contract_hash_v(int32_t obs_version, int32_t user_inputs, char *sixty_five_bytes,
    int32_t capacity);
int pw_set_seat_policy_script(void *handle, int seat, const char *bas, int32_t bas_len,
    const char *manifest_json, int32_t manifest_len);
int pw_step_logits(void *handle, const int32_t *actions, const float *logits, float *rewards,
    float *terminals);
int pw_seat_policy_choices(void *handle, int seat, int32_t *twenty_two);
/* pw_seat_policy_offset_choices: a policy seat's aim-offset heads (action contract 13) on the
 * last pw_step_logits, int32[6] = {selected5, selected6, final5, final6, temperature_milli5,
 * temperature_milli6}; zeros when the seat did not select. -1 bad args, not a policy seat, or
 * not exactly the two aim-offset heads (under 14 use pw_seat_policy_extra_choices).
 * pw_seat_policy_extra_choices: a policy seat's extra heads 5 .. 8 (13: aim offsets; 14: aim
 * then movement offsets), int32[12] = {selected5..8, final5..8, temperature_milli5..8}; zeros
 * for heads the contract lacks and when the seat did not select. -1 bad args, not a policy
 * seat, or no extra heads.
 * pw_set_seat_conditionals: a policy seat's COND_HEAD layers held by the trainer: count pairs
 * (condition head, re-selected head) in heads[2 * count], their weights (size(head) x
 * size(condition head), row-major) concatenated in that order; replaces the seat's previous
 * ones from its next selection, kept across pw_reset (count 0 clears). A zero weight column
 * takes no draw. 0; -1 bad args or not a policy seat; -2 against COND_HEAD's rules (or with
 * decoder.joint_sampling). */
int pw_seat_policy_offset_choices(void *handle, int seat, int32_t *six);
int pw_seat_policy_extra_choices(void *handle, int seat, int32_t *twelve);
/* pw_seat_policy_extra_choices2: the same for up to five extra heads (heads 5 .. 9, action contract 16 raw), fifteen
 * int32 {selected5..9, final5..9, temperature_milli5..9}; pw_seat_policy_extra_choices returns -1 for such a seat. */
int pw_seat_policy_extra_choices2(void *handle, int seat, int32_t *fifteen);
int pw_set_seat_conditionals(void *handle, int seat, int32_t count, const int32_t *heads,
                             const float *weights, int32_t weight_count);
/* Diagnostic: resident 64x64 terrain-cache blocks (16 KiB each) in this process. */
int pw_terrain_cache_blocks(void);
/* Terrain table of the handle's rules and map (shared by every handle and thread of the process
 * that agree): pw_terrain_prewarm computes the blocks covering the world bounds now (~30 s for
 * the island) and returns how many; pw_terrain_cache_save writes the computed blocks to path
 * (replaced atomically); pw_terrain_cache_load maps such a file read-only (shared across
 * processes through the page cache) and returns the blocks installed, or -1 when the file is
 * missing or was written for another game build, rules or map. All return 0 on a generated map
 * (never tabled) and -1 for a nil argument; none changes world state. */
int pw_terrain_prewarm(void *handle);
int pw_terrain_cache_save(void *handle, const char *path);
int pw_terrain_cache_load(void *handle, const char *path);
/* Neural actors (additive): the hosted seat's own loader and inference (neural_actor.nim)
 * for a model.bin in PWNET001 or PWNET002 format, so a trainer or evaluator runs a bundle's
 * network bit for bit as the hosted seat does. pw_net_load validates like the host and
 * refuses a model over the 4,000,000 operations per seat per tick budget; NULL on
 * rejection with the reason in error (NUL-terminated, truncated to capacity; may be NULL).
 * pw_net_info writes eight int64 {format 1|2, inputs, outputs, recurrent state floats,
 * heads, layers, parameters, operations per inference}; pw_net_head_sizes writes the head
 * sizes and returns their count; pw_net_contracts writes "<obs sha256> <action sha256>"
 * (capacity >= 130). pw_net_infer reads `inputs` observation floats and the state (every
 * MINGRU layer's state in layer order), updates the state in place and writes `outputs`
 * logits: 0, -1 bad arguments, -2 inference failed (nonfinite), state and logits untouched.
 * Reset convention = the hosted seat's: zero the whole state at initial use, match reset,
 * death and respawn (pw_observe's state_resets). One call at a time per net handle. */
void *pw_net_load(const void *data, int64_t length, char *error, int32_t capacity);
void pw_net_destroy(void *net);
int pw_net_info(void *net, int64_t *eight);
int pw_net_head_sizes(void *net, int32_t *sizes, int32_t capacity);
int pw_net_contracts(void *net, char *out, int32_t capacity);
int pw_net_infer(void *net, const float *observation, float *state, float *logits);
/* FFA-kin (mode "ffa_kin"; additive). With none of these called a handle plays the teams
 * game byte for byte as before.
 * pw_set_game_mode: 0 teams (default), 1 FFA-kin; pw_set_kin_layout: -1 drawn from the seed
 * (default), 0 fours, 1 pairs, 2 trios + loner, 3 cousins, 4 strangers, 5 clones. Both are
 * kept across pw_reset and applied at the NEXT pw_reset (the current world keeps its
 * mode); pw_game_mode reads the current world's mode (-1 NULL).
 * In FFA, pw_step pays every seat, dead ones included, its kin-weighted score change each
 * tick: (R_i(t) - R_i(t-1)) / 4320, R_i = sum_j r_ij s_j in points (s_j raw score), so a
 * match's rewards sum to R_i / 4320. The teams reward is unchanged.
 * Fog of war (rules 48, pw_set_rules(h, 48) or later): the agent-facing observations
 * (pw_observe*, and what policy seats read) never show a cog the observing seat cannot see:
 * ffa.view.1 carries only the agents the seat sees, and every seat's BASIC kin / gene /
 * seatScore / seatAlive read -1 for it. The reads below are PRIVILEGED trainer/eval reads of
 * the whole match (reward and logging), unmasked at every rules: never feed them to a policy.
 * Reads (current world): pw_kin float[256] r(i,j) at [16i+j] (zeros in teams);
 * pw_genes uint32[16]; pw_scores float[16] = results.scores (R_i in FFA);
 * pw_reward_split float[32] = {own_i, kin_i} per seat for the last step in reward units,
 * own = r_ii ds_i / 4320, kin = sum_{j!=i} r_ij ds_j / 4320, own + kin = the step's reward;
 * pw_kin_seat_stats float[48] = {death_tick (-1 alive), own-part return, kin-part return}
 * per seat, cumulative since create/reset.
 * pw_pair_stats int32[16*16*PW_PAIR_STAT_COUNT], cumulative since create/reset, at
 * [(16i + j) * 13 + stat] = i's count about j; telemetry outside the world, never hashed,
 * zero in teams. KinWindow = 72 ticks, near = 400 units:
 *   0 visible: ticks i could see j (both alive)      1 in_range: ... and within gun range (2000 in FFA)
 *   2 damage: health i removed from j                3 kills: kills of j by i
 *   4 defend: health i removed from a cog that removed health from j in the last 72 ticks
 *     (every "last 72 ticks" window is exclusive: 0 <= now - then < 72)
 *   5 defend_opp: ticks such an attacker of j (alive, not i) was visible to i (j alive)
 *   6 yield_opp: ticks j was capturing a heart uncontested and i was within 400 of it
 *   7 contest: ticks i stood in the capture zone (140) of a heart j was capturing (a
 *     capture paused by i's presence still names j as capturer)
 *   8 near: ticks the pair was within 400 (both alive)
 *   9 co_capture: great-heart captures i and j shared
 *  10 costly_defend: the part of defend dealt while i was in its last third of health
 *     (hp * 3 <= max hp, max hp 10 in FFA)
 *  11 death_after_defend: i died within 72 ticks of a defend event for j
 *  12 heart_pass: hearts whose ownership went directly from j to i
 * Eval-only overrides (training library only; hosted play cannot reach them):
 * pw_set_spawn_grouping int8[16] spawn groups (0..15, -1 alone) independent of the
 * kinship, NULL clears; pw_set_kin_override an exact kinship: family int8[16] (-1..15),
 * genes uint32[16], ibd int8[256] (0..32, symmetric, 32 on the diagonal; r = ibd/32),
 * family NULL clears, wins over the layout (the override's layout is a label only). The engine
 * reads the ibd matrix (the FFA territory boost, sim.territoryBoost) but never the genes. Both apply at the NEXT pw_reset and stay until
 * cleared. pw_set_obs_mask: bit 0 zeroes every kin column of ffa.view.1 (the genes-only
 * ablation; the territory-boost header column too), read
 * by the next pw_observe, kept across resets;
 * other bits rejected. pw_set_pair_stats_enabled(h, 0/1): pair counters off/on (default
 * on; off skips their per-tick work, from the next pw_step, kept across resets); the
 * reward, its split, the returns and death ticks are always kept.
 * All return 0, or -1 bad args. */
#define PW_PAIR_STAT_COUNT 13
int pw_set_game_mode(void *handle, int32_t mode);
int pw_game_mode(void *handle);
int pw_set_kin_layout(void *handle, int32_t layout);
int pw_kin(void *handle, float *two_fifty_six);
int pw_genes(void *handle, uint32_t *sixteen);
int pw_scores(void *handle, float *sixteen);
int pw_reward_split(void *handle, float *thirty_two);
int pw_kin_seat_stats(void *handle, float *forty_eight);
int pw_pair_stats(void *handle, int32_t *sixteen_sixteen_thirteen);
int pw_set_spawn_grouping(void *handle, const int8_t *sixteen);
int pw_set_kin_override(void *handle, const int8_t *family_sixteen, const uint32_t *genes_sixteen,
                        const int8_t *ibd_two_fifty_six);
int pw_set_obs_mask(void *handle, uint32_t flags);
int pw_set_pair_stats_enabled(void *handle, int32_t enabled);
/* Maps (additive; training library only). With pw_set_map never called a handle plays the
 * rules' own island byte for byte as before. pw_map_count: the number of maps; pw_map_name
 * writes map `index`'s name NUL-terminated ("" for -1, the island; capacity 32 always holds
 * one): 0, or -1 bad args. pw_set_map: -1 the rules' own island (default), 0 ..
 * pw_map_count()-1 a map; kept across pw_reset and applied at the NEXT pw_reset (the current
 * world keeps its map), 0 or -1 bad args. pw_map: the current world's map (-1 the island, -2
 * NULL). Each handle carries its own map, so handles on one thread may play different maps;
 * every call on a handle installs that handle's map for the calling thread. A handle on map
 * m plays exactly the world the hosted game builds with map m under the library's rules. */
int pw_map_count(void);
int pw_map_name(int32_t index, char *out, int32_t capacity);
int pw_set_map(void *handle, int32_t index);
int pw_map(void *handle);
/* Rules and game config (additive; training library only). With neither called a handle plays
 * NativeRules (40) with the default awards byte for byte as before. pw_rules_latest: the rules
 * live games play. pw_set_rules: NativeRules .. pw_rules_latest(), 0 or -1 bad args; pw_rules:
 * the current world's (-1 NULL). pw_set_config_json takes a whole Coworld game config object
 * (a manifest variant's game_config, verbatim; not NUL-terminated, `length` bytes) and reads it
 * with the host's parser: mode, kin_layout, glory, map, vision, vision_range (metres of per-cog
 * sight, 1..200; absent = unlimited; not with "vision": "team"), each absent key the host's
 * default except "map": a config without "map" keeps the handle's map (pw_set_map's or an
 * earlier config's), so maps can be drawn per reset under one config; "map": "" is the island;
 * tokens, players, slots, seed and max_ticks are accepted and ignored (seats and match
 * length come from this ABI). It replaces the handle's mode, kin layout, map, vision, vision
 * range and glory awards. 0; -1 bad args; -2 a config the host would refuse (or an FFA-kin config on an
 * observation contract v3 handle), its reason written to `error`
 * (NUL-terminated, truncated to capacity, "" on success, may be NULL). Rules and config are
 * kept across pw_reset and apply at the NEXT pw_reset; the current world keeps its own. Each
 * handle carries its own, so handles on one thread may play different rules and configs. At
 * pw_rules_latest() with a variant's game_config a handle plays that variant's hosted world. */
int pw_rules_latest(void);
int pw_set_rules(void *handle, int32_t version);
int pw_rules(void *handle);
int pw_set_config_json(void *handle, const char *json, int32_t length, char *error, int32_t capacity);
/* Observation contract ffa.view.1 and N-seat handles.
 * pw_create_observation(seed, max_ticks, 202): observation contract ffa.view.1
 * "paintbot-pw.ffa.view.1", FFA-kin at any seat count: a 24-float header (the seat's own
 * state and match constants), then the cog section (min(seats - 1, 64) rows of 44 floats:
 * exactly the seat's nearAgents(20000) list, nearest first, ties by identity; every row after
 * it all zero), the control heart section (one 12-float row per heart, nearest first) and the
 * great heart section (2 rows of 12). Column 0 of every row is its valid flag. The row width
 * follows the match, so read pw_handle_observation_size after each reset.
 * pw_set_seats(h, n): the seat count from the NEXT pw_reset on, 2..256; n != 16 needs a 202
 * handle (-1 otherwise). Kept across resets; a reset that changes the count re-creates every
 * per-seat setting at its default (knobs, scripts and policy seats removed). pw_seats(h): the
 * current world's count (-1 NULL). Every per-seat buffer follows it: pw_observe rows,
 * pw_step actions n*5 / rewards n / terminals n, pw_kin n*n at [n*i+j], pw_genes n,
 * pw_scores n, pw_reward_split 2n, pw_kin_seat_stats 3n, pw_pair_stats n*n*13,
 * pw_seat_stats 8n, pw_seat_state 8n. The eval overrides pw_set_spawn_grouping and
 * pw_set_kin_override apply to 16-seat worlds only; pw_bot_actions returns -1 in FFA-kin.
 * pw_observation_layout(h, int32[16]): [row floats, header floats, cog offset, cog rows, cog
 * width, heart offset, heart rows, heart width, great offset, great rows, great width, valid
 * column, seats, control hearts, 0, 0] for the current world (teams.view.1: [row floats, row
 * floats, 0 x 9, -1, seats, control hearts, 0, 0]). pw_observation_rows(h, seat, int32 *out,
 * capacity): the seat's row -> entity map for the observation pw_observe writes before the
 * next pw_step: the cog rows' identities (-1 past the agents seen), then the heart rows'
 * control heart indices, then the 2 great heart indices; returns that count and writes only
 * when capacity holds it; -1 bad args or not a 202 handle.
 * Action contract ffa.view.1 pointer: the five heads are sized by the current world:
 * pw_action_layout(h, int32[8]) = [5, 11 + control hearts, 9 + cog rows, 2, 2, 2, logits per
 * seat, 0] (teams.view.1: [5, 51, 25, 2, 2, 2, 82, 0]). pw_step's caller heads are decoded
 * by players/neural_decode_ffa.bas (objective 9 + k = control heart row k, 9 + H + g = great
 * heart row g; aim 9 + k = cog row k). Forbid masks do not apply under it;
 * pw_step_logits' logits are n rows of pw_action_layout's width; pw_sample_actions returns
 * -1 under it.
 * pw_net_load_layout(h, data, length, error, capacity): pw_net_load with the model's PWNET002
 * layout words resolved against the 202 handle's current layout and action heads, and the
 * budget of its seat count (4,000,000 x seats / 16 above 16 seats); NULL with the reason in
 * `error` otherwise (a handle that is not 202 included). */
#define PW_OBSERVATION_LAYOUT_WORDS 16
int pw_set_seats(void *handle, int32_t seats);
int pw_seats(void *handle);
int pw_observation_layout(void *handle, int32_t *sixteen);
int pw_observation_rows(void *handle, int32_t seat, int32_t *out, int32_t capacity);
int pw_action_layout(void *handle, int32_t *eight);
void *pw_net_load_layout(void *handle, const void *data, int64_t length, char *error, int32_t capacity);
#ifdef __cplusplus
}
#endif
#endif
