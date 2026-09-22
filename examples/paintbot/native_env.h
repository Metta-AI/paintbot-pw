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
/* Diagnostic: resident 64x64 terrain-cache blocks (16 KiB each) in this process. */
int pw_terrain_cache_blocks(void);
#ifdef __cplusplus
}
#endif
#endif
