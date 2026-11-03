"use strict";

// Every call to the app: `await dial(op, args)`, a POST to /api/<op>
// served next to the pages (settings/api.go).
async function dial(op, args = {}) {
  const res = await fetch("/api/" + op, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(args) });
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

// Wails' runtime drags the window by its top strip (--wails-draggable).
import("/wails/runtime.js").catch(() => {});

const $ = (s, root = document) => root.querySelector(s);
const $$ = (s, root = document) => [...root.querySelectorAll(s)];

let config = {};

// MARK: - Pages

function show(view) {
  for (const b of $$("#nav button")) {
    const on = b.dataset.view === view;
    b.classList.toggle("on", on);
    if (on) b.setAttribute("aria-current", "page");
    else b.removeAttribute("aria-current");
  }
  for (const v of $$(".view")) v.classList.toggle("on", v.id === view);
  $("main").scrollTop = 0;
  if (view === "setup") refreshStatus();
  if (view === "ring") loadRing();
}
$("#nav").addEventListener("click", (e) => { const b = e.target.closest("button"); if (b) show(b.dataset.view); });
document.addEventListener("click", async (e) => {
  const go = e.target.closest("[data-go]");
  if (go) {
    show(go.dataset.go);
    if (go.dataset.go === "voice") setCredMode("token", true);
  }
  const open = e.target.closest("[data-open]");
  if (open) {
    const r = await dial("open", { what: open.dataset.open });
    if (open.dataset.open === "dial") {
      const el = $("#openDialResult");
      el.className = r.ok ? "result" : "result bad";
      el.textContent = r.ok ? "Opening…" : "Dial isn't next to this app. Open it from your Applications folder.";
    }
  }
  const showKey = e.target.closest("button.show");
  if (showKey) {
    const input = showKey.parentElement.querySelector("input");
    input.type = input.type === "password" ? "text" : "password";
    showKey.textContent = input.type === "password" ? "Show" : "Hide";
  }
});

// MARK: - Get started

// Steps the user opened or closed by hand, by id: true for open.
const stepChoice = {};
for (const head of $$(".stepHead")) {
  head.addEventListener("click", () => {
    const step = head.parentElement;
    stepChoice[step.id] = !step.classList.contains("open");
    renderSteps();
  });
}

let lastStatus = null;

function renderSteps() {
  const s = lastStatus;
  if (!s) return;
  const d = s.dial || {};
  const mac = s.os === "darwin";
  const required = [["step-dial", !!d.connected]];
  if (mac) required.push(["step-permissions", !!(d.connected && d.accessibility && d.microphone)]);
  required.push(["step-voice", !!s.voice]);
  const current = (required.find(([, done]) => !done) || [null])[0];
  const notes = {
    "step-dial": d.connected ? "Running" : "",
    "step-permissions": !d.connected ? "" : d.accessibility && d.microphone ? "Allowed" : "",
    "step-voice": s.voice ? "Key added" : "",
    "step-jev": s.jev ? "Key added" : "Plain rules decide for now",
  };
  for (const [id, done] of [...required, ["step-jev", !!s.jev]]) {
    const step = $("#" + id);
    const isCurrent = id === current;
    step.classList.toggle("done", done);
    step.classList.toggle("current", isCurrent);
    // A step being typed in stays open, even once its key counts as added.
    const typing = step.contains(document.activeElement) && document.activeElement.tagName === "INPUT";
    const open = stepChoice[id] ?? (isCurrent || typing || (id === "step-jev" && !current && !s.jev));
    step.classList.toggle("open", open);
    step.querySelector(".stepNote").textContent = notes[id];
  }
  $("#perm-accessibility").classList.toggle("done", !!d.accessibility);
  $("#perm-microphone").classList.toggle("done", !!d.microphone);
  // Dial reports it hasn't got Accessibility, though macOS may list it as on.
  $("#permStale").hidden = !(d.connected && !d.accessibility);

  const done = required.filter(([, isDone]) => isDone).length;
  const ready = done === required.length;
  document.querySelector("#setup").classList.toggle("done-all", ready);
  $("#setupTitle").textContent = ready ? "You're all set" : "Set up Dial";
  $("#setupLede").textContent = ready
    ? "Click the centre of the dial and say something. Here's how it works."
    : "A few steps, and you can talk to your computer.";
  $("#progressBar").style.width = (done / required.length * 100) + "%";
  $("#progress").setAttribute("aria-valuemax", required.length);
  $("#progress").setAttribute("aria-valuenow", done);
  $("#navProgress").hidden = ready;
  $("#navProgress").textContent = done + "/" + required.length;
  $("#navProgress").title = `${done} of ${required.length} steps done`;
  $("#navVoice").hidden = !!s.voice;
}

async function refreshStatus() {
  let s;
  try {
    s = await dial("status");
  } catch {
    return;
  }
  lastStatus = s;
  document.body.classList.toggle("not-mac", s.os !== "darwin");
  renderSteps();
  showProblem(s.problem);
  $("#version").textContent = s.version;
  $("#configPath").textContent = s.config;
}

function showProblem(text) {
  $("#problem").hidden = !text;
  $("#problemText").textContent = text || "";
}

// The picture of the dial under "Using the dial".
function usageDial() {
  const at = (degrees, r) => { const a = degrees * Math.PI / 180; return [90 + r * Math.cos(a), 90 - r * Math.sin(a)]; };
  let tiles = "";
  for (let i = 0; i < 8; i++) {
    const [x, y] = at(90 - i * 45, 60), size = i === 0 ? 27 : 23;
    tiles += `<rect class="uTile" x="${(x - size / 2).toFixed(1)}" y="${(y - size / 2).toFixed(1)}" width="${size}" height="${size}" rx="${size * .24}"/>`;
  }
  const [ax, ay] = at(-112, 79), [bx, by] = at(-158, 79);
  const pin = (x, y, n) => `<circle class="uPin" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="8.5"/><text class="uPinText" x="${x.toFixed(1)}" y="${(y + 3.7).toFixed(1)}">${n}</text>`;
  const [p2x, p2y] = at(45, 60), [p3x, p3y] = at(-135, 79);
  return `<svg viewBox="0 0 180 180"><defs><marker id="uArrow" viewBox="0 0 8 8" refX="5" refY="4" markerWidth="5.5" markerHeight="5.5" orient="auto"><path class="uHead" d="M1 1L6 4L1 7"/></marker></defs>
    <circle class="uDisc" cx="90" cy="90" r="86"/>${tiles}
    <path class="uArc" marker-end="url(#uArrow)" d="M${ax.toFixed(1)} ${ay.toFixed(1)}A79 79 0 0 1 ${bx.toFixed(1)} ${by.toFixed(1)}"/>
    <circle class="uKnob" cx="90" cy="90" r="37"/>
    <rect class="uMic" x="84" y="72" width="12" height="21" rx="6"/><path class="uMic" d="M78 88a12 12 0 0 0 24 0M90 100v6M83 106h14"/>
    ${pin(116, 66, 1)}${pin(p2x, p2y, 2)}${pin(p3x, p3y, 3)}</svg>`;
}
$("#usageDial").innerHTML = usageDial();

// MARK: - Config

function engine() {
  const engines = (config.voice && config.voice.engines) || [];
  return engines[0] || { name: "豆包", type: "volcengine", apiKey: "", appId: "", accessToken: "", resourceId: "volc.seedasr.sauc.duration" };
}

async function loadConfig() {
  config = await dial("config.get");
  const e = engine();
  for (const input of $$("#engine [data-field]")) input.value = e[input.dataset.field] || "";
  setCredMode(!e.apiKey && (e.appId || e.accessToken) ? "token" : "key", false);
  $("#quickVoiceKey").value = e.apiKey || "";
  const j = config.jev || {};
  for (const input of $$("#jevForm [data-field]")) input.value = j[input.dataset.field] || "";
  $("#quickJevKey").value = j.apiKey || "";
  $("#hotwords").value = ((config.voice && config.voice.hotwords) || []).join("\n");
  setRange("commandThreshold", config.commandThreshold ?? 0.6, (v) => Number(v).toFixed(2));
  setRange("appThreshold", config.appThreshold ?? 0.5, (v) => Number(v).toFixed(2));
  const ring = config.ring || {};
  setRange("ringSize", ring.size ?? 8, (v) => v);
  setRange("halfLife", ring.halfLifeDays ?? 14, (v) => {
    $("#halfLifeHelp").textContent = `A pick counts half after ${v} ${Number(v) === 1 ? "day" : "days"}, a quarter after twice that, so an app you stopped using drifts off the ring.`;
    return v + (Number(v) === 1 ? " day" : " days");
  });
  const theme = config.theme || {};
  setRange("themeSize", Math.round((theme.size ?? 1) * 100), (v) => v + "%");
  setRange("themeTransparency", Math.round((theme.transparency ?? 0) * 100), (v) => v + "%");
  setRingStyle(theme.ringStyle ?? DEFAULT_RING_STYLE);
}

function setRange(id, value, format) {
  const input = $("#" + id);
  input.value = value;
  $("#" + id + "Value").textContent = format(value);
  input.oninput = () => { $("#" + id + "Value").textContent = format(input.value); };
}

// How the speech engine signs in. The core prefers an API key when there is
// one, so choosing the App ID and token saves without it.
let credMode = "key";
function setCredMode(mode, save) {
  credMode = mode;
  for (const b of $$("#credMode button")) b.setAttribute("aria-checked", String(b.dataset.cred === mode));
  for (const part of $$("[data-show-cred]")) part.hidden = part.dataset.showCred !== mode;
  if (save) saveSoon("voice", voiceValue());
}
$("#credMode").addEventListener("click", (e) => { const b = e.target.closest("button"); if (b) setCredMode(b.dataset.cred, true); });

function voiceValue() {
  const e = { ...engine() };
  for (const input of $$("#engine [data-field]")) e[input.dataset.field] = input.value.trim();
  if (credMode === "token") e.apiKey = "";
  if (!e.name) e.name = "豆包";
  e.type = "volcengine";
  const hotwords = $("#hotwords").value.split("\n").map((w) => w.trim()).filter(Boolean);
  return { engines: [e], engine: e.name, hotwords };
}

function jevValue() {
  const j = { ...(config.jev || {}) };
  for (const input of $$("#jevForm [data-field]")) j[input.dataset.field] = input.value.trim();
  return j;
}

// One timer per key, so a change to one setting can't cancel a change to another.
const saveTimers = {};
let savedTimer;
function saveSoon(key, value, delay = 300) {
  clearTimeout(saveTimers[key]);
  saveTimers[key] = setTimeout(() => save(key, value), delay);
}

async function save(key, value) {
  clearTimeout(saveTimers[key]);
  const state = $("#saveState");
  let problem = "";
  try {
    const r = await dial("config.set", { key, value });
    if (r.ok) config[key] = value;
    else problem = r.error || "the file can't be written";
  } catch (e) {
    problem = e.message;
  }
  clearTimeout(savedTimer);
  state.className = problem ? "saveState bad" : "saveState";
  state.textContent = problem ? "Couldn't save: " + problem : "Saved";
  if (!problem) savedTimer = setTimeout(() => { state.textContent = ""; }, 1800);
  if (key === "voice" || key === "jev") refreshStatus();
}

// The keys on Get started and on their own pages are one value.
function mirror(quick, full, keyName, value) {
  $(quick).addEventListener("input", () => {
    $(full).value = $(quick).value;
    if (keyName === "voice") setCredMode("key", false);
    saveSoon(keyName, value());
  });
  $(full).addEventListener("input", () => { $(quick).value = $(full).value; });
}
mirror("#quickVoiceKey", '#engine [data-field="apiKey"]', "voice", voiceValue);
mirror("#quickJevKey", '#jevForm [data-field="apiKey"]', "jev", jevValue);

for (const input of $$("#engine [data-field], #hotwords")) input.addEventListener("input", () => saveSoon("voice", voiceValue()));
for (const input of $$("#jevForm [data-field]")) input.addEventListener("input", () => saveSoon("jev", jevValue()));
$("#commandThreshold").addEventListener("change", (e) => saveSoon("commandThreshold", Number(e.target.value)));
$("#appThreshold").addEventListener("change", (e) => saveSoon("appThreshold", Number(e.target.value)));
const ringValue = () => ({ size: Number($("#ringSize").value), halfLifeDays: Number($("#halfLife").value) });
$("#ringSize").addEventListener("change", () => saveSoon("ring", ringValue()));
$("#halfLife").addEventListener("change", () => saveSoon("ring", ringValue()));

// MARK: - Theme

function saveTheme() {
  // Quickly, so the dial follows the slider.
  saveSoon("theme", { size: Number($("#themeSize").value) / 100, transparency: Number($("#themeTransparency").value) / 100, ringStyle }, 80);
}

// What the ring shows as a drag turns it. The names are the config's.
var DEFAULT_RING_STYLE = "ticksAndDimple";
var ringStyle = DEFAULT_RING_STYLE;
var RING_STYLES = [
  ["ticksAndDimple", "Ticks + dimple"], ["ticks", "Ticks"], ["dimple", "Dimple"], ["spokes", "Spokes"], ["trail", "Trail"],
];

// A small picture of the ring in the middle of a drag.
function ringPreview(style) {
  const at = (degrees, radius) => {
    const a = degrees * Math.PI / 180;
    return `${(50 + radius * Math.cos(a)).toFixed(2)} ${(50 - radius * Math.sin(a)).toFixed(2)}`;
  };
  const line = (degrees, from, to, width, opacity) => `<path d="M${at(degrees, from)}L${at(degrees, to)}" stroke-width="${width}" opacity="${opacity}"/>`;
  let marks = "";
  if (style === "ticksAndDimple" || style === "ticks") {
    for (let i = 0; i < 72; i++) marks += line(i * 5 + 20, i % 6 ? 40 : 37, 44, i % 6 ? .5 : .9, i % 6 ? .45 : .8);
  }
  if (style === "spokes") {
    for (let i = 0; i < 12; i++) marks += line(i * 30 + 20, 26, 42, 1.8, .4);
  }
  if (style === "ticksAndDimple" || style === "dimple") {
    const [x, y] = at(110, 33).split(" ");
    marks += `<circle cx="${x}" cy="${y}" r="6" class="ringDimple"/>`;
  }
  if (style === "trail") {
    for (let i = 0; i < 10; i++) marks += `<path d="M${at(70 + i * 9, 33)}L${at(79 + i * 9, 33)}" class="ringTrail" stroke-width="5" opacity="${((10 - i) / 10 * .85).toFixed(2)}"/>`;
  }
  return `<svg viewBox="0 0 100 100" aria-hidden="true"><circle cx="50" cy="50" r="47" class="ringDisc"/><g class="ringMarks">${marks}</g><circle cx="50" cy="50" r="22" class="ringKnob"/></svg>`;
}

$("#ringStyles").innerHTML = RING_STYLES.map(([style, name]) =>
  `<button type="button" role="radio" class="ringStyle" data-style="${style}" aria-checked="false">${ringPreview(style)}<span>${name}</span></button>`).join("");

function setRingStyle(style) {
  ringStyle = RING_STYLES.some(([name]) => name === style) ? style : DEFAULT_RING_STYLE;
  for (const button of $$("#ringStyles button")) button.setAttribute("aria-checked", String(button.dataset.style === ringStyle));
}
setRingStyle(ringStyle);
$("#ringStyles").addEventListener("click", (e) => {
  const button = e.target.closest("button");
  if (!button) return;
  setRingStyle(button.dataset.style);
  saveTheme();
});

function setThemeSlider(id, value) {
  const input = $("#" + id);
  input.value = value;
  input.oninput();
}

$("#themeSize").addEventListener("input", saveTheme);
$("#themeTransparency").addEventListener("input", saveTheme);
$("#themePresets").addEventListener("click", (e) => {
  const button = e.target.closest("button");
  if (!button) return;
  setThemeSlider("themeSize", button.dataset.size);
  saveTheme();
});
$("#themeReset").addEventListener("click", () => {
  setThemeSlider("themeSize", 100);
  setThemeSlider("themeTransparency", 0);
  setRingStyle(DEFAULT_RING_STYLE);
  saveTheme();
});

// MARK: - Tests

function report(el, r) {
  el.className = "result " + (r.ok ? "ok" : "bad");
  el.textContent = r.ok ? `It works. It answered in ${r.ms} ms.` : `That didn't work: ${r.error}` + (r.logid ? ` (logid ${r.logid})` : "");
}

async function testVoice(el) {
  const value = voiceValue(), e = value.engines[0];
  if (!e.apiKey && !(e.appId && e.accessToken)) {
    el.className = "result bad";
    el.textContent = "Add a key first.";
    return;
  }
  el.className = "result";
  el.textContent = "Testing…";
  await save("voice", value);
  report(el, await dial("voice.test", { engine: e }));
}

async function testJev(el) {
  const value = jevValue();
  if (!value.apiKey) {
    el.className = "result bad";
    el.textContent = "Add a key first.";
    return;
  }
  el.className = "result";
  el.textContent = "Testing…";
  await save("jev", value);
  report(el, await dial("jev.test", { jev: value }));
}

$("#voiceTest").addEventListener("click", () => testVoice($("#voiceResult")));
$("#quickVoiceTest").addEventListener("click", () => testVoice($("#quickVoiceResult")));
$("#jevTest").addEventListener("click", () => testJev($("#jevResult")));
$("#quickJevTest").addEventListener("click", () => testJev($("#quickJevResult")));

// What the dial would do, in words.
function verdict(r) {
  const name = r.appName || "an app";
  const actions = {
    switch_app: `Switch to ${name}`, open_app: `Open ${name}`, scroll_up: "Scroll up", scroll_down: "Scroll down",
    page_top: "Go to the top", page_bottom: "Go to the bottom", close_window: "Close the window",
  };
  if (r.intent !== "command") return `Type “${r.text}”`;
  return actions[r.action] || "Nothing: it heard a command but couldn't tell which";
}

async function tryIt() {
  const text = $("#tryText").value.trim();
  if (!text) return;
  $("#tryResult").hidden = false;
  $("#tryWhat").textContent = "Thinking…";
  $("#tryWhy").textContent = "";
  const r = await dial("decide.try", { text });
  $("#tryWhat").textContent = verdict(r);
  const by = r.source === "jev" ? "Jev decided" + (r.confidence ? `, ${Math.round(r.confidence * 100)}% sure` : "") : "Plain rules decided";
  $("#tryWhy").textContent = by + (r.message ? `. ${r.message}` : ".");
}
$("#tryButton").addEventListener("click", tryIt);
$("#tryText").addEventListener("keydown", (e) => { if (e.key === "Enter") tryIt(); });
$("#tryChips").addEventListener("click", (e) => {
  const chip = e.target.closest("button");
  if (!chip) return;
  $("#tryText").value = chip.textContent;
  tryIt();
});

// MARK: - Ring

// "2026-11-03 10:12" in words.
function when(last) {
  const then = new Date(last.replace(" ", "T"));
  if (isNaN(then)) return last;
  const day = (d) => new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const days = Math.round((day(new Date()) - day(then)) / 86400000);
  if (days <= 0) return "today";
  if (days === 1) return "yesterday";
  if (days < 30) return days + " days ago";
  return last.slice(0, 10);
}

let learnedCount = 0;
async function loadRing() {
  const r = await dial("ring.get");
  const list = $("#learned");
  list.innerHTML = "";
  learnedCount = r.apps.length;
  $("#forget").hidden = !r.apps.length;
  $("#learnedHelp").hidden = !r.apps.length;
  disarmForget();
  if (!r.apps.length) {
    list.innerHTML = '<li class="empty">Nothing yet. Click an app on the ring, or say “switch to …”.</li>';
    return;
  }
  const most = Math.max(...r.apps.map((a) => a.count), 1);
  for (const a of r.apps) {
    const li = document.createElement("li");
    li.innerHTML = '<span class="name"></span><span class="bar"><div></div></span><span class="count"></span><span class="when"></span>';
    li.children[0].textContent = a.name || a.id;
    li.children[0].title = a.id;
    li.children[1].firstChild.style.width = (a.count / most * 100) + "%";
    li.children[2].textContent = a.count.toFixed(1);
    li.children[3].textContent = when(a.last);
    list.appendChild(li);
  }
}

// Forgetting can't be undone, so it takes a second click.
let forgetTimer;
function disarmForget() {
  clearTimeout(forgetTimer);
  const button = $("#ringReset");
  button.dataset.armed = "";
  button.textContent = "Forget all";
  button.classList.remove("danger");
  $("#ringResetCancel").hidden = true;
}
$("#ringReset").addEventListener("click", async () => {
  const button = $("#ringReset");
  if (!button.dataset.armed) {
    button.dataset.armed = "yes";
    button.textContent = `Forget ${learnedCount} ${learnedCount === 1 ? "app" : "apps"}`;
    button.classList.add("danger");
    $("#ringResetCancel").hidden = false;
    forgetTimer = setTimeout(disarmForget, 6000);
    return;
  }
  await dial("ring.reset");
  loadRing();
});
$("#ringResetCancel").addEventListener("click", disarmForget);

// MARK: - Start

(async () => {
  try {
    await loadConfig();
  } catch (e) {
    // The rest of the app still works, and says what's wrong.
    showProblem(e.message);
  }
  await refreshStatus();
  const start = location.hash.slice(1);
  if (start && $("#nav button[data-view='" + start + "']")) show(start);
  setInterval(refreshStatus, 3000);
})();
