#ifndef PAINTBOT_PW_NATIVE_ENV_H
#define PAINTBOT_PW_NATIVE_ENV_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Fixed v1 buffers: 16 seats, 448 floats/seat, 5 int32 actions/seat.
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
/* Diagnostic: resident 64x64 terrain-cache blocks (16 KiB each) in this process. */
int pw_terrain_cache_blocks(void);
#ifdef __cplusplus
}
#endif
#endif
