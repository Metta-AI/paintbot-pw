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
 * reads is cleared here and by every reset. Returns 0, -1 for a bad handle or version.
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
/* Diagnostic: resident 64x64 terrain-cache blocks (16 KiB each) in this process. */
int pw_terrain_cache_blocks(void);
#ifdef __cplusplus
}
#endif
#endif
