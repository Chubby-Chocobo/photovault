/**
 * system-map.cjs - Loader and queries for docs/architecture/system-map.json (components, contracts).
 *
 * In a workspace the map carries `member` (+ optional `subpath`) and the loader derives `path`
 * and `repo` from the manifest; derived values are never stored. Callers are the inverse of
 * `calls`. No cache and no throws: problems come back as messages.
 *
 * @module system-map
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { SAFE_TEXT, VIA, KINDS, validateSystemMap } = require('./system-map-validate.cjs');
const { parseJson } = require('./workspace-manifest-validate.cjs');
const { normalizeDocsRoot } = require('./docs-layout.cjs');
const { MANIFEST_FILE } = require('./repo-shape-detector.cjs');

const MAP_REL = 'architecture/system-map.json';
const MAX_MAP_BYTES = 2 * 1024 * 1024;

const isFile = (p) => { try { return fs.statSync(p).isFile(); } catch { return false; } };

const DEFAULT_ROLES = {
  frontend: ['fe', 'web', 'frontend', 'interface', 'ui'],
  backend: ['be', 'api', 'backend', 'service', 'server'],
  'smart-contract': ['sc', 'contracts', 'contract'],
  engine: ['engine', 'matching-engine'],
  mobile: ['mobile', 'app', 'ios', 'android'],
  infra: ['infra', 'devops', 'deploy'],
  bot: ['bot'],
  sdk: ['sdk', 'lib', 'libs'],
};

/** The docs dir (relative, posix) every map reader and writer uses: `paths.docs` under the shared docs-root rule, else `docs`. */
const docsDirFor = (docsRel) => normalizeDocsRoot(docsRel) || 'docs';

/** Absolute path of the map under the project's docs dir. */
function mapPath(root, docsRel = 'docs') {
  return path.join(root, docsDirFor(docsRel), ...MAP_REL.split('/'));
}

/** Copy of the map with path/repo (and org, client, product) taken from the manifest. */
function joinManifest(map, manifest) {
  const members = new Map(manifest.members.map((m) => [m.name, m]));
  const place = (item) => {
    const member = members.get(item.member);
    const sub = item.subpath && item.subpath !== '.' ? `/${item.subpath}` : '';
    const placed = { ...item, path: `${member.path}${sub}` };
    delete placed.repo; // a stored repo is ignored (validation warns); the manifest is the source
    if (member.repo) placed.repo = member.repo;
    return placed;
  };
  const out = { ...map, org: manifest.org, components: (map.components || []).map(place), contracts: (map.contracts || []).map(place) };
  for (const key of ['client', 'product']) if (manifest[key] !== undefined) out[key] = manifest[key];
  return out;
}

/**
 * @param {string} root Project root
 * @param {string} [docsRel] paths.docs from the ADF config
 * @param {{ manifest?: object|null }} [opts] A valid manifest enables the member join
 * @returns {{ map: object|null, errors: string[], warnings: string[] }} map is null when the file is absent or invalid
 */
function loadSystemMap(root, docsRel = 'docs', { manifest = null } = {}) {
  const file = mapPath(root, docsRel);
  let text;
  try {
    if (fs.statSync(file).size > MAX_MAP_BYTES) return { map: null, errors: ['system-map.json is larger than 2 MB'], warnings: [] };
    text = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err && err.code === 'ENOENT') return { map: null, errors: [], warnings: [] };
    return { map: null, errors: [`system-map.json cannot be read (${err && err.code ? err.code : 'error'})`], warnings: [] };
  }
  // A manifest file that did not load is not "no manifest": monorepo rules would give misleading errors
  if (!manifest && isFile(path.join(root, MANIFEST_FILE))) {
    return { map: null, errors: ['adf-workspace.json is invalid; fix it before the map can be loaded'], warnings: [] };
  }
  const { value: parsed, error } = parseJson(text, 'system-map.json');
  if (error) return { map: null, errors: [error], warnings: [] };
  const { errors, warnings } = validateSystemMap(parsed, { manifest });
  if (errors.length > 0) return { map: null, errors, warnings };
  return { map: manifest ? joinManifest(parsed, manifest) : parsed, errors, warnings };
}

/**
 * Role of a component name: the last "-" segment first, then the whole name, else "unknown".
 * @param {string} name
 * @param {Record<string, string[]>} [roles] Replaces the defaults entirely
 */
function roleFor(name, roles = DEFAULT_ROLES) {
  const lower = String(name || '').toLowerCase();
  const table = roles && typeof roles === 'object' ? roles : DEFAULT_ROLES;
  for (const candidate of [lower.slice(lower.lastIndexOf('-') + 1), lower]) {
    for (const [role, aliases] of Object.entries(table)) {
      if (Array.isArray(aliases) && aliases.some((a) => String(a).toLowerCase() === candidate)) return role;
    }
  }
  return 'unknown';
}

const norm = (rel) => String(rel).replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/+$/, '');

/** Component whose path is the longest prefix of `rel` (posix, relative to the root), or null. */
function componentForPath(map, rel) {
  const target = norm(rel);
  let best = null;
  for (const c of (map && map.components) || []) {
    if (typeof c.path !== 'string') continue;
    if ((target === c.path || target.startsWith(`${c.path}/`)) && (!best || c.path.length > best.path.length)) best = c;
  }
  return best;
}

/** @returns {{ component: object, via: string, topic?: string }[]} components that call `name` (inverse of calls) */
function callersOf(map, name) {
  const out = [];
  for (const c of (map && map.components) || []) {
    for (const call of c.calls || []) {
      if (call.to === name) out.push({ component: c, via: call.via, ...(call.topic ? { topic: call.topic } : {}) });
    }
  }
  return out;
}

/** @returns {object[]} components that consume contract `id` */
function consumersOf(map, id) {
  return ((map && map.components) || []).filter((c) => Array.isArray(c.consumes) && c.consumes.includes(id));
}

module.exports = {
  MAP_REL,
  DEFAULT_ROLES,
  SAFE_TEXT,
  VIA,
  KINDS,
  docsDirFor,
  mapPath,
  loadSystemMap,
  validateSystemMap,
  roleFor,
  componentForPath,
  callersOf,
  consumersOf,
};
