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
/* Diagnostic: resident 64x64 terrain-cache blocks (16 KiB each) in this process. */
int pw_terrain_cache_blocks(void);
#ifdef __cplusplus
}
#endif
#endif
