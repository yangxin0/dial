"use strict";

// Every call to the app: `await dial(op, args)`, a POST to /api/<op>
// served next to the pages (settings/api.go).
async function dial(op, args = {}) {
  const res = await fetch("/api/" + op, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(args) });
  if (!res.ok) throw new Error(await res.text());
  return res.json();
}

// Wails' runtime drags the window by the header (--wails-draggable).
import("/wails/runtime.js").catch(() => {});

const $ = (s, root = document) => root.querySelector(s);
const $$ = (s, root = document) => [...root.querySelectorAll(s)];

let config = {};

// MARK: - Pages

function show(view) {
  for (const b of $$("#nav button")) b.classList.toggle("on", b.dataset.view === view);
  for (const v of $$(".view")) v.classList.toggle("on", v.id === view);
  if (view === "setup") refreshStatus();
  if (view === "dial") loadRing();
}
$("#nav").addEventListener("click", (e) => { const b = e.target.closest("button"); if (b) show(b.dataset.view); });
document.addEventListener("click", (e) => {
  const go = e.target.closest("[data-go]");
  if (go) show(go.dataset.go);
  const open = e.target.closest("[data-open]");
  if (open) dial("open", { what: open.dataset.open });
  const showKey = e.target.closest("button.show");
  if (showKey) {
    const input = showKey.parentElement.querySelector("input");
    input.type = input.type === "password" ? "text" : "password";
    showKey.textContent = input.type === "password" ? "Show" : "Hide";
  }
});

// MARK: - Status

async function refreshStatus() {
  const s = await dial("status");
  document.body.classList.toggle("not-mac", s.os !== "darwin");
  $("#chk-core").className = s.core.running ? "ok" : "";
  $("#chk-voice").className = s.voice ? "ok" : "";
  $("#chk-jev").className = s.jev ? "ok" : "warn";
  const d = s.dial || {};
  const perms = $("#chk-permissions");
  const sub = $("#permissions-sub");
  if (!d.connected) {
    perms.className = "";
    sub.textContent = "Open Dial: it reports its Accessibility and Microphone grants here.";
  } else if (d.accessibility && d.microphone) {
    perms.className = "ok";
    sub.textContent = "Accessibility and the Microphone are both allowed.";
  } else {
    perms.className = "warn";
    const missing = [];
    if (!d.accessibility) missing.push("Accessibility (System Settings ▸ Privacy & Security ▸ Accessibility ▸ Dial). If Dial is already on there, remove it with − and add it again: a rebuilt ad-hoc build is a new app to macOS. Run make signing-identity once so the grant survives rebuilds");
    if (!d.microphone) missing.push("the Microphone (asked on the first recording)");
    sub.textContent = "Still needed: " + missing.join(" and ") + ".";
  }
  $("#version").textContent = s.version;
  $("#configPath").textContent = s.config;
}

// MARK: - Config

function engine() {
  const engines = (config.voice && config.voice.engines) || [];
  return engines[0] || { name: "豆包", type: "volcengine", apiKey: "", appId: "", accessToken: "", resourceId: "volc.seedasr.sauc.duration" };
}

async function loadConfig() {
  config = await dial("config.get");
  const e = engine();
  for (const input of $$("#engine [data-field]")) input.value = e[input.dataset.field] || "";
  const j = config.jev || {};
  for (const input of $$("#jevForm [data-field]")) input.value = j[input.dataset.field] || "";
  $("#hotwords").value = ((config.voice && config.voice.hotwords) || []).join("\n");
  setRange("commandThreshold", config.commandThreshold ?? 0.6, (v) => Number(v).toFixed(2));
  setRange("appThreshold", config.appThreshold ?? 0.5, (v) => Number(v).toFixed(2));
  const ring = config.ring || {};
  setRange("ringSize", ring.size ?? 8, (v) => v);
  setRange("halfLife", ring.halfLifeDays ?? 14, (v) => v + " d");
  const theme = config.theme || {};
  setRange("themeSize", Math.round((theme.size ?? 1) * 100), (v) => v + "%");
  setRange("themeTransparency", Math.round((theme.transparency ?? 0) * 100), (v) => v + "%");
  setRingStyle(theme.ringStyle ?? DEFAULT_RING_STYLE);
}

function setRange(id, value, format) {
  const input = $("#" + id);
  input.value = value;
  $("#" + id + "Value").textContent = format(value);
  input.dataset.format = "";
  input.oninput = () => { $("#" + id + "Value").textContent = format(input.value); };
}

function voiceValue() {
  const e = { ...engine() };
  for (const input of $$("#engine [data-field]")) e[input.dataset.field] = input.value.trim();
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
function saveSoon(key, value, delay = 300) {
  clearTimeout(saveTimers[key]);
  saveTimers[key] = setTimeout(async () => {
    await dial("config.set", { key, value });
    config[key] = value;
  }, delay);
}

for (const input of $$("#engine [data-field], #hotwords")) input.addEventListener("input", () => saveSoon("voice", voiceValue()));
for (const input of $$("#jevForm [data-field]")) input.addEventListener("input", () => saveSoon("jev", jevValue()));
$("#commandThreshold").addEventListener("change", (e) => saveSoon("commandThreshold", Number(e.target.value)));
$("#appThreshold").addEventListener("change", (e) => saveSoon("appThreshold", Number(e.target.value)));
$("#ringSize").addEventListener("change", () => saveSoon("ring", { size: Number($("#ringSize").value), halfLifeDays: Number($("#halfLife").value) }));
$("#halfLife").addEventListener("change", () => saveSoon("ring", { size: Number($("#ringSize").value), halfLifeDays: Number($("#halfLife").value) }));

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
  el.textContent = r.ok ? `OK, ${r.ms} ms` : `Failed: ${r.error}` + (r.logid ? ` (logid ${r.logid})` : "");
}

$("#voiceTest").addEventListener("click", async () => {
  const el = $("#voiceResult");
  el.className = "result";
  el.textContent = "Testing…";
  await dial("config.set", { key: "voice", value: voiceValue() });
  report(el, await dial("voice.test", { engine: voiceValue().engines[0] }));
});

$("#jevTest").addEventListener("click", async () => {
  const el = $("#jevResult");
  el.className = "result";
  el.textContent = "Testing…";
  await dial("config.set", { key: "jev", value: jevValue() });
  report(el, await dial("jev.test", { jev: jevValue() }));
});

async function tryIt() {
  const text = $("#tryText").value.trim();
  if (!text) return;
  $("#tryResult").textContent = "…";
  const r = await dial("decide.try", { text });
  const lines = [`intent: ${r.intent} (${r.source}${r.confidence ? ", " + Number(r.confidence).toFixed(2) : ""})`];
  if (r.intent === "command") lines.push(`action: ${r.action}` + (r.appName ? ` → ${r.appName}` : ""));
  else lines.push(`type: ${r.text}`);
  if (r.message) lines.push(r.message);
  $("#tryResult").textContent = lines.join("\n");
}
$("#tryButton").addEventListener("click", tryIt);
$("#tryText").addEventListener("keydown", (e) => { if (e.key === "Enter") tryIt(); });

// MARK: - Ring

async function loadRing() {
  const r = await dial("ring.get");
  const body = $("#learned tbody");
  body.innerHTML = "";
  if (!r.apps.length) {
    body.innerHTML = '<tr><td class="empty">Nothing learned yet: turn the ring or say “switch to …”.</td></tr>';
    return;
  }
  for (const a of r.apps) {
    const tr = document.createElement("tr");
    tr.innerHTML = `<td></td><td class="count"></td><td class="when"></td>`;
    tr.children[0].textContent = a.name || a.id;
    tr.children[0].title = a.id;
    tr.children[1].textContent = a.count.toFixed(1);
    tr.children[2].textContent = a.last;
    body.appendChild(tr);
  }
}
$("#ringReset").addEventListener("click", async () => { await dial("ring.reset"); loadRing(); });

// MARK: - Start

(async () => {
  await loadConfig();
  await refreshStatus();
  setInterval(() => { if ($("#setup").classList.contains("on")) refreshStatus(); }, 3000);
})();
