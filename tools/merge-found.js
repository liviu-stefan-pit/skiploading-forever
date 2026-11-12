// Builds Shared.lua from the saved files other players send you.
//
//   1. Put each player's WTF\Account\<account>\SavedVariables\SkipLoading.lua into tools\contrib\,
//      renamed to one file per player (anna.lua, bob.lua ...). A newer file from the same player
//      replaces their old one. Your own file can go in there too.
//   2. Run:  node merge-found.js
//
// Only nodes a player gathered themselves are taken: imported points and nodes that reached them
// through an earlier Shared.lua are skipped. Shared.lua is rebuilt from scratch on every run, so
// running it twice never counts anything twice.
//
//   node merge-found.js fileA.lua fileB.lua     use these files instead of tools\contrib
//   node merge-found.js --out some\Shared.lua   write somewhere else
const fs = require("fs");
const path = require("path");

// Two players' records of the same node type this close together are one node. In units of 0.01%
// of the map: about 8 yards in an ordinary zone, 15 in the largest.
const SAME = 15;

// ---- reader for the Lua the game writes into saved variable files
function parseLua(src) {
  let i = 0;
  const fail = what => { throw new Error(`${what} at character ${i}`); };
  function skip() {
    for (;;) {
      while (i < src.length && /\s/.test(src[i])) i++;
      if (src.startsWith("--", i)) { while (i < src.length && src[i] !== "\n") i++; } else return;
    }
  }
  function string() {
    const quote = src[i++];
    let out = "";
    while (i < src.length && src[i] !== quote) {
      if (src[i] === "\\") {
        const c = src[++i];
        if (c === "n") out += "\n";
        else if (/\d/.test(c)) { const m = src.slice(i).match(/^\d{1,3}/)[0]; out += String.fromCharCode(+m); i += m.length - 1; }
        else out += c;
        i++;
      } else out += src[i++];
    }
    i++;
    return out;
  }
  function value() {
    skip();
    const c = src[i];
    if (c === "{") return table();
    if (c === '"' || c === "'") return string();
    const m = src.slice(i).match(/^(true|false|nil|-?(?:0x[\da-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+))/);
    if (!m) fail("unexpected text");
    i += m[0].length;
    return m[0] === "true" ? true : m[0] === "false" ? false : m[0] === "nil" ? null : Number(m[0]);
  }
  function table() {
    i++; // {
    const out = {};
    let n = 1;
    for (;;) {
      skip();
      if (src[i] === "}") { i++; return out; }
      let key;
      if (src[i] === "[") { i++; key = value(); skip(); if (src[i++] !== "]") fail("expected ]"); skip(); if (src[i++] !== "=") fail("expected ="); }
      else {
        const m = src.slice(i).match(/^([A-Za-z_]\w*)\s*=(?!=)/);
        if (m) { key = m[1]; i += m[0].length; }
      }
      const v = value();
      out[key === undefined ? n++ : key] = v;
      skip();
      if (src[i] === "," || src[i] === ";") i++;
    }
  }
  const globals = {};
  for (;;) {
    skip();
    if (i >= src.length) return globals;
    const m = src.slice(i).match(/^([A-Za-z_]\w*)\s*=/);
    if (!m) fail("expected a variable");
    i += m[0].length;
    globals[m[1]] = value();
  }
}

// ---- collect
const args = process.argv.slice(2);
let out = path.join(__dirname, "..", "Shared.lua");
const files = [];
for (let a = 0; a < args.length; a++) {
  if (args[a] === "--out") out = args[++a]; else files.push(args[a]);
}
if (files.length === 0) {
  const dir = path.join(__dirname, "contrib");
  if (fs.existsSync(dir)) for (const f of fs.readdirSync(dir).sort()) if (f.toLowerCase().endsWith(".lua")) files.push(path.join(dir, f));
}

const found = { ores: {}, herbs: {} }; // kind -> map -> list of merged nodes
let players = 0;
for (const file of files) {
  let ds;
  try { ds = parseLua(fs.readFileSync(file, "utf8")).SkipLoadingForeverDataSet; }
  catch (e) { console.log(`${path.basename(file)}: could not be read (${e.message}), skipped`); continue; }
  if (!ds || typeof ds !== "object") { console.log(`${path.basename(file)}: no SkipLoadingForeverDataSet in it, skipped`); continue; }
  let count = 0;
  for (const kind of ["ores", "herbs"]) {
    for (const [map, zone] of Object.entries(ds[kind] || {})) {
      if (!zone || typeof zone !== "object") continue;
      for (const [coord, node] of Object.entries(zone)) {
        if (!node || typeof node !== "object" || node.shared) continue; // imported, or not found by this player
        const valid = (typeof node.id === "number" || typeof node.id === "string") &&
          Number.isFinite(node.seen) && Number.isFinite(node.last) && Number.isFinite(Number(coord));
        if (!valid) continue;
        const c = Number(coord);
        const p = { x: Math.floor(c / 1e6), y: Math.floor((c % 1e6) / 100), id: node.id,
                    seen: node.seen, last: node.last, build: Number(node.build) || 0, by: 1 };
        const list = ((found[kind][map] = found[kind][map] || []));
        const same = list.find(q => q.id === p.id && Math.hypot(q.x - p.x, q.y - p.y) <= SAME);
        if (same) {
          if (p.seen > same.seen) { same.x = p.x; same.y = p.y; } // keep the spot of whoever saw it most
          same.seen += p.seen; same.by++;
          if (p.last > same.last) { same.last = p.last; same.build = p.build; }
        } else list.push(p);
        count++;
      }
    }
  }
  players++;
  console.log(`${path.basename(file)}: ${count} nodes found by this player`);
}

// ---- write
const luaId = id => typeof id === "number" ? String(id) : JSON.stringify(id);
const total = { ores: 0, herbs: 0 };
let body = "";
for (const kind of ["ores", "herbs"]) {
  body += `\t${kind} = {\n`;
  for (const map of Object.keys(found[kind]).sort((a, b) => a - b)) {
    body += `\t\t[${map}] = {\n`;
    const used = new Set();
    for (const p of found[kind][map].sort((a, b) => a.x - b.x || a.y - b.y)) {
      let key = p.x * 1e6 + p.y * 100;
      while (used.has(key)) key++;
      used.add(key);
      body += `\t\t\t[${key}]={id=${luaId(p.id)},seen=${p.seen},last=${p.last},build=${p.build}},\n`;
      total[kind]++;
    }
    body += `\t\t},\n`;
  }
  body += `\t},\n`;
}
fs.writeFileSync(out,
  `-- Generated by tools/merge-found.js. Do not edit.\n` +
  `-- Nodes other players found on Forever. The addon merges each new version into the dataset once.\n` +
  `SkipLoadingShared = {\n\tstamp = ${Math.floor(Date.now() / 1000)},\n\tplayers = ${players},\n` + body + `}\n`);
console.log(`wrote ${out}: ${total.ores} ore and ${total.herbs} herb locations from ${players} player file(s)`);
