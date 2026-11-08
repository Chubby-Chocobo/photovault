/**
 * member-link.cjs - How a member repo points back to its workspace: the committed marker
 * `.adf-workspace.json`, the workspace's docs dir, and the attached workspace a member session sees.
 *
 * Reads only; nothing is written here and nothing spawns a process. The marker is data a member
 * repo carries, so every field is validated before any caller uses it.
 *
 * @module member-link
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { parseRemoteUrl, canonicalUrl } = require('./git-remote-url.cjs');
const { NAME_RE, validateOrg, isObject } = require('./workspace-manifest-validate.cjs');
const { readTextCapped } = require('./read-text-capped.cjs');
const { loadManifest } = require('./workspace-manifest.cjs');
const { docsDirFor } = require('./system-map.cjs');

const MARKER_FILE = '.adf-workspace.json';
const MAX_BYTES = 64 * 1024;
const MAX_CONFIG_BYTES = 1024 * 1024;
const MAX_DIRS = 20;
const HOST_RE = /^[a-z0-9][a-z0-9.-]*$/;

const isName = (v) => typeof v === 'string' && NAME_RE.test(v);

/** True when the manifest has the canonical `repo` URL a marker needs. */
function canWriteMarker(manifest) {
  return Boolean(manifest) && typeof manifest.repo === 'string' && canonicalUrl(manifest.repo) === manifest.repo;
}

/** The marker file text for a component of the workspace described by `manifest`. Throws when the manifest cannot back a marker. */
function renderMarker({ manifest, component }) {
  if (!canWriteMarker(manifest)) throw new Error('the manifest needs a canonical https "repo" URL to write a member marker');
  if (!isName(component)) throw new Error('the marker component must be a component name');
  const marker = {
    adf: 1,
    workspace: manifest.repo,
    host: parseRemoteUrl(manifest.repo).host,
    org: [...manifest.org],
    ...(manifest.client ? { client: manifest.client } : {}),
    ...(manifest.product ? { product: manifest.product } : {}),
    component,
  };
  return `${JSON.stringify(marker, null, 2)}\n`;
}

function validMarker(v) {
  const parsed = typeof v.workspace === 'string' && canonicalUrl(v.workspace) === v.workspace ? parseRemoteUrl(v.workspace) : null;
  return Boolean(parsed) && v.host === parsed.host && HOST_RE.test(v.host)
    && validateOrg(v.org).length === 0
    && [v.client, v.product].every((x) => x === undefined || isName(x))
    && isName(v.component);
}

/**
 * @param {string} text Content of a `.adf-workspace.json`
 * @returns {{ ours: boolean, marker: object|null }} `ours` = a JSON object with `"adf": 1`; `marker` is
 *   set only when every field is valid. A file without `"adf": 1` is someone else's.
 */
function readMarker(text) {
  let value;
  try { value = JSON.parse(text); } catch { return { ours: false, marker: null }; }
  if (!isObject(value) || value.adf !== 1) return { ours: false, marker: null };
  return { ours: true, marker: validMarker(value) ? value : null };
}

/**
 * The marker of the member at `dir`.
 * @returns {{ kind: 'absent'|'unreadable'|'foreign'|'ours', marker?: object|null, text?: string }}
 *   `unreadable`: a symlink, a directory, an oversized file or a read error; callers leave it alone.
 */
function readMarkerFile(dir) {
  const file = path.join(dir, MARKER_FILE);
  let stat;
  try { stat = fs.lstatSync(file); } catch (err) { return { kind: err && err.code === 'ENOENT' ? 'absent' : 'unreadable' }; }
  if (!stat.isFile() || stat.size > MAX_BYTES) return { kind: 'unreadable' };
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return { kind: 'unreadable' }; }
  const { ours, marker } = readMarker(text);
  return { kind: ours ? 'ours' : 'foreign', marker, text };
}

/** A docs dir as the posix, relative text written into CLAUDE.md files (`docs` when empty, absolute or escaping). */
const docsPosix = (docsRel) => path.posix.normalize(docsDirFor(docsRel).split(path.sep).join('/')).replace(/\/+$/, '');

/** `paths.docs` of the ADF project at `dir`, read from its config file (no process.chdir, no throw); `docs` when unset. */
function docsRelOf(dir) {
  try {
    const text = readTextCapped(path.join(dir, '.claude', 'config', 'adf-config.json'), MAX_CONFIG_BYTES);
    const config = text === null ? null : JSON.parse(text);
    return docsDirFor(config && config.paths && config.paths.docs);
  } catch { return 'docs'; }
}

/** Entries of `permissions.additionalDirectories` in the project's settings.local.json (strings only). */
function additionalDirectories(baseDir) {
  try {
    const text = readTextCapped(path.join(baseDir, '.claude', 'settings.local.json'), MAX_CONFIG_BYTES);
    if (text === null) return [];
    const dirs = JSON.parse(text).permissions.additionalDirectories;
    return Array.isArray(dirs) ? dirs.filter((d) => typeof d === 'string' && d && !/[\u0000-\u001f\u007f]/.test(d)).slice(0, MAX_DIRS) : [];
  } catch { return []; }
}

/**
 * The workspace a member session has attached: an `additionalDirectories` entry that holds a valid
 * adf-workspace.json of the marker's product (or whose `repo` is the marker's workspace).
 * @returns {{ dir: string, manifest: object }|null}
 */
function attachedWorkspace(baseDir, marker) {
  for (const entry of additionalDirectories(baseDir)) {
    const dir = path.resolve(baseDir, entry.startsWith('~/') ? path.join(os.homedir(), entry.slice(2)) : entry);
    const { manifest } = loadManifest(dir);
    if (!manifest) continue;
    if ((marker.product && manifest.product === marker.product) || manifest.repo === marker.workspace) return { dir, manifest };
  }
  return null;
}

module.exports = { MARKER_FILE, canWriteMarker, renderMarker, readMarker, readMarkerFile, docsPosix, docsRelOf, additionalDirectories, attachedWorkspace };
