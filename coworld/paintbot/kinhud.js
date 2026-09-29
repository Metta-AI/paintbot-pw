/* FFA-kin (Heartland) HUD maths: pure functions over the viewer state, unit-tested in node. */
(function (root) {
  'use strict';
  const TICK_RATE = 24;
  const GREAT_QUORUM = 3;
  const GREAT_CAPTURE_TICKS = 5 * TICK_RATE;
  // Same colour as the board disc: HSL(hue, 80%, 58%), loners grey (kinhue.nim).
  function kinColor(hue, alpha = 1) {
    if (hue === undefined || hue === null || hue < 0) return `rgba(150,155,160,${alpha})`;
    return `hsla(${Math.round(hue * 10) / 10},80%,58%,${alpha})`;
  }
  const isFfa = (state) => state?.mode === 'ffa_kin';
  const hueOf = (state, seat) => state.kinHue?.[seat] ?? -1;
  // Relatedness label for a round(100 r) value: clones 1, siblings ½, cousins ¼.
  function kinLabel(pct) {
    if (!pct) return '';
    return pct >= 100 ? '1' : pct === 50 ? '½' : pct === 25 ? '¼' : `${pct}%`;
  }
  const points = (tenths) => tenths / 10;
  // Seats in this match: 16, or a crowd variant's count (Heartland Big: 50).
  const seatCount = (state) => state.world?.cogs?.length || 16;
  // R_i = sum_j r_ij s_j, in points. rPct is round(100 r) and s is in tenths, both integers.
  function kinScore(state, seat) {
    const w = state.world;
    let total = 0;
    for (let j = 0; j < seatCount(state); j++) total += (state.rPct?.[seat]?.[j] ?? (j === seat ? 100 : 0)) * (w.seatScore?.[j] ?? 0);
    return total / 1000;
  }
  function cogRows(state) {
    const w = state.world;
    const rows = [];
    for (let seat = 0; seat < seatCount(state); seat++) {
      rows.push({
        seat,
        family: state.family?.[seat] ?? -1,
        hue: hueOf(state, seat),
        held: (w.controlHearts || []).filter((h) => h.owner === seat).length,
        heartSec: w.heartSeconds?.[seat] ?? 0,
        great: points(w.greatShare?.[seat] ?? 0),
        s: points(w.seatScore?.[seat] ?? 0),
        R: kinScore(state, seat),
        dead: !(w.cogs?.[seat]?.hp > 0),
      });
    }
    return rows.sort((a, b) => b.R - a.R || b.s - a.s || a.seat - b.seat);
  }
  // One chip per family with its summed raw score and control hearts held now; each loner is
  // its own chip.
  function familyChips(state) {
    const w = state.world;
    const chips = new Map();
    for (let seat = 0; seat < seatCount(state); seat++) {
      const family = state.family?.[seat] ?? -1;
      const key = family >= 0 ? `f${family}` : `l${seat}`;
      if (!chips.has(key)) chips.set(key, { family, seat: family >= 0 ? null : seat, hue: hueOf(state, seat), score: 0, hearts: 0, members: [], alive: 0 });
      const chip = chips.get(key);
      chip.members.push(seat);
      chip.score += w.seatScore?.[seat] ?? 0;
      if (w.cogs?.[seat]?.hp > 0) chip.alive++;
      chip.hearts += (w.controlHearts || []).filter((h) => h.owner === seat).length;
    }
    return [...chips.values()]
      .map((c) => ({ ...c, score: points(c.score) }))
      .sort((a, b) => b.score - a.score || b.alive - a.alive || a.members[0] - b.members[0]);
  }
  // A chip's selection key: "f<family>" for a family, "l<seat>" for a loner.
  const chipKey = (chip) => chip.family >= 0 ? `f${chip.family}` : `l${chip.seat}`;
  // Chip text: the badge is alive/size ("1/2"); the body is hearts held and raw score.
  // Compact chips (many families) drop the separator.
  function chipText(chip, compact = false) {
    return {
      badge: `${chip.alive}/${chip.members.length}`,
      hearts: `♥${chip.hearts}`,
      score: `${Math.round(chip.score)}`,
      text: `♥${chip.hearts}${compact ? ' ' : ' · '}${Math.round(chip.score)}`,
      out: chip.alive === 0,
    };
  }
  const COMPACT_CHIPS = 6; // more chips than this switch the header strip to compact chips
  // Toggle one chip in the family selection (a Set of chip keys); returns a new Set.
  function toggleFocus(focus, key) {
    const next = new Set(focus);
    if (next.has(key)) next.delete(key); else next.add(key);
    return next;
  }
  // A seat's policy: its player name without the " (n)" copy suffix the host appends.
  const policyOf = (names, seat) => (names?.[seat] || `Bot ${seat + 1}`).replace(/ \(\d+\)$/, '');
  // One chip per policy with the mean score of the cogs it controls: R (the match score) and raw s.
  function policyChips(state, names) {
    const chips = new Map();
    for (let seat = 0; seat < seatCount(state); seat++) {
      const policy = policyOf(names, seat);
      if (!chips.has(policy)) chips.set(policy, { policy, members: [], alive: 0, R: 0, s: 0 });
      const chip = chips.get(policy);
      chip.members.push(seat);
      chip.R += kinScore(state, seat);
      chip.s += points(state.world.seatScore?.[seat] ?? 0);
      if (state.world.cogs?.[seat]?.hp > 0) chip.alive++;
    }
    return [...chips.values()]
      .map(({ R, s, ...c }) => ({ ...c, meanR: R / c.members.length, meanS: s / c.members.length }))
      .sort((a, b) => b.meanR - a.meanR || b.meanS - a.meanS || a.members[0] - b.members[0]);
  }
  // A policy chip's selection key; it shares the focus set with family keys.
  const policyKey = (chip) => `p:${chip.policy}`;
  // Seats belonging to the selected families or policies as a bit mask (bit i = seat i): a number
  // for up to 31 seats, a BigInt for crowd matches. maskBit reads either.
  function focusMask(state, focus, names) {
    const seats = seatCount(state);
    let mask = seats > 31 ? 0n : 0;
    for (let seat = 0; seat < seats; seat++) {
      const family = state.family?.[seat] ?? -1;
      if (!focus.has(family >= 0 ? `f${family}` : `l${seat}`) && !focus.has(`p:${policyOf(names, seat)}`)) continue;
      if (typeof mask === 'bigint') mask |= 1n << BigInt(seat); else mask |= 1 << seat;
    }
    return mask;
  }
  const maskBit = (mask, i) => typeof mask === 'bigint' ? Number((mask >> BigInt(i)) & 1n) : (mask >> i) & 1;
  // How each cog is drawn. Kin view (a selected cog) takes precedence: the cog and its kin get
  // badges (kin with ½ / ¼), kin get a halo, unrelated cogs dim. Otherwise, with families
  // selected, their cogs get a badge and a halo and every other cog dims. With nothing selected
  // no cog is dimmed and no badges are drawn.
  function cogEmphasis(state, selected, mask) {
    const out = [];
    for (let i = 0; i < seatCount(state); i++) {
      if (selected >= 0) {
        const pct = i === selected ? 100 : state.rPct?.[selected]?.[i] ?? 0;
        out.push({ dim: pct === 0, halo: i !== selected && pct > 0, badge: pct > 0,
          label: i === selected ? '' : kinLabel(pct) });
      } else if (mask) {
        const on = maskBit(mask, i) === 1;
        out.push({ dim: !on, halo: on, badge: on, label: '' });
      } else out.push({ dim: false, halo: false, badge: false, label: '' });
    }
    return out;
  }
  // Each great heart: dormant (countdown), charging (n/3 present, charge fraction) or ready.
  function greatStatus(state) {
    const w = state.world;
    return (w.greatHearts || []).map((g, index) => {
      const present = g.present ?? 0;
      if (w.tick < g.dormantUntil) {
        return { index, state: 'dormant', present, quorum: GREAT_QUORUM, progress: 0,
          secondsLeft: Math.ceil((g.dormantUntil - w.tick) / TICK_RATE) };
      }
      const progress = Math.max(0, Math.min(1, (g.progress ?? 0) / GREAT_CAPTURE_TICKS));
      const charging = present >= GREAT_QUORUM || progress > 0;
      return { index, state: charging ? 'charging' : 'ready', present, quorum: GREAT_QUORUM, progress, secondsLeft: 0 };
    });
  }
  function greatText(status) {
    if (status.state === 'dormant') return `dormant ${status.secondsLeft}s`;
    if (status.state === 'charging') return `${Math.min(status.present, status.quorum)}/${status.quorum} · ${Math.round(status.progress * 100)}%`;
    return status.present ? `ready · ${status.present}/${status.quorum}` : 'ready';
  }
  // Winner -3 ends an FFA match: name the top cog by R_i and the top family by raw score.
  function matchResult(state, nameOf = (i) => `Cog ${i + 1}`) {
    const top = cogRows(state)[0];
    const family = familyChips(state)[0];
    const familyName = family.family >= 0 ? `family of ${family.members.map((i) => i + 1).join(', ')}` : `loner ${family.seat + 1}`;
    return { top, family, text: `Match ended · top cog ${nameOf(top.seat)} (R ${top.R.toFixed(1)}) · top ${familyName} (${family.score.toFixed(1)})` };
  }
  const api = { kinColor, isFfa, kinLabel, kinScore, cogRows, familyChips, greatStatus, greatText, matchResult,
    chipKey, chipText, COMPACT_CHIPS, toggleFocus, focusMask, cogEmphasis, policyOf, policyChips, policyKey };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.PaintbotKinHud = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
