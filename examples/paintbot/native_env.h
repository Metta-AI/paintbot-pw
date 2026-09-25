#ifndef PAINTBOT_PW_NATIVE_ENV_H
#define PAINTBOT_PW_NATIVE_ENV_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* v1 buffers: 16 seats, 448 floats/seat (observation contract v1; a handle from
 * pw_create_observation(..., 2) writes 506), 5 int32 actions/seat.
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
 * -1 bad arguments. Worlds without scripts are byte-identical to before. */
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
 * action heads are neither decoded nor checked against its forbid mask (no decoder option
 * runs for it and its contract-v2 aim memory is not recorded); a scripted seat's script
 * still runs but its order is replaced. The fire hold and fire period apply only if already
 * set on the seat (off by default). pw_seat_orders echoes the executed command (an
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
 * pw_set_seat_damage_scale: damage dealt BY the seat is scaled by permille/1000 with
 * floor rounding (a 1-point gun hit deals 0 below 1000; grenade 2/6 and spray 3 step
 * down), the hit itself still lands (shield, cooldown relief, telemetry and friendly-fire
 * glory as before). 1000 is exact. Returns 0, -1 bad args. */
int pw_set_seat_fire_period(void *handle, int seat, int32_t period);
int pw_set_seat_damage_scale(void *handle, int seat, int32_t permille);
/* Action contract selection (additive to v1). pw_set_action_contract chooses how the
 * caller's actions (and the Nim bot's, and an override-mapped scripted seat's) are
 * decoded: 1 = contract v1 "paintbot-pw.rules37.action.v1.51-25-2-2-2" (an identity aim
 * is the body's current position; the default, byte-identical to a library without this
 * call), 2 = contract v2 "paintbot-pw.rules37.action.v2.51-25-2-2-2" (an identity aim is
 * the body's lead-compensated aim point: body + 6*u - 5*v with u the body's last-tick
 * displacement as the seat itself could observe it (zero on a first tick, gap, respawn
 * or teleport) and v the move the seat's own movement/sneak heads order this tick; see
 * neural_contract.nim). Same head sizes; movement, directional aim, fire, grenade and
 * sneak decode identically. Kept across pw_reset; the per-seat one-tick aim memory v2
 * reads is cleared here and by every reset, and, as the hosted seat clears it
 * (neural_host.beginTick), on every decided tick the seat is dead or alive after a tick it
 * was dead (so a respawned seat's first leads are the hosted seat's).
 * Returns 0, -1 for a bad handle or version.
 * pw_action_contract returns the selected version.
 * pw_action_contract_hash writes the 64-hex SHA-256 an actor and manifest must carry to
 * be decoded under that version (NUL-terminated, capacity >= 65). */
int pw_set_action_contract(void *handle, int32_t version);
int pw_action_contract(void *handle);
int pw_action_contract_hash(int32_t version, char *sixty_five_bytes, int32_t capacity);
/* Demonstration-mapping diagnostic: the point every movement head index (51 x {x, z})
 * and aim head index (25 x {x, z}) resolves to for the seat on the current pre-step
 * world under the selected contract, exactly as the coming pw_step would decode it
 * (a v2 identity aim depends on the movement and sneak head indices given, through the
 * seat's planned move). Index 0 is the seat's position / current aim. Candidates that do not exist now
 * (missing heart, unavailable or unseen pickup, identity nobody visible carries) and
 * every entry of a dead seat are INT32_MIN in both coordinates. Reads only. */
int pw_action_candidates(void *handle, int seat, int32_t movement, int32_t sneak,
                         int32_t *goals_51x2, int32_t *aims_25x2);
/* Mapping-ceiling diagnostics (pw-bc). pw_script_decide runs the scripted seats'
 * decision for the current tick now (once; later calls before the next pw_step are
 * no-ops) so pw_seat_orders reports the orders the coming pw_step will execute; with
 * every override mask 0 the world is byte-identical whether or not it is called.
 * Returns 1 decided, 0 nothing to do, -1 bad handle. pw_set_seat_override makes a
 * scripted seat execute the caller's decoded action for the masked heads instead of its
 * script's order (bits: 1 walk/goal/direct, 2 aim, 4 shoot, 8 grenade, 16 sneak; 0 =
 * exact script play); the script still runs and reports its orders. Kept across
 * pw_reset. Returns 0, -1 bad args. */
int pw_script_decide(void *handle);
int pw_set_seat_override(void *handle, int seat, int32_t mask);
/* Decoder fire hold (additive; the hosted bundle option decoder.fire_hold_teammates so
 * training and deployment agree). With enabled = 1 the seat's final shoot order on every
 * pw_step, whoever issued it (the caller's decoded action, the Nim bot, a script, an
 * override mix), is dropped when a teammate the seat can see (fog-gated, apparent team,
 * the gun's line-of-sight test) stands within the gun's hit tolerance (Radius = 55) of
 * the segment from the seat to the aim the order leaves and no farther along it than
 * the aim point; the aim, movement and every other head stand, so the network keeps
 * choosing fire and the decoder gates it. Action candidates and contract hashes are
 * untouched. 0 (the default) is byte-identical to a library without this call. Kept
 * across pw_reset. Returns 0, -1 bad args. pw_seat_fire_held: the orders held for the
 * seat since the last create/reset (telemetry; 0 with the hold off; -1 bad args). */
int pw_set_seat_fire_hold(void *handle, int seat, int32_t enabled);
int pw_seat_fire_held(void *handle, int seat);
/* Fire-hold radius (additive; decoder.fire_hold_teammates {"radius": r}).
 * pw_set_seat_fire_hold_radius(handle, seat, r) with r in 1..2000: the seat's hold
 * (pw_set_seat_fire_hold) tests teammates within r of the line of fire instead of 55; 0
 * restores 55 (the default; byte-identical). It does not turn the hold on. Kept across
 * pw_reset. Returns 0, -1 bad args. pw_seat_fire_hold_radius: the effective radius (55
 * unless set), -1 bad args. */
int pw_set_seat_fire_hold_radius(void *handle, int seat, int32_t radius);
int pw_seat_fire_hold_radius(void *handle, int seat);
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
/* A hosted seat decides, and so draws, only on ticks it is alive on the pre-step world: a
 * probe that wants the hosted seat's exact draws calls pw_sample_actions for live seats only. */
/* Decoder objective forbid (additive; the hosted bundle option decoder.forbid_objectives).
 * pw_set_seat_forbid_objectives: the `count` movement-head indices (distinct, 0..50, fewer
 * than 51) are never selected for the seat by pw_sample_actions (argmax or draw, as if
 * their logits were -inf), and pw_step returns -3 without stepping when the caller hands
 * one of them for a live seat whose actions it decodes; count 0 clears (indices may be NULL).
 * Kept across pw_reset; -1 bad args. pw_seat_forbidden_objectives: mask int32[51] (may be
 * NULL) gets 1 per forbidden index, 0 otherwise (the trainer's logit mask); returns the
 * count, -1 bad args. No seat forbidding anything = byte-identical to before. */
int pw_set_seat_forbid_objectives(void *handle, int seat, const int32_t *indices, int32_t count);
int pw_seat_forbidden_objectives(void *handle, int seat, int32_t *mask);
/* Decoder strafe legs (additive; the hosted bundle option decoder.strafe_legs, base.bas's
 * contact footwork). pw_set_seat_strafe with range > 0: on every pw_step while the seat sees
 * an apparent enemy within range and is not in a trench, the caller's movement index for it
 * is replaced by a compass leg (43..50) perpendicular to the nearest such enemy, turned 3/4
 * lateral plus the direction to the heart/pickup the caller's index names, held leg_min..
 * leg_max ticks, or shot_min..shot_max when a shoot order the gun can take starts it (a
 * ready shot with fewer than shot_min ticks left starts a new leg), reversing across the
 * line with probability reverse_permille/1000 per new leg; draws from the seat's own stream
 * seeded from the match seed and the slot exactly as the hosted seat seeds it. Defaults of
 * the bundle option: 5250, 3, 6, 6, 9, 800. range 0 = off (the default; byte-identical).
 * Kept across pw_reset (legs and stream reset); -1 bad args (1 <= leg_min <= leg_max <= 72,
 * 6 <= shot_min <= shot_max <= 72, range <= 20000, 0 <= permille <= 1000).
 * pw_seat_strafe_stats: int32[3] = {legs started, decisions replaced (since create/reset),
 * movement index executed on the last pw_step or -1 if the caller's stood}; -1 bad args. */
int pw_set_seat_strafe(void *handle, int seat, int32_t range, int32_t leg_min, int32_t leg_max,
                       int32_t shot_min, int32_t shot_max, int32_t reverse_permille);
int pw_seat_strafe_stats(void *handle, int seat, int32_t *stats);
/* Decoder aim snap (additive; the hosted bundle option decoder.aim_snap). pw_set_seat_aim_snap
 * with max_angle_millideg in 1..90000 (22500 = the bundle default 22.5 degrees): on every
 * pw_step a live caller-decoded seat's shoot order with a compass aim (17..24) takes the aim
 * index (1..16) of the apparent enemy identity it can see (fog-gated, apparent team) within
 * that angle of the compass heading, nearest in angle, then nearer body, then lower identity;
 * the identity candidate (contract v2: the lead aim point) is then what it aims at. Integer
 * geometry against threshold round(cos(angle) * 32768). 0 = off (the default; byte-identical).
 * Kept across pw_reset; -1 bad args. pw_seat_aim_snap_stats: int32[3] = {decisions snapped
 * (since create/reset), aim index executed on the last pw_step or -1 if the caller's stood,
 * the cosine threshold or 0 when off}; -1 bad args.
 * Decoder steady shot (additive; decoder.steady_shot). pw_set_seat_steady_shot(handle, seat,
 * 1): a live caller-decoded seat carrying the gun stands still (movement index 0) on the step
 * a shoot order the gun takes is decided (pre-step windup 0 and cooldown <= 1) and on every
 * step its windup runs (pre-step windup > 0), i.e. from the order until the ray leaves (six
 * decisions per shot; v2's own-drift term is then zero and true). 0 = off (the default;
 * byte-identical). Kept across pw_reset; -1 bad args or when the seat's forbid mask lists
 * index 0 (and pw_set_seat_forbid_objectives refuses index 0 while it is on).
 * pw_seat_steady_stats: int32[3] = {order ticks held, decisions held (since create/reset),
 * movement index executed on the last pw_step (0) or -1}; -1 bad args.
 * Order inside pw_step for one seat: aim snap, strafe, steady shot, decode, fire hold (a
 * steady-held step reports the strafe's executed index as -1). */
int pw_set_seat_aim_snap(void *handle, int seat, int32_t max_angle_millideg);
int pw_seat_aim_snap_stats(void *handle, int seat, int32_t *stats);
int pw_set_seat_steady_shot(void *handle, int seat, int32_t enabled);
int pw_seat_steady_stats(void *handle, int seat, int32_t *stats);
/* Decoder aim retarget (additive; the hosted bundle option decoder.aim_retarget).
 * pw_set_seat_aim_retarget(handle, seat, 1, max_range, hp_weight, carry_weight) with
 * max_range in 1..20000 and both weights in 0..1000000000 (5250, 160000, 2500000 = base.bas's
 * rule and the bundle defaults): on every pw_step a live caller-decoded seat's shoot order
 * with an identity or compass aim (1..24) takes the aim index (1..16) of the visible apparent
 * enemy identity (the observation's identity block: fog-gated, apparent team) minimising
 * d^2 - (3 - hp) * hp_weight - carrying * carry_weight among those with d <= max_range, d
 * measured from the seat to the identity's aim candidate exactly as pw_action_candidates
 * reports it for the step's movement and sneak heads (contract v2: the lead point); ties go
 * to the lower identity; none qualifies = the order stands. enabled 0 = off (the default;
 * byte-identical; the other arguments are then ignored). Kept across pw_reset; -1 bad args.
 * pw_seat_aim_retarget_stats: int32[3] = {decisions whose aim it replaced (since
 * create/reset), aim index executed on the last pw_step or -1 if the caller's stood,
 * max_range or 0 when off}; -1 bad args.
 * Decoder shot gate (additive; decoder.shot_gate). pw_set_seat_shot_gate(handle, seat,
 * max_range) with max_range in 1..20000 (5250 = the bundle default): on every pw_step a live
 * caller-decoded seat's shoot order, as it stands after the aim retarget and the aim snap,
 * becomes no shot when its aim is still a compass index (17..24; no snap configured, or no
 * enemy in the snap's cone), when the snap aimed it at an enemy whose body lies beyond
 * max_range, or when it is an identity aim whose aim candidate lies beyond max_range. A keep
 * aim (0), and an identity aim within range or that no visible body carries, pass (pw-diag3's
 * --shot-gate). A dropped decision keeps its pre-snap aim head, so the strafe, the steady
 * shot and the fire hold see a decision without a shot. 0 = off (the default;
 * byte-identical). Kept across pw_reset; -1 bad args. pw_seat_shot_gate_stats: int32[3] =
 * {shoot orders dropped (since create/reset), shoot head executed on the last pw_step (0) or
 * -1 if the caller's stood, max_range or 0 when off}; -1 bad args.
 * Order inside pw_step for one seat: aim retarget, aim snap, shot gate, strafe, steady shot,
 * decode, fire hold. */
int pw_set_seat_aim_retarget(void *handle, int seat, int32_t enabled, int32_t max_range,
                             int32_t hp_weight, int32_t carry_weight);
int pw_seat_aim_retarget_stats(void *handle, int seat, int32_t *stats);
int pw_set_seat_shot_gate(void *handle, int seat, int32_t max_range);
int pw_seat_shot_gate_stats(void *handle, int seat, int32_t *stats);
/* Decoder spray options (additive; decoder.spray_aim / decoder.spray_gate). Both act only on
 * a live caller-decoded seat's shoot order while it holds a READY spray can (sprayCooldown 0,
 * so the order starts a burst this step), and judge the cone that order would produce on the
 * pre-step world: the aim the decode gives the heads, the seat's position, mechanics.nim
 * sprayTouches' geometry, over the bodies the seat can see under their apparent teams.
 * pw_set_seat_spray_aim(handle, seat, max_range) with max_range in 1..850 (850 = default):
 * the aim head becomes the visible apparent enemy identity (within max_range + Radius, clear
 * line) whose cone holds the most apparent enemies (ties: nearer body, lower hp, lower
 * identity); when no candidate's cone holds an enemy the order stands. 0 = off (default).
 * pw_seat_spray_aim_stats: int32[3] = {orders re-aimed, aim index executed on the last step
 * or -1, max_range or 0}. pw_set_seat_spray_gate(handle, seat, max_teammates, min_enemies)
 * with max_teammates 0..7 and min_enemies 0..8 (0, 1 = defaults): the order is dropped unless
 * its cone holds >= min_enemies apparent enemies and <= max_teammates apparent teammates;
 * max_teammates -1 = off (default; min_enemies ignored). pw_seat_spray_gate_stats: int32[4] =
 * {orders dropped, shoot head executed on the last step (0) or -1, max_teammates or -1,
 * min_enemies or -1}. Both are kept across pw_reset; off on every seat is byte-identical;
 * -1 bad args. Order inside pw_step: aim retarget, aim snap, spray aim, shot gate (whose drop
 * also undoes the spray aim), spray gate, strafe, steady shot, decode, fire hold.
 * pw_seat_spray_stats (training library only): int32[4] = {enemy damage, teammate damage,
 * enemy kills, teammate kills} dealt by the seat's spray since the last create/reset (health
 * removed, armor first; attribution = the damage's owner during the spray burst). */
int pw_set_seat_spray_aim(void *handle, int seat, int32_t max_range);
int pw_seat_spray_aim_stats(void *handle, int seat, int32_t *stats);
int pw_set_seat_spray_gate(void *handle, int seat, int32_t max_teammates, int32_t min_enemies);
int pw_seat_spray_gate_stats(void *handle, int seat, int32_t *stats);
int pw_seat_spray_stats(void *handle, int seat, int32_t *stats);
/* Observation contract selection (additive). pw_create_observation is pw_create with the
 * observation contract chosen, kept across pw_reset: 1 = v1
 * "paintbot-pw.rules37.obs.v1.float448" (identical to pw_create), 2 = v2
 * "paintbot-pw.rules37.obs.v2.float506" = v1's 448 floats unchanged in columns 0..447,
 * then a 58-float public terrain block (self wet, self height; per heart 0..9 wet and
 * height delta; per apparent identity 0..15 wet and height delta, zero when v1's slot is
 * empty; visible apparent enemies wet/dry and teammates wet/dry, each /8; heights are
 * elevation/800; see neural_actor.md). NULL for any other version or a bad max_ticks.
 * pw_observe / pw_observe_seats rows are then that many floats apart. The contract never
 * touches the world or its hash. pw_observation_size() stays 448;
 * pw_observation_size_for(version) = 448 / 506 (-1 unknown); pw_handle_observation_size
 * and pw_observation_contract read a handle (-1 for NULL); pw_observation_contract_hash
 * writes the 64-hex SHA-256 an actor and manifest carry (NUL-terminated, capacity >= 65;
 * 0, or -1 bad args). */
void *pw_create_observation(int32_t seed, int32_t max_ticks, int32_t obs_version);
int pw_observation_size_for(int32_t obs_version);
int pw_handle_observation_size(void *handle);
int pw_observation_contract(void *handle);
int pw_observation_contract_hash(int32_t obs_version, char *sixty_five_bytes, int32_t capacity);
/* Neural BASIC I/O (PLAN-neural-basic-io), training side; every call additive, and a
 * handle that never uses them is byte-identical to one without them.
 * pw_create_observation_inputs: observation contract v2u<K>
 * "paintbot-pw.rules39.obs.v2u<K>" (K = user_inputs, 1..32; 0 = pw_create_observation(.., 2)):
 * every pw_observe row is v2's 506 floats followed by K floats, a policy seat's user inputs
 * as its policy.bas left them (float32(v) / 1000: what its next decision's observation
 * reads), zeros for every other seat. pw_handle_user_inputs = the handle's K;
 * pw_handle_observation_size = 506 + K; pw_user_inputs_contract_hash writes the v2u<K>
 * SHA-256 (0, or -1 bad args).
 * pw_set_seat_policy_script: the seat runs a bundle's policy.bas under its manifest.json
 * exactly as the hosted neural seat does (decoder options, sampling, user inputs, action
 * contract; the seat's own sampling and strafe streams from the match seed and slot), with
 * no actor: run_neural_net yields the seat's row of the logits passed to pw_step_logits.
 * The manifest's observation_contract must be the handle's. Rebuilt on pw_reset; length 0
 * removes it; pw_set_seat_script on the seat replaces it. Per-seat decoder setters do not
 * apply to it. 0 running, 1 compile failed, 2 manifest rejected (text in
 * pw_seat_script_status), -1 bad args. While any policy seat is installed pw_step and
 * pw_script_decide return -4.
 * pw_step_logits: pw_step with logits = float[16 * 82] in seat order (only policy seats'
 * rows are read). The trainer runs the actor on the seat's pw_observe row every tick the
 * seat is alive, its recurrent state cleared as the host clears it (dead, alive after a
 * death, new match).
 * pw_seat_policy_choices: int32[22] of the last step = {decided, selected[5], final[5],
 * temperature_milli[5], mask0 bits 0..31, mask0 bits 32..50, mask1, mask2, mask3, mask4}:
 * decided = the script selected this step; selected = the heads drawn under the applied
 * masks and temperatures (the trainer's log-probability target); final = the heads decoded
 * (-1 if never decoded); temperature 0 = argmax; mask bit i = choice i excluded. -1 bad args
 * or not a policy seat. */
void *pw_create_observation_inputs(int32_t seed, int32_t max_ticks, int32_t user_inputs);
int pw_handle_user_inputs(void *handle);
int pw_user_inputs_contract_hash(int32_t user_inputs, char *sixty_five_bytes, int32_t capacity);
int pw_set_seat_policy_script(void *handle, int seat, const char *bas, int32_t bas_len,
    const char *manifest_json, int32_t manifest_len);
int pw_step_logits(void *handle, const int32_t *actions, const float *logits, float *rewards,
    float *terminals);
int pw_seat_policy_choices(void *handle, int seat, int32_t *twenty_two);
/* Diagnostic: resident 64x64 terrain-cache blocks (16 KiB each) in this process. */
int pw_terrain_cache_blocks(void);
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
#ifdef __cplusplus
}
#endif
#endif
