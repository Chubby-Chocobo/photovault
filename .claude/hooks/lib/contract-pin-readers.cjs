/**
 * contract-pin-readers.cjs - Where each directory pins another repo: submodule gitlinks, Cargo git
 * dependencies and npm git URLs. Local files and one `git ls-tree` only: no network, no fetch.
 *
 * Handles the listed TOML forms line by line (not a TOML parser). Every URL passes through
 * stripCredentials; a stripped credential sets `credentialInUrl` and the value is dropped.
 * Malformed files come back as `unreadable` entries (file and line, never content), never a throw.
 *
 * @module contract-pin-readers
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { parseGitmodules } = require('./repo-shape-detector.cjs');
const { canonicalUrl, stripCredentials } = require('./git-remote-url.cjs');
const { gitOut } = require('./drift-git.cjs');

const MAX_FILE_BYTES = 1024 * 1024;
// A longer line is skipped and its file reported unreadable: real manifests never have one, and regexes cannot be interrupted
const MAX_LINE_CHARS = 4096;
const MAX_SPEC_CHARS = 2048;
const SHA_RE = /^[0-9a-f]{40}$/i;
const VERSION_TAG_RE = /^v?\d+(\.\d+)+/;
const NPM_SECTIONS = ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies'];
const NPM_GIT_FORM_RE = /^(?:(?:git\+)?(?:https?|ssh|git):\/\/|(?:github|gitlab|bitbucket):)/i;
const NPM_OWNER_REPO_RE = /^[A-Za-z0-9][\w.-]*\/[\w.-]+$/;
const NPM_NOT_GIT_RE = /^(?:npm|workspace|file|link|portal|patch):|\.(?:tgz|tar\.gz|zip)(?:\?.*)?$|\/(?:tarball|zipball)(?:\/|$)/i;

const DEP_SECTION_RE = /^(?:workspace\.)?(?:dev-|build-)?dependencies$/;
const DEP_TABLE_RE = /^(?:workspace\.)?(?:dev-|build-)?dependencies\.([\w-]+)$/;
const TARGET_DEP_RE = /^target\..+?\.(?:dev-|build-)?dependencies(?:\.([\w-]+))?$/;

/** The reference fields shared by every source; the raw URL is dropped here. */
function describeRef(rawUrl, ref, refKind) {
  const url = stripCredentials(rawUrl);
  const pinned = refKind === 'commit' || refKind === 'tag';
  return { url, ref, refKind, pinned, ...(pinned ? {} : { reason: refKind === 'branch' || refKind === 'range' ? refKind : 'none' }), credentialInUrl: url !== rawUrl };
}

/**
 * @param {unknown} spec A package.json dependency value
 * @returns {{ url: string, ref: string, refKind: 'commit'|'tag'|'branch'|'range'|'none', pinned: boolean, reason?: 'branch'|'range'|'none', credentialInUrl: boolean }|null}
 *   null when the value is not a git dependency (registry range, alias, file, tarball)
 */
function classifyNpmRef(spec) {
  if (typeof spec !== 'string' || spec.length > MAX_SPEC_CHARS) return null;
  const text = spec.trim();
  const hash = text.indexOf('#');
  const base = hash < 0 ? text : text.slice(0, hash);
  const ref = hash < 0 ? '' : text.slice(hash + 1);
  if (!base || NPM_NOT_GIT_RE.test(base)) return null;
  const url = NPM_OWNER_REPO_RE.test(base) ? `github:${base}` : base;
  if (!NPM_GIT_FORM_RE.test(url) || !canonicalUrl(url)) return null;
  const refKind = !ref ? 'none' : SHA_RE.test(ref) ? 'commit' : VERSION_TAG_RE.test(ref) ? 'tag' : ref.startsWith('semver:') ? 'range' : 'branch';
  return describeRef(url, ref, refKind);
}

function cargoDepFrom(name, keys) {
  const [ref, refKind] = keys.rev ? [keys.rev, 'commit'] : keys.tag ? [keys.tag, 'tag'] : keys.branch ? [keys.branch, 'branch'] : ['', 'none'];
  return { source: 'cargo', name, file: 'Cargo.toml', ...describeRef(keys.git, ref, refKind) };
}

function cargoKeys(text) {
  const keys = {};
  for (const m of text.matchAll(/\b(git|tag|rev|branch)\s*=\s*"([^"]*)"/g)) keys[m[1]] = m[2];
  return keys;
}

/** `{ name }` for a `[dependencies.<name>]` table, `{ name: null }` for a dependency list, else null. */
function dependencySection(header) {
  const h = header.trim();
  if (DEP_SECTION_RE.test(h)) return { name: null };
  const m = DEP_TABLE_RE.exec(h) || TARGET_DEP_RE.exec(h);
  return m ? { name: m[1] || null } : null;
}

/**
 * @param {string} text Cargo.toml content
 * @returns {{ pins: object[], badLines: number[] }} git dependencies, and lines that could not be read
 */
function parseCargoGitDeps(text) {
  const pins = [];
  const badLines = [];
  let section = null;
  let table = null;
  const flush = () => {
    if (table && table.keys.git) pins.push(cargoDepFrom(table.name, table.keys));
    table = null;
  };
  String(text || '').split(/\r?\n/).forEach((raw, index) => {
    if (raw.length > MAX_LINE_CHARS) { flush(); section = null; badLines.push(index + 1); return; }
    const line = raw.trim();
    if (!line || line.startsWith('#')) return;
    const header = /^\[([^[\]]+)\]\s*(?:#.*)?$/.exec(line);
    if (header || /^\[\[[^\]]+\]\]/.test(line)) {
      flush();
      section = header ? dependencySection(header[1]) : null;
      if (section && section.name) table = { name: section.name, keys: {} };
      return;
    }
    if (line.startsWith('[') && !line.includes(']')) { flush(); section = null; badLines.push(index + 1); return; }
    if (!section) return;
    if (table) { Object.assign(table.keys, cargoKeys(line.replace(/\s#.*$/, ''))); return; }
    const inline = /^"?([\w-]+)"?\s*=\s*\{(.*)\}\s*(?:#.*)?$/.exec(line);
    if (inline) {
      const keys = cargoKeys(inline[2]);
      if (keys.git) pins.push(cargoDepFrom(inline[1], keys));
    } else if (/=\s*\{/.test(line)) badLines.push(index + 1);
  });
  flush();
  return { pins, badLines };
}

/** @returns {{ text: string }|{ error: true }|null} null when the file does not exist */
function loadText(dir, file) {
  const full = path.join(dir, file);
  try {
    const stat = fs.statSync(full);
    if (!stat.isFile()) return null;
    if (stat.size > MAX_FILE_BYTES) return { error: true };
    return { text: fs.readFileSync(full, 'utf8') };
  } catch (err) {
    return err && err.code === 'ENOENT' ? null : { error: true };
  }
}

function readCargoPins(dir) {
  const loaded = loadText(dir, 'Cargo.toml');
  if (!loaded) return { pins: [], unreadable: [] };
  if (loaded.error) return { pins: [], unreadable: [{ file: 'Cargo.toml' }] };
  const { pins, badLines } = parseCargoGitDeps(loaded.text);
  return { pins, unreadable: badLines.map((line) => ({ file: 'Cargo.toml', line })) };
}

function readNpmPins(dir) {
  const loaded = loadText(dir, 'package.json');
  if (!loaded) return { pins: [], unreadable: [] };
  const bad = { pins: [], unreadable: [{ file: 'package.json' }] };
  if (loaded.error) return bad;
  let pkg;
  try { pkg = JSON.parse(loaded.text); } catch { return bad; }
  if (!pkg || typeof pkg !== 'object' || Array.isArray(pkg)) return bad;
  const pins = [];
  for (const section of NPM_SECTIONS) {
    const deps = pkg[section];
    if (!deps || typeof deps !== 'object' || Array.isArray(deps)) continue;
    for (const [name, spec] of Object.entries(deps)) {
      const found = classifyNpmRef(spec);
      if (found) pins.push({ source: 'npm', name, file: 'package.json', ...found });
    }
  }
  return { pins, unreadable: [] };
}

/** One `git ls-tree` call resolves the gitlink sha of every submodule path. */
function readSubmodulePins(dir, { timeoutMs } = {}) {
  const loaded = loadText(dir, '.gitmodules');
  if (!loaded) return { pins: [], unreadable: [] };
  if (loaded.error) return { pins: [], unreadable: [{ file: '.gitmodules' }] };
  const lines = loaded.text.split(/\r?\n/);
  const unreadable = lines.flatMap((l, i) => (l.length > MAX_LINE_CHARS ? [{ file: '.gitmodules', line: i + 1 }] : []));
  const subs = parseGitmodules(lines.filter((l) => l.length <= MAX_LINE_CHARS).join('\n'));
  if (subs.length === 0) return { pins: [], unreadable };
  const raw = gitOut(dir, ['ls-tree', '-z', 'HEAD', '--', ...subs.map((s) => s.path)], { timeoutMs, raw: true });
  if (raw === null) return { pins: [], unreadable: [...unreadable, { file: '.gitmodules' }] };
  const shas = new Map();
  for (const record of raw.split('\0')) {
    const m = /^160000 commit ([0-9a-f]{40,64})\t(.+)$/s.exec(record);
    if (m) shas.set(m[2], m[1]);
  }
  const pins = subs.map((s) => ({
    source: 'submodule', name: s.name, path: s.path, file: '.gitmodules',
    ...describeRef(s.url, shas.get(s.path) || '', shas.has(s.path) ? 'commit' : 'none'),
  }));
  return { pins, unreadable };
}

/**
 * @param {string} dir Directory to read
 * @param {{ timeoutMs?: number }} [opts]
 * @returns {{ pins: object[], unreadable: { file: string, line?: number }[] }}
 */
function readPins(dir, opts = {}) {
  const parts = [readSubmodulePins(dir, opts), readCargoPins(dir), readNpmPins(dir)];
  return { pins: parts.flatMap((p) => p.pins), unreadable: parts.flatMap((p) => p.unreadable) };
}

module.exports = { classifyNpmRef, parseCargoGitDeps, readSubmodulePins, readCargoPins, readNpmPins, readPins };
