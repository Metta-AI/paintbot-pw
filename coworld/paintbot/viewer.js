/* All displayed facts come from the verified Polyworld replay. */
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id),
    colors = ["#ff8069", "#71cfff"];
  let started = false;
  let state = null,
    index = null,
    selected = -1,
    loop = false,
    skip = false,
    spoilers = false,
    following = false,
    pov = false,
    bars = true,
    eventToasts = false,
    trails = false,
    lastTick = -1,
    ended = false,
    commsPinned = true;
  let inspectorKey = "",
    commsKey = "";
  let insetSize = 0.25;
  let camera = { x: 0, z: 0, d: 60, yaw: 0, tilt: 0.92 };
  const escape = (s) =>
    String(s).replace(
      /[&<>"']/g,
      (c) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        })[c],
    );
  const clock = (t) =>
    `${Math.floor(t / 24 / 60)}:${String(Math.floor(t / 24) % 60).padStart(2, "0")}`;
  const name = (i) => index?.names[i] || `Bot ${i + 1}`;
  const team = (i) => i % 2;
  const eventTitle = (e) =>
    ({
      tag: `tagged ${escape(name(e.victim))}`,
      down: "was tagged out",
      capture: "captured a heart",
      pickup: "picked up the enemy heart",
      drop: "dropped the heart",
      return: "heart returned home",
      "grenade pickup": "picked up a grenade",
      "spray pickup": "picked up a spray can",
      "shield pickup": "picked up armor",
      "grenade throw": "threw a grenade",
      "grenade blast": "grenade exploded",
      spray: "sprayed paint",
      heal: "used a med kit",
    })[e.kind];
  function ready() {
    return (
      state !== null &&
      !document.getElementById("status").classList.contains("error")
    );
  }
  function seek(t, pause = false) {
    if (!ready()) return;
    if (pause) Module._pw_play(0);
    Module._pw_seek(Math.max(0, Math.min(state.total, Math.round(t))));
  }
  function cameraUpdate() {
    if (ready())
      Module._pw_camera(camera.x, camera.z, camera.d, camera.yaw, camera.tilt);
    $("zoom").value = camera.d;
  }
  function options() {
    if (ready()) Module._pw_options(+following, +pov, +bars, +trails);
    document.body.classList.toggle("pov", pov);
    layoutInset();
  }
  function layoutInset() {
    const r = $("canvas").getBoundingClientRect(),
      w = r.width * insetSize;
    const frame = $("povframe");
    Object.assign(frame.style, {
      left: r.right - w - 24 + "px",
      top: r.top + 100 + "px",
      width: w + "px",
      height: w / 1.6 + "px",
    });
    $("fpvcap").style.top = r.top + 85 + "px";
  }
  let resizing = false;
  $("povresize").onpointerdown = (e) => {
    resizing = true;
    $("povresize").setPointerCapture(e.pointerId);
  };
  $("povresize").onpointermove = (e) => {
    if (!resizing) return;
    const r = $("canvas").getBoundingClientRect();
    insetSize = Math.max(
      0.18,
      Math.min(0.5, (r.right - 24 - e.clientX) / r.width),
    );
    if (ready()) Module._pw_inset(insetSize);
    layoutInset();
  };
  $("povresize").onpointerup = () => (resizing = false);
  $("povresize").onpointercancel = () => (resizing = false);
  $("povresize").onkeydown = (e) => {
    if (!["ArrowLeft", "ArrowRight"].includes(e.key)) return;
    e.preventDefault();
    insetSize = Math.max(
      0.18,
      Math.min(0.5, insetSize + (e.key === "ArrowLeft" ? 0.03 : -0.03)),
    );
    if (ready()) Module._pw_inset(insetSize);
    layoutInset();
  };
  window.addEventListener("resize", layoutInset);
  function pressed(id, value) {
    $(id).setAttribute("aria-pressed", String(value));
  }
  function fit() {
    camera = { x: 0, z: 0, d: 60, yaw: 0, tilt: 0.92 };
    following = false;
    cameraUpdate();
    options();
  }
  function select(i) {
    if (!ready()) return;
    selected = i;
    Module._pw_select(i);
    if (i < 0) {
      following = false;
      pov = false;
      options();
    }
    renderInspector();
    renderSeats();
  }
  function setLens(value) {
    if (!ready()) return;
    Module._pw_lens(Number(value));
    $("lens").value = String(value);
  }
  function toast(text) {
    $("toast").textContent = text;
    setTimeout(() => ($("toast").textContent = ""), 2000);
  }
  function bind(id, fn) {
    $(id).addEventListener("click", () => {
      if (ready()) fn();
    });
  }
  bind("play", () => Module._pw_play(+state.paused));
  bind("restart", () => seek(0));
  bind("back", () => seek(state.world.tick - 1, true));
  bind("step", () => seek(state.world.tick + 1, true));
  bind("forward", () => seek(state.world.tick + 120));
  bind("end", () => seek(state.total, true));
  bind("loop", () => {
    loop = !loop;
    pressed("loop", loop);
  });
  bind("skip", () => {
    skip = !skip;
    pressed("skip", skip);
  });
  bind("spoilers", () => {
    spoilers = !spoilers;
    pressed("spoilers", spoilers);
    renderTimeline();
    renderEventsIfOpen();
  });
  bind("fit", fit);
  bind("topdown", () => {
    camera.tilt = camera.tilt > 1.5 ? 0.92 : 1.55;
    cameraUpdate();
  });
  bind("eventtoasts", () => {
    eventToasts = !eventToasts;
    pressed("eventtoasts", eventToasts);
    $("feed").hidden = !eventToasts;
    $("banner").hidden = !eventToasts;
  });
  bind("bars", () => {
    bars = !bars;
    pressed("bars", bars);
    options();
  });
  bind("trails", () => {
    trails = !trails;
    pressed("trails", trails);
    options();
  });
  bind("zoomin", () => {
    camera.d = Math.max(6, camera.d * 0.8);
    cameraUpdate();
  });
  bind("zoomout", () => {
    camera.d = Math.min(100, camera.d * 1.25);
    cameraUpdate();
  });
  $("zoom").oninput = (e) => {
    camera.d = +e.target.value;
    cameraUpdate();
  };
  $("speed").onchange = (e) => {
    if (ready()) Module._pw_speed(parseInt(e.target.value));
  };
  $("scrub").oninput = (e) => seek(+e.target.value);
  $("lens").onchange = (e) => setLens(e.target.value);
  $("fullscreen").onclick = async () => {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else await document.documentElement.requestFullscreen();
    } catch {
      toast("Fullscreen is unavailable in this embed.");
    }
  };
  bind("download", () => {
    const uri =
      new URLSearchParams(location.hash.slice(1)).get("replay") ||
      new URLSearchParams(location.search).get("replay");
    if (uri) {
      const a = document.createElement("a");
      a.href = uri;
      a.download = "paintbot.replay";
      a.rel = "noopener";
      a.click();
    }
  });
  function show(title, html) {
    $("dialogbody").innerHTML =
      `<div class="eyebrow">Paintbot / replay analysis</div><h2>${title}</h2>${html}`;
    if (!$("dialog").open) $("dialog").showModal();
  }
  $("dialog").querySelector(".close").onclick = () => $("dialog").close();
  $("dialog").onclick = (e) => {
    if (e.target === $("dialog")) $("dialog").close();
  };
  function stats() {
    const w = state.world,
      counts = Array.from({ length: 16 }, () => ({ deaths: 0, shots: 0 }));
    for (const e of index.events)
      if (e.tick <= w.tick && e.kind === "down") counts[e.slot].deaths++;
    const rows = w.cogs
      .map(
        (c, i) =>
          `<tr><td><button data-seat="${i}" class="${team(i) ? "blue" : "red"}">${escape(name(i))}</button></td><td>${c.hp > 0 ? "● Alive" : state.world.equipment?.[i]?.lives === 0 ? "Eliminated" : `↻ ${Math.ceil(c.respawn / 24)}s`}</td><td>${c.tags}</td><td>${counts[i].deaths}</td><td>${c.captures}</td><td>${c.tags + c.captures * 10}</td></tr>`,
      )
      .join("");
    show(
      w.tick === state.total
        ? w.winner < 0
          ? "Match drawn"
          : `${w.winner ? "Azure" : "Ember"} wins`
        : "Match scoreboard",
      `<p class="hint">${clock(w.tick)} · Ember ${w.captures[0]} — ${w.captures[1]} Azure · Seed ${index.seed}<br>Glory = tags + 10 × captures. Statistics are evaluated at the playhead.</p><table><thead><tr><th>Player / seat</th><th>Status</th><th>Tags</th><th>Outs</th><th>Captures</th><th>Glory</th></tr></thead><tbody>${rows}</tbody></table>`,
    );
    $("dialogbody")
      .querySelectorAll("[data-seat]")
      .forEach(
        (b) =>
          (b.onclick = () => {
            select(+b.dataset.seat);
            $("dialog").close();
          }),
      );
  }
  bind("stats", stats);
  let eventFilter = "all",
    dialogMode = "";
  function events() {
    dialogMode = "events";
    const list = index.events.filter(
      (e) =>
        (spoilers || e.tick <= state.world.tick) &&
        (eventFilter === "all" || e.kind === eventFilter),
    );
    show(
      "The match, moment by moment",
      `<div class="toolbar"><select id="eventfilter" aria-label="Event type">${["all", "capture", "pickup", "drop", "return", "tag", "down", "grenade throw", "grenade blast", "spray", "grenade pickup", "spray pickup", "shield pickup", "heal"].map((x) => `<option ${x === eventFilter ? "selected" : ""}>${x}</option>`).join("")}</select><span class="hint">${list.length} events · ${spoilers ? "Future events visible" : "Future events hidden"}</span></div><div class="eventlist">${list.map((e) => `<button data-tick="${e.tick}"><span class="${e.side ? "blue" : "red"}">${clock(e.tick)} · ${escape(e.slot < 0 ? (e.side ? "Azure" : "Ember") : name(e.slot))}</span> ${eventTitle(e)}</button>`).join("") || '<p class="hint">No matching events at this point in the replay.</p>'}</div>`,
    );
    $("eventfilter").onchange = (e) => {
      eventFilter = e.target.value;
      events();
    };
    $("dialogbody")
      .querySelectorAll("[data-tick]")
      .forEach(
        (b) =>
          (b.onclick = () => {
            seek(+b.dataset.tick, true);
            $("dialog").close();
          }),
      );
  }
  bind("events", events);
  function renderEventsIfOpen() {
    if ($("dialog").open && dialogMode === "events") events();
  }
  $("dialog").addEventListener("close", () => (dialogMode = ""));
  $("help").onclick = () =>
    show(
      "Take a closer look",
      `<div class="helpgrid">${[
        ["Space", "Play / pause"],
        [", / E", "Restart / end"],
        ["B / N", "Previous / next tick"],
        [".", "Forward five seconds"],
        ["R / F / O", "Loop / skip lulls / spoilers"],
        ["Z / X", "Zoom in / out"],
        ["Escape", "Clear selection and POV"],
        ["Arrow keys", "Pan camera"],
        ["Drag", "Pan across the arena"],
        ["Shift + drag", "Orbit camera"],
        ["Pinch", "Zoom on touch screens"],
        ["Click a bot", "Inspect; Follow and Eyes in the inspector"],
      ]
        .map(([k, v]) => `<div><kbd>${k}</kbd> ${v}</div>`)
        .join(
          "",
        )}</div><p class="hint">Visibility uses the game’s range and cover checks. The tactical map shows full spectator context. Communications contain public policy shouts; private diagnostic logs are never displayed. Existing v1 replays have no recorded names or communications.</p>`,
    );
  window.addEventListener("keydown", (e) => {
    if (
      !ready() ||
      $("dialog").open ||
      /INPUT|SELECT|TEXTAREA/.test(e.target.tagName)
    )
      return;
    const keys = {
      " ": "play",
      ",": "restart",
      b: "back",
      n: "step",
      ".": "forward",
      e: "end",
      r: "loop",
      f: "skip",
      o: "spoilers",
      z: "zoomin",
      x: "zoomout",
    };
    if (keys[e.key.toLowerCase()]) {
      e.preventDefault();
      $(keys[e.key.toLowerCase()]).click();
    } else if (e.key === "Escape") {
      select(-1);
      setLens(-1);
    } else if (e.key.startsWith("Arrow")) {
      e.preventDefault();
      following = false;
      camera.x += e.key === "ArrowLeft" ? -2 : e.key === "ArrowRight" ? 2 : 0;
      camera.z += e.key === "ArrowUp" ? -2 : e.key === "ArrowDown" ? 2 : 0;
      cameraUpdate();
      options();
    }
  });
  function renderSeats() {
    if (!state) return;
    for (let i = 0; i < 16; i++) {
      const c = state.world.cogs[i],
        b = $(`seat${i}`);
      b.classList.toggle("down", c.hp <= 0);
      b.setAttribute("aria-pressed", String(i === selected));
      b.title = `${name(i)} · ${c.hp} HP · ${c.tags} tags · ${c.captures} captures`;
      b.setAttribute("aria-label", b.title);
      b.querySelector(".pips").textContent = c.hp > 0 ? "●".repeat(c.hp) : "↻";
    }
  }
  function renderInspector() {
    if (!state) return;
    const key = [selected, following, pov].join();
    const stable = inspectorKey === key && $("inspect").querySelector("dl");
    inspectorKey = key;
    if (selected < 0) {
      $("inspect").innerHTML =
        '<p class="railtitle">Squad inspection</p><p class="hint">Select a portrait or a bot in the arena.</p>';
      return;
    }
    const c = state.world.cogs[selected],
      d = index.events.filter(
        (e) =>
          e.kind === "down" &&
          e.slot === selected &&
          e.tick <= state.world.tick,
      ).length;
    const markup = `<p class="railtitle">Bot ${selected + 1} / ${team(selected) ? "Azure" : "Ember"}</p><div class="name">${escape(name(selected))}</div><dl><dt>Health</dt><dd>${c.hp} / 3</dd><dt>Lives</dt><dd>${state.world.equipment?.[selected]?.lives ?? "∞"}</dd><dt>Armor</dt><dd>${state.world.equipment?.[selected]?.armor ?? 0}</dd><dt>Equipment</dt><dd>${[state.world.equipment?.[selected]?.grenade ? "Grenade" : "", state.world.equipment?.[selected]?.sprayCan ? "Spray can" : ""].filter(Boolean).join(" · ") || "Paintball gun"}</dd><dt>Tags / outs</dt><dd>${c.tags} / ${d}</dd><dt>Captures</dt><dd>${c.captures}</dd><dt>Respawn</dt><dd>${c.hp ? "—" : (c.respawn / 24).toFixed(1) + "s"}</dd><dt>Shield</dt><dd>${(c.shield / 24).toFixed(1)}s</dd><dt>Carrying</dt><dd>${c.carrying ? "♥ Enemy heart" : "—"}</dd><dt>Position</dt><dd>${(c.pos.x / 100).toFixed(1)}, ${(c.pos.z / 100).toFixed(1)}</dd></dl><div class="inspection-actions"><button id="follow" aria-pressed="${following}">Follow</button><button id="eyes" aria-pressed="${pov}">Eyes</button><button id="botlens">Vision</button><button id="clear">Clear</button></div>`;
    if (stable) {
      const temp = document.createElement("div");
      temp.innerHTML = markup;
      const values = temp.querySelectorAll("dd");
      $("inspect")
        .querySelectorAll("dd")
        .forEach((el, i) => (el.textContent = values[i].textContent));
      return;
    }
    $("inspect").innerHTML = markup;
    $("follow").onclick = () => {
      following = !following;
      options();
      renderInspector();
    };
    $("eyes").onclick = () => {
      pov = !pov;
      options();
      renderInspector();
    };
    $("botlens").onclick = () => setLens(selected);
    $("clear").onclick = () => select(-1);
  }
  function renderTimeline() {
    if (!state || !index) return;
    const tick = state.world.tick,
      total = state.total;
    const shown = index.events.filter((e) => spoilers || e.tick <= tick);
    $("markers").innerHTML = shown
      .filter((e) => e.kind !== "down" && e.kind !== "return")
      .map(
        (e) =>
          `<button class="marker ${e.kind}" style="left:${(100 * e.tick) / total}%;background:${colors[e.side]}" data-tick="${e.tick}" aria-label="${clock(e.tick)} ${escape(e.slot < 0 ? (e.side ? "Azure" : "Ember") : name(e.slot))} ${eventTitle(e)}" title="${clock(e.tick)} · ${escape(e.slot < 0 ? (e.side ? "Azure" : "Ember") : name(e.slot))} ${eventTitle(e)}"></button>`,
      )
      .join("");
    $("markers")
      .querySelectorAll("button")
      .forEach((b) => (b.onclick = () => seek(+b.dataset.tick, true)));
    const samples = index.momentum.filter((p) => spoilers || p.tick <= tick),
      max = Math.max(1, ...samples.map((p) => Math.max(p.red, p.blue)));
    $("momentum").innerHTML = ["red", "blue"]
      .map(
        (side, i) =>
          `<polyline fill="none" stroke="${colors[i]}" stroke-width="1.5" points="${samples.map((p) => `${(p.tick / total) * 1000},${42 - (p[side] / max) * 38}`).join(" ")}"/>`,
      )
      .join("");
  }
  function minimap() {
    const canvas = $("minimap"),
      ctx = canvas.getContext("2d"),
      w = state.world;
    ctx.fillStyle = "#294835";
    ctx.fillRect(0, 0, 320, 200);
    ctx.fillStyle = "#c0b68b";
    for (const c of w.cover) {
      if (c.h === 0) {
        ctx.beginPath();
        ctx.arc(
          (c.x + c.w / 2) / 20,
          (c.z + c.w / 2) / 20,
          c.w / 40,
          0,
          Math.PI * 2,
        );
        ctx.fill();
      } else ctx.fillRect(c.x / 20, c.z / 20, c.w / 20, c.h / 20);
    }
    for (let i = 0; i < 16; i++) {
      const c = w.cogs[i];
      if (c.hp <= 0) continue;
      ctx.beginPath();
      ctx.fillStyle = colors[team(i)];
      ctx.arc(
        c.pos.x / 20,
        c.pos.z / 20,
        i === selected ? 4 : 2.5,
        0,
        Math.PI * 2,
      );
      ctx.fill();
      if (i === selected) {
        ctx.strokeStyle = "#fff3b0";
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(c.pos.x / 20, c.pos.z / 20);
        const a = Math.atan2(c.aim.z - c.pos.z, c.aim.x - c.pos.x);
        ctx.lineTo(
          c.pos.x / 20 + Math.cos(a - 0.5) * 35,
          c.pos.z / 20 + Math.sin(a - 0.5) * 35,
        );
        ctx.lineTo(
          c.pos.x / 20 + Math.cos(a + 0.5) * 35,
          c.pos.z / 20 + Math.sin(a + 0.5) * 35,
        );
        ctx.closePath();
        ctx.fillStyle = "#ffefa022";
        ctx.fill();
      }
    }
    for (let s = 0; s < 2; s++) {
      ctx.fillStyle = colors[s];
      ctx.font = "13px serif";
      ctx.fillText("♥", w.hearts[s].pos.x / 20 - 5, w.hearts[s].pos.z / 20 + 4);
    }
    ctx.strokeStyle = "#ffffff88";
    ctx.beginPath();
    state.footprint.forEach((p, i) => {
      if (i === 0) ctx.moveTo((p[0] + 32) * 5, (p[1] + 20) * 5);
      else ctx.lineTo((p[0] + 32) * 5, (p[1] + 20) * 5);
    });
    ctx.closePath();
    ctx.stroke();
  }
  let mapDrag = false;
  function mapMove(e) {
    const r = $("minimap").getBoundingClientRect();
    camera.x = ((e.clientX - r.left) / r.width) * 64 - 32;
    camera.z = ((e.clientY - r.top) / r.height) * 40 - 20;
    camera.d = Math.min(camera.d, 35);
    following = false;
    cameraUpdate();
    options();
  }
  $("minimap").onpointerdown = (e) => {
    mapDrag = true;
    $("minimap").setPointerCapture(e.pointerId);
    mapMove(e);
  };
  $("minimap").onpointermove = (e) => {
    if (mapDrag) mapMove(e);
  };
  $("minimap").onpointerup = () => (mapDrag = false);
  $("minimap").onpointercancel = () => (mapDrag = false);
  const pointers = new Map();
  let drag = null,
    pinch = 0;
  $("canvas").addEventListener("pointerdown", (e) => {
    pointers.set(e.pointerId, [e.clientX, e.clientY]);
    $("canvas").setPointerCapture(e.pointerId);
    drag = {
      x: e.clientX,
      y: e.clientY,
      startX: e.clientX,
      startY: e.clientY,
      moved: false,
    };
    if (pointers.size === 2) {
      const p = [...pointers.values()];
      pinch = Math.hypot(p[0][0] - p[1][0], p[0][1] - p[1][1]);
    }
  });
  $("canvas").addEventListener("pointermove", (e) => {
    if (!pointers.has(e.pointerId)) return;
    pointers.set(e.pointerId, [e.clientX, e.clientY]);
    if (pointers.size === 2) {
      const p = [...pointers.values()],
        n = Math.hypot(p[0][0] - p[1][0], p[0][1] - p[1][1]);
      if (n > 0) {
        camera.d = Math.max(6, Math.min(100, (camera.d * pinch) / n));
        pinch = n;
        cameraUpdate();
      }
      if (drag) drag.moved = true;
      return;
    }
    if (!drag) return;
    const dx = e.clientX - drag.x,
      dy = e.clientY - drag.y;
    if (Math.hypot(e.clientX - drag.startX, e.clientY - drag.startY) > 4)
      drag.moved = true;
    if (drag.moved) {
      following = false;
      if (e.shiftKey) {
        camera.yaw += dx * 0.008;
        camera.tilt = Math.max(0.2, Math.min(1.55, camera.tilt + dy * 0.005));
      } else {
        camera.x -= dx * camera.d * 0.0015;
        camera.z -= dy * camera.d * 0.0015;
      }
      cameraUpdate();
      options();
    }
    drag.x = e.clientX;
    drag.y = e.clientY;
  });
  $("canvas").addEventListener("pointerup", (e) => {
    pointers.delete(e.pointerId);
    if (drag && !drag.moved && state) {
      const r = $("canvas").getBoundingClientRect(),
        x = (e.clientX - r.left) / r.width,
        y = (e.clientY - r.top) / r.height;
      let best = -1,
        dist = 26;
      state.screen.forEach((p, i) => {
        if (state.world.cogs[i].hp <= 0 || !state.visible[i]) return;
        const d = Math.hypot((p[0] - x) * r.width, (p[1] - y) * r.height);
        if (d < dist) {
          best = i;
          dist = d;
        }
      });
      select(best);
    }
    drag = null;
  });
  $("canvas").addEventListener("pointercancel", (e) => {
    pointers.delete(e.pointerId);
    drag = null;
  });
  // Ordinary scrolling belongs to the surrounding Observatory page; deliberate control-scroll zooms.
  $("canvas").addEventListener(
    "wheel",
    (e) => {
      if (!e.ctrlKey && !e.metaKey) return;
      e.preventDefault();
      camera.d = Math.max(
        6,
        Math.min(100, camera.d * Math.exp(e.deltaY * 0.002)),
      );
      cameraUpdate();
    },
    { passive: false },
  );
  $("commslist").onscroll = () => {
    const el = $("commslist");
    commsPinned = el.scrollHeight - el.scrollTop - el.clientHeight < 20;
  };
  $("commslive").onclick = () => {
    commsPinned = true;
    $("commslist").scrollTop = $("commslist").scrollHeight;
  };
  $("commsteam").onchange = renderComms;
  function renderComms() {
    if (!state || !index) return;
    const messages = index.communications.filter(
      (m) =>
        m.tick <= state.world.tick &&
        ($("commsteam").value === "-1" ||
          team(m.slot) === +$("commsteam").value),
    );
    $("commscount").textContent = messages.length;
    const key = messages.length + ":" + $("commsteam").value;
    if (key === commsKey) return;
    commsKey = key;
    const el = $("commslist");
    el.innerHTML =
      messages
        .slice(-200)
        .map(
          (m) =>
            `<p><span class="${team(m.slot) ? "blue" : "red"}">${clock(m.tick)} · ${escape(name(m.slot))}</span><br>${escape(m.text)}</p>`,
        )
        .join("") ||
      '<p class="hint">No public communications recorded at this point. Private policy logs are not included.</p>';
    if (commsPinned) el.scrollTop = el.scrollHeight;
  }
  Module.paintbotIndex = (data) => {
    index = data;
    for (let i = 0; i < 16; i++) {
      const b = document.createElement("button");
      b.id = `seat${i}`;
      b.className = `seat ${team(i) ? "blue" : "red"}`;
      b.innerHTML = `<span class="num">${i + 1}</span><img src="portrait.png" alt=""><span class="pips">●●●</span>`;
      b.onclick = () => {
        if (innerWidth < 700 && selected === i) {
          select(-1);
          setLens(-1);
          return;
        }
        select(i);
        if (innerWidth < 700) {
          following = true;
          pov = true;
          options();
          setLens(i);
          toast(name(i));
        }
      };
      $(`squad${team(i)}`).append(b);
      const option = document.createElement("option");
      option.value = i;
      option.textContent = `${i + 1} · ${name(i)}`;
      $("lens").append(option);
    }
    $("verification").textContent = "✓ HASH VERIFIED";
  };
  Module.paintbotState = (data) => {
    state = data;
    if (!index) return;
    if (!started) {
      started = true;
      layoutInset();
      const t = new URLSearchParams(location.search).get("t");
      if (t !== null && Number.isFinite(Number(t))) seek(Number(t), true);
    }
    const w = data.world,
      t = w.tick;
    $("povsight").style.visibility =
      selected >= 0 && w.cogs[selected].hp > 0 ? "visible" : "hidden";
    $("play").textContent = data.paused ? "Play" : "Pause";
    $("scrub").max = data.total;
    $("scrub").value = t;
    $("clock").textContent = `${clock(t)} / ${clock(data.total)}`;
    $("tickread").textContent = `${t} / ${data.total} ticks`;
    for (let s = 0; s < 2; s++) {
      $(`score${s}`).textContent = w.captures[s];
      $(`alive${s}`).textContent =
        `${w.cogs.filter((c, i) => team(i) === s && c.hp > 0).length} alive`;
      const h = w.hearts[s];
      $(`heart${s}`).textContent =
        h.carrier >= 0
          ? `Stolen · bot ${h.carrier + 1}`
          : h.returnAt > 0
            ? "Heart dropped"
            : "Heart at home";
    }
    let bubbles = document.getElementById("speech-bubbles");
    if (!bubbles) {
      bubbles = document.createElement("div");
      bubbles.id = "speech-bubbles";
      bubbles.style.cssText =
        "position:fixed;inset:0;pointer-events:none;z-index:5";
      document.body.appendChild(bubbles);
    }
    const canvasRect = $("canvas").getBoundingClientRect();
    bubbles.replaceChildren();
    const latestSpeech = new Map();
    for (const message of index.communications || []) {
      if (message.tick <= t && message.tick > t - 72)
        latestSpeech.set(message.slot, message);
    }
    for (const [slot, message] of latestSpeech) {
      const p = data.screen[slot];
      if (
        !data.visible[slot] ||
        w.cogs[slot].hp <= 0 ||
        !p ||
        p[0] < 0 ||
        p[0] > 1 ||
        p[1] < 0 ||
        p[1] > 1
      )
        continue;
      const bubble = document.createElement("div");
      bubble.textContent = message.text;
      bubble.style.cssText = `position:absolute;left:${canvasRect.left + p[0] * canvasRect.width}px;top:${canvasRect.top + p[1] * canvasRect.height}px;transform:translate(-50%,-130%);max-width:160px;padding:5px 8px;border-radius:12px;background:#fff9df;color:#263c30;font:12px sans-serif;box-shadow:0 2px 5px #0005`;
      bubbles.appendChild(bubble);
    }
    const recent = index.events
      .filter((e) => e.tick <= t && e.tick > t - 120 && e.kind !== "down")
      .slice(-4);
    $("feed").innerHTML = recent
      .map(
        (e) =>
          `<div class="feeditem"><time>${clock(e.tick)}</time><span class="${e.side ? "blue" : "red"}">${escape(e.slot < 0 ? (e.side ? "Azure" : "Ember") : name(e.slot))}</span><br>${eventTitle(e)}</div>`,
      )
      .join("");
    const capture = recent.findLast((e) => e.kind === "capture");
    $("banner").textContent =
      capture && t - capture.tick < 60
        ? `${capture.side ? "Azure" : "Ember"} captures ♥`
        : "";
    if (t !== lastTick) {
      renderSeats();
      renderInspector();
      renderComms();
      if (t % 12 === 0 || Math.abs(t - lastTick) > 12 || t === data.total)
        renderTimeline();
      lastTick = t;
    }
    minimap();
    if (skip && !data.paused) {
      const next = index.events.find((e) => e.tick > t && e.kind !== "down");
      if (next && next.tick - t > 120) {
        $("skipping").textContent = "SKIPPING LULL";
        seek(next.tick - 48);
      } else $("skipping").textContent = "";
    } else $("skipping").textContent = "";
    if (t === data.total) {
      if (loop) {
        seek(0);
        Module._pw_play(1);
      } else if (!ended) {
        ended = true;
        stats();
      }
    } else ended = false;
  };
})();
