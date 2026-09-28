const assert = require('node:assert/strict');
const kin = require('../coworld/paintbot/kinhud.js');

// Two sibling pairs (families 0 and 1, cousins of each other), one loner (seat 4), the rest a
// third family. rPct is round(100 r); seatScore etc. are in tenths.
const family = [0, 0, 1, 1, -1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2];
const rPct = Array.from({length: 16}, (_, i) => Array.from({length: 16}, (_, j) => {
  if (i === j) return 100;
  if (family[i] < 0 || family[j] < 0) return 0;
  if (family[i] === family[j]) return 50;
  if (family[i] <= 1 && family[j] <= 1) return 25;
  return 0;
}));
const seatScore = Array(16).fill(0);
seatScore[0] = 100; seatScore[1] = 300; seatScore[2] = 40; seatScore[4] = 500; seatScore[9] = 20;
const heartSeconds = Array(16).fill(0); heartSeconds[1] = 24; heartSeconds[4] = 50;
const greatShare = Array(16).fill(0); greatShare[1] = 60; greatShare[0] = 60;
const cogs = Array.from({length: 16}, (_, i) => ({hp: i === 1 || i === 9 ? 0 : 3}));
const state = {
  mode: 'ffa_kin', family, rPct,
  kinHue: family.map(f => f < 0 ? -1 : f * 90),
  world: {
    tick: 480, cogs, seatScore, heartSeconds, greatShare,
    controlHearts: [{owner: 4}, {owner: 4}, {owner: 0}, {owner: -1}],
    greatHearts: [
      {pos: {x: 0, z: 0}, progress: 60, dormantUntil: 0, present: 3},
      {pos: {x: 1, z: 1}, progress: 0, dormantUntil: 480 + 24 * 42 - 5, present: 1},
    ],
  },
};

assert.equal(kin.isFfa(state), true);
assert.equal(kin.isFfa({mode: 'teams'}), false);
assert.equal(kin.isFfa(null), false);

// R_i = sum_j r_ij s_j in points.
assert.equal(kin.kinScore(state, 0), 10 + 0.5 * 30 + 0.25 * 4);  // self + sibling + cousin
assert.equal(kin.kinScore(state, 4), 50);                         // a loner counts only itself
assert.equal(kin.kinScore(state, 5), 0.5 * 2);                    // sibling 9 (dead) still counts

const rows = kin.cogRows(state);
assert.equal(rows.length, 16);
for (let i = 1; i < rows.length; i++) assert.ok(rows[i - 1].R >= rows[i].R, 'sorted by R');
assert.deepEqual(rows.slice(0, 3).map(r => r.seat), [4, 1, 0]);
const r1 = rows.find(r => r.seat === 1);
assert.deepEqual({s: r1.s, heartSec: r1.heartSec, great: r1.great, held: r1.held, dead: r1.dead, family: r1.family, hue: r1.hue},
  {s: 30, heartSec: 24, great: 6, held: 0, dead: true, family: 0, hue: 0});
assert.equal(rows.find(r => r.seat === 1).R, 30 + 0.5 * 10 + 0.25 * 4);
assert.equal(rows.find(r => r.seat === 4).held, 2);
assert.equal(rows.find(r => r.seat === 4).hue, -1);
assert.equal(rows.find(r => r.seat === 0).dead, false);
// Ties break by raw score then seat.
const tied = rows.filter(r => r.R === 0).map(r => r.seat);
assert.deepEqual(tied, [...tied].sort((a, b) => a - b));

const chips = kin.familyChips(state);
assert.equal(chips.length, 4); // three families + one loner
assert.deepEqual(chips.map(c => [c.family, c.score]), [[-1, 50], [0, 40], [1, 4], [2, 2]]);
assert.equal(chips[0].seat, 4);
assert.deepEqual(chips[1].members, [0, 1]);
assert.equal(chips[1].alive, 1);
assert.equal(chips[3].members.length, 11);
assert.equal(chips[3].alive, 10);
for (let i = 1; i < chips.length; i++) assert.ok(chips[i - 1].score >= chips[i].score);

const great = kin.greatStatus(state);
assert.deepEqual(great[0], {index: 0, state: 'charging', present: 3, quorum: 3, progress: 0.5, secondsLeft: 0});
assert.equal(great[1].state, 'dormant');
assert.equal(great[1].secondsLeft, 42);
assert.equal(kin.greatText(great[0]), '3/3 · 50%');
assert.equal(kin.greatText(great[1]), 'dormant 42s');
state.world.tick = 480 + 24 * 42;
assert.equal(kin.greatStatus(state)[1].state, 'ready');
assert.equal(kin.greatText(kin.greatStatus(state)[1]), 'ready · 1/3');
// Decaying charge below quorum still reads as charging.
state.world.greatHearts[0].present = 1;
assert.equal(kin.greatStatus(state)[0].state, 'charging');

assert.equal(kin.kinLabel(0), '');
assert.equal(kin.kinLabel(50), '½');
assert.equal(kin.kinLabel(25), '¼');
assert.equal(kin.kinLabel(100), '1');
assert.equal(kin.kinColor(-1), 'rgba(150,155,160,1)');
assert.equal(kin.kinColor(120, 0.5), 'hsla(120,80%,58%,0.5)');

const result = kin.matchResult(state, i => `Bot ${i + 1}`);
assert.equal(result.top.seat, 4);
assert.match(result.text, /Match ended · top cog Bot 5 \(R 50\.0\) · top loner 5 \(50\.0\)/);

console.log('Paintbot FFA-kin HUD sorting, family sums, dead flags, great hearts and R maths passed');
