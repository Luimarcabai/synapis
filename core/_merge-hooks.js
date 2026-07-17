#!/usr/bin/env node
// Sinapsis v4.8.1 — idempotent hook wiring for ~/.claude/settings.json
// Usage: node _merge-hooks.js <settings.template.json> <settings.json>
//
// Fixes audit finding #1 (iAmasters OS, 2026-07-17): both installers used to
// print "merge hooks manually" and register NOTHING when settings.json already
// existed — which it almost always does — leaving a ghost install with the
// whole learning pipeline inert and no warning anywhere.
//
// Behaviour:
//   - settings.json missing      -> created from the template (_-prefixed meta
//                                   keys stripped).
//   - settings.json exists       -> deep-merge: every existing entry is
//                                   preserved untouched; template hooks are
//                                   appended only when their `command` is not
//                                   already registered for that event (dedup
//                                   by trimmed command string). Idempotent.
//   - UTF-8 BOM (#16)            -> stripped on read, never re-emitted.
//   - malformed settings.json    -> exit 1, file left untouched.
//   - before modifying           -> timestamped backup written next to the
//                                   file; write is atomic (tmp + rename).

const fs = require("fs");
const path = require("path");

const [templatePath, settingsPath] = process.argv.slice(2);
if (!templatePath || !settingsPath) {
  console.error("usage: node _merge-hooks.js <settings.template.json> <settings.json>");
  process.exit(1);
}

function stripMeta(obj) {
  if (Array.isArray(obj)) return obj.map(stripMeta);
  if (obj && typeof obj === "object") {
    const out = {};
    for (const [k, v] of Object.entries(obj)) {
      if (k.startsWith("_")) continue;
      out[k] = stripMeta(v);
    }
    return out;
  }
  return obj;
}

function readJson(p) {
  let raw = fs.readFileSync(p, "utf8");
  if (raw.charCodeAt(0) === 0xFEFF) raw = raw.slice(1); // BOM-safe (#16)
  return JSON.parse(raw);
}

function writeAtomic(p, data) {
  const tmp = p + ".tmp-" + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + "\n");
  fs.renameSync(tmp, p);
}

const template = stripMeta(readJson(templatePath));

if (!fs.existsSync(settingsPath)) {
  writeAtomic(settingsPath, template);
  console.log("created: settings.json written from template");
  process.exit(0);
}

let settings;
try {
  settings = readJson(settingsPath);
} catch (e) {
  console.error("settings.json is not valid JSON — left untouched (" + e.message + ")");
  process.exit(1);
}
if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
  console.error("settings.json root is not an object — left untouched");
  process.exit(1);
}

let added = 0;
settings.hooks = settings.hooks || {};

for (const [event, templateGroups] of Object.entries(template.hooks || {})) {
  if (settings.hooks[event] !== undefined && !Array.isArray(settings.hooks[event])) {
    console.error("skip " + event + ": existing entry is not an array");
    continue;
  }
  if (!Array.isArray(settings.hooks[event])) settings.hooks[event] = [];

  const registered = new Set();
  for (const group of settings.hooks[event]) {
    const hooks = group && Array.isArray(group.hooks) ? group.hooks : [];
    for (const h of hooks) {
      if (h && typeof h.command === "string") registered.add(h.command.trim());
    }
  }

  for (const tg of templateGroups) {
    const missing = (tg.hooks || []).filter(
      (h) => typeof h.command === "string" && !registered.has(h.command.trim())
    );
    if (!missing.length) continue;
    const group = tg.matcher !== undefined ? { matcher: tg.matcher, hooks: missing } : { hooks: missing };
    settings.hooks[event].push(group);
    missing.forEach((h) => registered.add(h.command.trim()));
    added += missing.length;
  }
}

if (added === 0) {
  console.log("ok: all Sinapsis hooks already wired — nothing to do");
  process.exit(0);
}

const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
const backup = settingsPath + ".pre-sinapsis-" + stamp;
fs.copyFileSync(settingsPath, backup);
writeAtomic(settingsPath, settings);
console.log(
  "merged: " + added + " hook(s) wired, existing entries preserved (backup: " + path.basename(backup) + ")"
);
