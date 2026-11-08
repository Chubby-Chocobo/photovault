/**
 * workspace-init.cjs - `workspace init`: write the files a workspace (or monorepo) needs, once.
 *
 * Idempotent: it computes every output, then writes only what is missing or, for the two managed
 * ignore blocks, out of date, and reports each as written, updated or kept. It never writes inside
 * a member. Credentials found in an origin URL are never stored or printed; the command that
 * removes them is printed instead and `--fix-remotes` runs it.
 *
 * `--archetype <id>` seeds the system map with that archetype's roles and stores its id; an existing map is kept as it is.
 * `<docs>/conventions/contracts.md` (the contracts policy) is written from the template when missing and then belongs to the project.
 *
 * @module workspace-init
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { MANIFEST_FILE, roleDirsOf, loadManifest, validateManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { mapPath, validateSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { nestedRepos } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { stripCredentials, ownerOf } = require('../../../../hooks/lib/git-remote-url.cjs');
const { seedMap } = require('./system-map-seed.cjs');
const { archetypeOption } = require('./archetypes.cjs');
const { monorepoIdentity } = require('./seed-map-command.cjs');
const { readMembers, remoteFixes, seedOrg, umbrellaRepo, ownerOutsideOrg } = require('./workspace-members.cjs');
const { planBlocks } = require('./workspace-ignore-blocks.cjs');
const { originOf, setOrigin, setUrlCommand } = require('./workspace-git.cjs');
const { renderInit } = require('./workspace-init-report.cjs');
const { planDirectPush } = require('./workspace-direct-push.cjs');
const { list, jsonText, fail, usageError, identityError } = require('./workspace-util.cjs');

const BOOTSTRAP_SH = '#!/usr/bin/env sh\nexec node "$(dirname "$0")/.claude/skills/workspace/scripts/workspace.cjs" bootstrap --cwd "$(dirname "$0")" "$@"\n';
const CONTRACTS_TEMPLATE = path.join(__dirname, '..', '..', 'templates', 'contracts.md');
const errorCode = (err) => (err && err.code ? err.code : 'error');

/** Write `content` (text, or a function that builds it only when needed) to `rel` when absent; returns the output record. */
function writeOnce(root, rel, content, { mode, dry }) {
  const file = path.join(root, rel);
  if (fs.existsSync(file)) return { path: rel, status: 'kept' };
  const text = typeof content === 'function' ? content() : content;
  if (!dry) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text, mode ? { mode } : undefined);
    if (mode) fs.chmodSync(file, mode);
  }
  return { path: rel, status: 'written' };
}

/** Apply `step` and turn a thrown fs error into a failed record, so later outputs still run. */
function attempt(rel, step) {
  try { return step(); } catch (err) {
    return { path: rel, status: 'failed', error: err && err.reportable ? err.message : `cannot write ${rel} (${errorCode(err)})` };
  }
}

/** The seeded map as text; an invalid one is never written. */
function seededMapText(rel, seedArgs) {
  const { map } = seedMap(seedArgs);
  const { errors } = validateSystemMap(map, { manifest: seedArgs.manifest || null });
  if (errors.length === 0) return jsonText(map);
  throw Object.assign(new Error(`${rel}: the seeded map is invalid, not written: ${errors.join('; ')}`), { reportable: true });
}

function writeBlock(root, block, dry) {
  return attempt(block.file, () => {
    if (block.next !== null && !dry) fs.writeFileSync(path.join(root, block.file), block.next);
    return { path: block.file, status: block.status };
  });
}

const relPath = (root, file) => path.relative(root, file).split(path.sep).join('/');

/** `<docs>/conventions/contracts.md`, written once from the template; the docs dir is the one the map lives in. */
function contractsOutput(root, mapRel, dry) {
  const rel = `${path.posix.dirname(path.posix.dirname(mapRel))}/conventions/contracts.md`;
  return attempt(rel, () => writeOnce(root, rel, () => fs.readFileSync(CONTRACTS_TEMPLATE, 'utf8'), { dry }));
}

/** Members per owner, in org order, so an owner that brings one odd repo stands out in the dry run. */
function memberCounts(orgList, members) {
  const counts = new Map(orgList.map((o) => [o.toLowerCase(), 0]));
  for (const m of members) {
    const key = (m.repo ? ownerOf(m.repo) || '' : '').toLowerCase();
    if (counts.has(key)) counts.set(key, counts.get(key) + 1);
  }
  return orgList.map((o) => ({ owner: o, members: counts.get(o.toLowerCase()) }));
}

/** "name (owner)" for each member whose repo owner is not in org: check warns about them, so init says it first. */
function outsideOrg(manifest) {
  return manifest.members.flatMap((m) => {
    const owner = ownerOutsideOrg(m, manifest.org);
    return owner ? [`${m.name} (${owner})`] : [];
  });
}

function manifestFor(root, roleDirs, opts) {
  const found = readMembers(root, roleDirs);
  const umbrella = originOf(root);
  const stripped = umbrella ? stripCredentials(umbrella) : null;
  const given = list(opts.org);
  const orgList = given.length > 0 ? given : seedOrg(stripped, found.origins);
  const repo = umbrellaRepo(stripped);
  const manifest = {
    version: 1, ...(opts.client ? { client: opts.client } : {}), ...(opts.product ? { product: opts.product } : {}),
    org: orgList, ...(repo ? { repo } : {}), roleDirs, members: found.members,
  };
  const seeded = given.length === 0;
  return { manifest, notes: found.notes, org: { list: orgList, seeded, ...(seeded ? { members: memberCounts(orgList, found.members) } : {}) } };
}

function initWorkspace({ root, docsRel, opts, loaded, roleDirs, archetype }) {
  const dry = Boolean(opts['dry-run']);
  const notes = [];
  let manifest = loaded.manifest;
  let org = null;
  if (!manifest) {
    const built = manifestFor(root, roleDirs, opts);
    const { errors } = validateManifest(built.manifest);
    if (errors.length > 0) return fail(errors.map((e) => `${e}${built.org.list.length === 0 ? ' (pass --org a,b: no owner could be read from the origins)' : ''}`));
    ({ manifest, org } = built);
    notes.push(...built.notes);
  } else {
    const listed = new Set(manifest.members.map((m) => m.path));
    const unlisted = nestedRepos(root, roleDirsOf(manifest)).filter((p) => !listed.has(p));
    if (unlisted.length > 0) notes.push(`nested repos not in the manifest (add them to ${MANIFEST_FILE}): ${unlisted.join(', ')}`);
  }
  const outside = outsideOrg(manifest);
  if (outside.length > 0) notes.push(`owner not in org, so not trusted: ${outside.join(', ')}; add an owner to org only if the team trusts it`);

  const mapRel = relPath(root, mapPath(root, docsRel));
  const outputs = [
    attempt(MANIFEST_FILE, () => (loaded.manifest ? { path: MANIFEST_FILE, status: 'kept' } : writeOnce(root, MANIFEST_FILE, jsonText(manifest), { dry }))),
    ...planBlocks(root, roleDirsOf(manifest)).map((block) => writeBlock(root, block, dry)),
    attempt('bootstrap.sh', () => writeOnce(root, 'bootstrap.sh', BOOTSTRAP_SH, { mode: 0o755, dry })),
    attempt(mapRel, () => writeOnce(root, mapRel, () => seededMapText(mapRel, { root, manifest, archetype }), { dry })),
    contractsOutput(root, mapRel, dry),
  ];
  const directPush = planDirectPush(root, { dry });
  return finish({ mode: 'workspace', archetype, root, opts, outputs, org, notes, fixes: remoteFixes(root, manifest.members), members: manifest.members.map((m) => m.name), directPush });
}

function initMonorepo({ root, docsRel, opts, archetype }) {
  const dry = Boolean(opts['dry-run']);
  const mapRel = relPath(root, mapPath(root, docsRel));
  const outputs = [
    attempt(mapRel, () => writeOnce(root, mapRel, () => seededMapText(mapRel, { root, archetype, ...monorepoIdentity(root, opts) }), { dry })),
    contractsOutput(root, mapRel, dry),
  ];
  return finish({ mode: 'monorepo', archetype, root, opts, outputs, org: null, notes: [], fixes: [], members: [] });
}

function finish({ mode, archetype, root, opts, outputs, org, notes, fixes, members, directPush }) {
  const dry = Boolean(opts['dry-run']);
  const applied = fixes.map((fix) => {
    const run = Boolean(opts['fix-remotes']) && !dry;
    const done = run ? setOrigin(path.join(root, fix.path), fix.url) : { ok: false };
    return { path: fix.path, command: setUrlCommand(fix.path, fix.url), applied: done.ok, ...(run && !done.ok ? { error: done.error } : {}) };
  });
  const errors = [...outputs.filter((o) => o.status === 'failed').map((o) => o.error), ...(directPush && directPush.error ? [directPush.error] : []), ...applied.filter((a) => a.error).map((a) => `${a.command} failed: ${a.error}`)];
  const result = {
    ok: errors.length === 0, mode, dryRun: dry, outputs, org, members, notes, remoteFixes: applied, errors,
    ...(archetype ? { archetype: { id: archetype.id, applied: outputs.some((o) => o.path.endsWith('system-map.json') && o.status === 'written') } } : {}),
    ...(directPush ? { directPush } : {}),
  };
  return { code: errors.length > 0 ? 1 : 0, result, text: renderInit(result) };
}

/** @param {{ root: string, docsRel: string, opts: object }} ctx */
function run({ root, docsRel, opts }) {
  const loaded = loadManifest(root);
  if (loaded.errors.length > 0) return fail(loaded.errors.map((e) => `${e}; fix it before running init`));
  const roleDirs = roleDirsOf(loaded.manifest);
  const workspace = Boolean(loaded.manifest) || Boolean(opts.workspace) || nestedRepos(root, roleDirs).length > 0;
  const bad = identityError(opts, { forMap: !workspace });
  if (bad) return usageError(bad);
  const chosen = archetypeOption(opts);
  if (chosen.error) return usageError(chosen.error);
  return (workspace ? initWorkspace : initMonorepo)({ root, docsRel, opts, loaded, roleDirs, archetype: chosen.archetype });
}

module.exports = { run };
