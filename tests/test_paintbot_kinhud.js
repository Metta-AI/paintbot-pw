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
// Hearts held now: loner 4 holds two, family 0 one (seat 0), the rest none; a family with a
// dead member still counts the living members' hearts.
assert.deepEqual(chips.map(c => c.hearts), [2, 1, 0, 0]);
assert.equal(chips[0].seat, 4);
assert.deepEqual(chips[1].members, [0, 1]);
assert.equal(chips[1].alive, 1);
assert.equal(chips[3].members.length, 11);
assert.equal(chips[3].alive, 10);
for (let i = 1; i < chips.length; i++) assert.ok(chips[i - 1].score >= chips[i].score);

// Chip text: alive/size badge, hearts and score; compact chips drop the separator.
assert.deepEqual(kin.chipText(chips[1]), {badge: '1/2', hearts: '♥1', score: '40', text: '♥1 · 40', out: false});
assert.equal(kin.chipText(chips[1], true).text, '♥1 40');
assert.equal(kin.chipText(chips[0]).badge, '1/1'); // loner
assert.equal(kin.chipText(chips[3]).badge, '10/11');
assert.equal(kin.chipText({family: 5, seat: null, members: [6, 7], alive: 0, hearts: 0, score: 12.4}).badge, '0/2');
assert.equal(kin.chipText({family: 5, seat: null, members: [6, 7], alive: 0, hearts: 0, score: 12.4}).out, true);
assert.equal(kin.chipText({family: 5, seat: null, members: [6, 7], alive: 0, hearts: 0, score: 12.4}).text, '♥0 · 12');
assert.deepEqual(chips.map(kin.chipKey), ['l4', 'f0', 'f1', 'f2']);
assert.equal(kin.COMPACT_CHIPS, 6);

// Family selection: chip clicks toggle keys; the mask covers the picked families' seats.
let focus = new Set();
focus = kin.toggleFocus(focus, 'f0');
assert.deepEqual([...focus], ['f0']);
assert.equal(kin.focusMask(state, focus), 0b11);
focus = kin.toggleFocus(focus, 'l4');
assert.equal(kin.focusMask(state, focus), 0b10011);
const twice = kin.toggleFocus(focus, 'f0');
assert.deepEqual([...twice], ['l4']);
assert.equal(focus.has('f0'), true, 'toggleFocus returns a new set');
assert.equal(kin.focusMask(state, new Set()), 0);

// Emphasis: nothing selected -> no dimming, no halos, no badges.
let em = kin.cogEmphasis(state, -1, 0);
assert.ok(em.every(e => !e.dim && !e.halo && !e.badge));
// Families picked: their cogs get badge + halo, the rest dim.
em = kin.cogEmphasis(state, -1, kin.focusMask(state, focus));
assert.deepEqual(em.map(e => e.badge ? 1 : 0).join(''), '1100100000000000');
assert.deepEqual(em.map(e => e.dim ? 1 : 0).join(''), '0011011111111111');
assert.equal(em[0].halo, true);
// Kin view wins over picked families: the selected cog and its kin get badges (½ / ¼ labels).
em = kin.cogEmphasis(state, 0, kin.focusMask(state, focus));
assert.deepEqual(em.map(e => e.badge ? 1 : 0).join(''), '1111000000000000');
assert.deepEqual(em.slice(0, 4).map(e => e.label), ['', '½', '¼', '¼']);
assert.equal(em[0].halo, false);
assert.equal(em[1].halo, true);
assert.equal(em[4].dim, true);

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

// A crowd match (Heartland Big: 50 seats, 10 tribes of 5): the mask becomes a BigInt past 31
// seats, and every seat gets an emphasis and a chip.
{
  const crowd = {
    family: Array.from({length: 50}, (_, i) => Math.floor(i / 5)),
    rPct: Array.from({length: 50}, (_, i) => Array.from({length: 50}, (_, j) => i === j ? 100 : Math.floor(i / 5) === Math.floor(j / 5) ? 50 : 0)),
    world: {cogs: Array.from({length: 50}, () => ({hp: 10})), seatScore: Array(50).fill(10), controlHearts: []},
  };
  const mask = kin.focusMask(crowd, new Set(['f9']));
  assert.equal(typeof mask, 'bigint');
  const em = kin.cogEmphasis(crowd, -1, mask);
  assert.equal(em.length, 50);
  assert.deepEqual(em.map((e, i) => e.halo ? i : -1).filter((i) => i >= 0), [45, 46, 47, 48, 49]);
  assert.equal(kin.cogEmphasis(crowd, 47, 0).filter((e) => e.halo).length, 4);
  assert.equal(kin.familyChips(crowd).length, 10);
}
console.log('Paintbot FFA-kin HUD sorting, family sums, dead flags, great hearts and R maths passed');
