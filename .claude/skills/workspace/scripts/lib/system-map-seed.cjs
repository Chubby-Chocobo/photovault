/**
 * system-map-seed.cjs - Build the first system map (or the missing part of one) from what is on disk.
 *
 * Workspace: one component per member outside contracts/, one contract per member under contracts/.
 * Monorepo: components from the build-file directories under services/ and apps/, contracts from
 * each contracts/<dir>. Roles come from the name, then from the detected stack. `consumes` comes
 * from `.gitmodules` entries, Cargo git dependencies and npm git URLs that point at a contract's repo. With `existing`, only entries that are
 * missing are added and nothing already in the map is edited, except that an `archetype` merges its
 * role aliases into `roles` and sets `archetype`.
 *
 * @module system-map-seed
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { DEFAULT_ROLES, roleFor } = require('../../../../hooks/lib/system-map.cjs');
const { roleDirComponents, parseGitmodules } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { sameRepo } = require('../../../../hooks/lib/git-remote-url.cjs');
const { readCargoPins, readNpmPins } = require('../../../../hooks/lib/contract-pin-readers.cjs');
const { readTextCapped } = require('../../../../hooks/lib/read-text-capped.cjs');
const { NAME_RE, memberPath } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { detectStack, STACK_ROLES } = require('./component-stack.cjs');
const { applyArchetype } = require('./archetypes.cjs');
const { scanContractKind } = require('./contract-kind-scan.cjs');

const MAX_GITMODULES_BYTES = 256 * 1024;

/** A directory name as a component or member name, or null when nothing valid is left. */
function slugName(dirName) {
  const slug = String(dirName).toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+|-+$/g, '');
  return NAME_RE.test(slug) ? slug : null;
}

function subdirs(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory() && !e.name.startsWith('.')).map((e) => e.name).sort();
  } catch { return []; }
}

/** What exists, with its placement in the map ({ member } or { path }) and directory on disk. */
function discover(root, manifest) {
  if (manifest) {
    const place = (m) => ({ name: m.name, place: { member: m.name }, dir: memberPath(root, m), repo: m.repo });
    const isContract = (m) => m.path.startsWith('contracts/');
    return { components: manifest.members.filter((m) => !isContract(m)).map(place), contracts: manifest.members.filter(isContract).map(place) };
  }
  const components = roleDirComponents(root).map((rel) => ({ name: slugName(path.posix.basename(rel)), place: { path: rel }, dir: path.join(root, rel) }));
  const contracts = subdirs(path.join(root, 'contracts')).map((d) => ({ name: slugName(d), place: { path: `contracts/${d}` }, dir: path.join(root, 'contracts', d) }));
  return { components: components.filter((c) => c.name), contracts: contracts.filter((c) => c.name) };
}

const placeKey = (item) => (item.member !== undefined ? `member:${item.member}` : `path:${item.path}`);

function submoduleUrls(dir) {
  const text = readTextCapped(path.join(dir, '.gitmodules'), MAX_GITMODULES_BYTES);
  return text === null ? [] : parseGitmodules(text).map((s) => s.url);
}

/** URLs a directory pins: submodules, Cargo git dependencies and npm git dependencies (credentials already stripped for the last two). */
function pinnedUrls(dir) {
  return [...submoduleUrls(dir), ...readCargoPins(dir).pins.map((p) => p.url), ...readNpmPins(dir).pins.map((p) => p.url)];
}

/**
 * @param {{ root: string, manifest?: object|null, existing?: object|null, org?: string[], client?: string, product?: string, archetype?: object }} opts
 *   archetype is a loaded archetype (see archetypes.cjs)
 *   existing is the map as stored (placement fields, not derived ones)
 * @returns {{ map: object, added: string[] }}
 */
function seedMap({ root, manifest = null, existing = null, org, client, product, archetype = null }) {
  const base = existing || { roles: DEFAULT_ROLES };
  const shaped = archetype ? applyArchetype(base, archetype, DEFAULT_ROLES) : base;
  const roles = shaped.roles || DEFAULT_ROLES;
  const found = discover(root, manifest);
  const names = new Set(((existing && existing.components) || []).map((c) => c.name));
  const ids = new Set(((existing && existing.contracts) || []).map((c) => c.id));
  const places = new Set([...((existing && existing.components) || []), ...((existing && existing.contracts) || [])].map(placeKey));
  const fresh = (item, taken) => !taken.has(item.name) && !places.has(placeKey(item.place));

  const contracts = found.contracts.filter((c) => fresh(c, ids))
    .map((c) => ({ id: c.name, kind: scanContractKind(c.dir), ...c.place }));

  // Contract repos by id: the manifest member's repo in a workspace, a stored repo in a monorepo
  const members = new Map(((manifest && manifest.members) || []).map((m) => [m.name, m]));
  const repoOf = (c) => (manifest ? (members.get(c.member) || {}).repo : c.repo);
  const repos = new Map([...((existing && existing.contracts) || []), ...contracts].map((c) => [c.id, repoOf(c)]).filter(([, repo]) => repo));

  const components = found.components.filter((c) => fresh(c, names)).map((c) => {
    const stack = detectStack(c.dir);
    const role = roleFor(c.name, roles);
    const urls = pinnedUrls(c.dir);
    const consumes = [...repos].filter(([, repo]) => urls.some((url) => sameRepo(url, repo))).map(([id]) => id);
    return {
      name: c.name, ...c.place, role: role === 'unknown' ? STACK_ROLES[stack] : role,
      ...(stack !== 'unknown' ? { stack } : {}), ...(consumes.length > 0 ? { consumes } : {}),
    };
  });

  const byName = (key) => (a, b) => a[key].localeCompare(b[key]);
  components.sort(byName('name'));
  contracts.sort(byName('id'));
  const added = [...components.map((c) => `component:${c.name}`), ...contracts.map((c) => `contract:${c.id}`)];
  if (archetype && (!existing || JSON.stringify(shaped) !== JSON.stringify(existing))) added.unshift(`archetype:${archetype.id}`);
  if (existing) {
    return { map: { ...shaped, components: [...(existing.components || []), ...components], contracts: [...(existing.contracts || []), ...contracts] }, added };
  }
  const head = { version: 1, ...(client ? { client } : {}), ...(product ? { product } : {}), ...(!manifest && org && org.length > 0 ? { org } : {}) };
  return { map: { ...head, ...(archetype ? { archetype: archetype.id } : {}), roles, components, contracts }, added };
}

module.exports = { seedMap, slugName };
