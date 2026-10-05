/* Replay-derived inspection text and screen-space object picking. */
(function (root) {
  'use strict';
  const teams = ['Ember', 'Azure'];
  const seconds = ticks => `${(Math.max(0, ticks) / 24).toFixed(1)}s`;
  const pickups = {
    grenadePickup: ['Grenade', 'A throwable paint grenade. Deals 2 damage in the open, 1 into another trench, or 6 inside the blast’s trench.'],
    sprayPickup: ['Spray can', 'Adds a reusable short-range paint spray that hits in a forward cone.'],
    medkitPickup: ['Med kit', 'Restores full health (10 HP in FFA-kin and from rules 49, 3 before) when collected by an injured cog.'],
    armorPickup: ['Armor', 'Grants 3 armor points that absorb damage. While armored, gun cooldown is tripled.'],
    uniformPickup: ['Uniform', 'Disguises the cog as the opposing team. Attacking ends the disguise; friendly fire still applies.'],
    misterPickup: ['Windex-mister', 'For 60 s the cog cannot attack, but every 15 s heals 1 HP to every cog within 5 m (its halo), any team, itself included.'],
    radarPickup: ['Radar', 'For 60 s (or until its carrier picks up anything else) every cog within 8 m deals double damage, any team. The carrier cannot attack and moves at 60% speed.'],
    sniperPickup: ['Sniper rifle', 'Replaces the gun until death: accurate to 48 m with no duds, one shot every 4 s. Cannot be carried with a spray can.'],
  };
  function equipment(cog, e = {}, uniform = false) {
    const items = [];
    if (e.grenade) items.push(e.charge ? `Grenade · charging ${seconds(e.charge)}` : 'Grenade');
    if (e.sprayCan) items.push(e.burst > 0 ? 'Spray can · spraying' : e.sprayCooldown > 0 ? `Spray can · ready in ${seconds(e.sprayCooldown)}` : 'Spray can · ready');
    if (e.armor > 0) items.push(`Armor · ${e.armor} / 3`);
    if (uniform) items.push('Uniform · enemy disguise');
    if (cog.carrying) items.push('Carrying enemy heart');
    return items.length ? items.join(' · ') : 'None';
  }
  function territoryText(boost) {
    return boost > 0 ? `Territory boost +${boost}%: ${boost}% faster, ${boost}% less gun spread.` : 'Territory boost +0% (neutral or unrelated ground).';
  }
  function bonuses(cog, terrain, e = {}, rules = 27, ffa = false) {
    if (cog.hp <= 0) return 'None while respawning or eliminated.';
    const items = [];
    if (cog.shield > 0) items.push(`Spawn protection · ${seconds(cog.shield)} remaining.`);
    if (rules >= 6 && terrain?.trench >= 0) items.push('Trench cover: 70% chance to avoid gunfire from outside; outside grenade damage 1 (inside: 6). Movement out is slowed.');
    if (rules >= 9 && terrain) items.push(`Elevation ${(terrain.elevation / 100).toFixed(1)} m.`);
    if (rules >= 10 && terrain) {
      const delta = terrain.spread - 100;
      items.push(delta === 0 ? 'Aim: normal gun spread.' : `Aim: ${Math.abs(delta)}% ${delta < 0 ? 'less' : 'more'} gun spread (${delta < 0 ? 'downhill' : 'uphill'}).`);
    }
    // FFA-kin: 30% x r(me, territory owner) faster and less gun spread (sim.territoryBoost).
    if (ffa && terrain) items.push(territoryText(terrain.territoryBoost ?? 0));
    if (rules >= 6 && (e.armor > 0 || cog.carrying || terrain?.trench >= 0)) items.push('Gun cooldown: 3s (normally 1s).');
    return items.join(' ') || 'None';
  }
  function objectDetails(selection, state) {
    if (!selection) return null;
    const w = state.world;
    if (selection.kind === 'heart') {
      const h = w.controlHearts?.[selection.id];
      if (!h) return null;
      const value = state.heartValues?.[selection.id] ?? 1;
      const capture = w.heartCaptures?.[selection.id];
      // FFA-kin owners and capturers are seats, not teams.
      const side = state.mode === 'ffa_kin' ? (i => i >= 0 ? `Cog ${i + 1}` : undefined) : (i => teams[i]);
      let status = 'No capture in progress';
      if (capture?.contested) status = 'Contested · capture paused';
      else if (capture?.ticks > 0) status = `${side(capture.team)} capturing · ${seconds(72 - capture.ticks)} remaining`;
      return {title: `${value === 5 ? 'Big heart' : 'Heart'} ${selection.id + 1}`, color: h.owner,
        rows: [['Owner', side(h.owner) ?? 'Neutral'], ['Held continuously', h.owner < 0 ? 'Unclaimed' : seconds(state.heartHeld?.[selection.id] ?? 0)],
          ['Value', `${value} point${value === 1 ? '' : 's'}/s`], ['Capture', status]],
        description: 'Hold this heart to earn points. The held timer resets when ownership changes.'};
    }
    const p = w.pickups?.[selection.id];
    if (!p) return null;
    const [title, description] = pickups[p.kind] ?? ['Upgrade', 'Equipment pickup'];
    return {title, color: -1, rows: [['Status', p.readyAt > w.tick ? `Respawns in ${seconds(p.readyAt - w.tick)}` : 'Available'],
      ['Respawn', p.kind === 'grenadePickup' ? '5s after collection' : '30s after collection']], description};
  }
  function objectAt(objects, rect, x, y) {
    let best = null, nearest = 24;
    for (const item of objects || []) {
      const a = item.bottom, b = item.top;
      if (!a || !b || a[0] === -100 || b[0] === -100) continue;
      const ax = rect.left + a[0] * rect.width, ay = rect.top + a[1] * rect.height;
      const dx = (b[0] - a[0]) * rect.width, dy = (b[1] - a[1]) * rect.height;
      const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy || 1)));
      const distance = Math.hypot(x - ax - t * dx, y - ay - t * dy);
      if (distance < nearest) { nearest = distance; best = {kind: item.kind, id: item.id}; }
    }
    return best;
  }
  const api = {equipment, bonuses, territoryText, objectDetails, objectAt};
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.PaintbotInspector = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
