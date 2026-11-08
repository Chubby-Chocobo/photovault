/**
 * workspace-check.cjs - `workspace check`: validate the manifest, the system map and how the
 * workspace sits on disk. Read-only.
 *
 * Errors (exit 1): invalid files, a member without `git`, a symlinked or escaping member path, a
 * member the workspace repo does not ignore. Everything else is a warning. Roles and contract
 * kinds that the map's archetype expects but the map lacks are information and never change the exit code.
 *
 * @module workspace-check
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { MANIFEST_FILE, roleDirsOf, loadManifest, memberState, memberPath } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { loadSystemMap, mapPath } = require('../../../../hooks/lib/system-map.cjs');
const { nestedRepos } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { planBlocks } = require('./workspace-ignore-blocks.cjs');
const { branchOf, ignoreStatus } = require('./workspace-git.cjs');
const { directPushWarnings } = require('./workspace-direct-push.cjs');
const { ownerOutsideOrg } = require('./workspace-members.cjs');
const { archetypeFindings } = require('./archetypes.cjs');

const BLOCK_WARNING = { written: 'has no managed block', updated: 'managed block is out of date', malformed: 'managed block markers are damaged' };

function checkMembers(root, manifest, found) {
  let unknownIgnore = false;
  const rows = manifest.members.map((m) => {
    const state = memberState(root, m);
    const ignored = ignoreStatus(root, m.path);
    if (state === 'symlink') found.errors.push(`member ${m.name}: ${m.path} is a symlink or leaves the workspace`);
    if (state === 'missing') found.warnings.push(`member ${m.name} is not cloned (run /workspace bootstrap)`);
    if (state === 'not-a-repo') found.warnings.push(`member ${m.name}: ${m.path} exists but is not a git repo`);
    if (state === 'remote-mismatch') found.warnings.push(`member ${m.name}: origin differs from the manifest repo`);
    if (ignored === 'not-ignored') found.errors.push(`member ${m.name}: ${m.path} is not ignored by the workspace repo (run /workspace init)`);
    unknownIgnore = unknownIgnore || ignored === 'unknown';
    const owner = ownerOutsideOrg(m, manifest.org);
    if (owner) found.warnings.push(`member ${m.name}: owner ${owner} is not in org`);
    return { name: m.name, path: m.path, state, branch: state === 'cloned' ? branchOf(memberPath(root, m)) : null };
  });
  if (unknownIgnore) found.warnings.push('cannot tell whether members are ignored: the workspace root is not a git repository');
  return rows;
}

function checkLayout(root, manifest, found) {
  const roleDirs = roleDirsOf(manifest);
  for (const block of planBlocks(root, roleDirs)) {
    if (block.status !== 'kept') found.warnings.push(`${block.file} ${BLOCK_WARNING[block.status]} (run /workspace init)`);
  }
  const listed = new Set(manifest.members.map((m) => m.path));
  for (const rel of nestedRepos(root, roleDirs)) {
    if (!listed.has(rel)) found.warnings.push(`${rel} is a git repo under a role dir but not a manifest member`);
  }
}

function render(result) {
  const lines = [`workspace check: ${result.ok ? 'ok' : 'failed'}`];
  if (result.members.length > 0) lines.push(`members (${result.members.length}):`, ...result.members.map((m) => `  ${m.name}  ${m.path}  ${m.state}${m.branch ? `  ${m.branch}` : ''}`));
  if (result.map) lines.push(`map: ${result.map.components} components, ${result.map.contracts} contracts`);
  if (result.errors.length > 0) lines.push('errors:', ...result.errors.map((e) => `  ${e}`));
  if (result.warnings.length > 0) lines.push('warnings:', ...result.warnings.map((w) => `  ${w}`));
  if (result.info.length > 0) lines.push('info:', ...result.info.map((i) => `  ${i}`));
  return lines.join('\n');
}

/** @param {{ root: string, docsRel: string }} ctx */
function run({ root, docsRel }) {
  const loaded = loadManifest(root);
  const found = { errors: [...loaded.errors], warnings: [...loaded.warnings], info: [] };
  const manifestFile = fs.existsSync(path.join(root, MANIFEST_FILE));
  let members = [];
  let map = null;

  if (!manifestFile && !fs.existsSync(mapPath(root, docsRel))) {
    found.errors.push(`neither ${MANIFEST_FILE} nor a system map found; run /workspace init`);
  } else if (!manifestFile || loaded.manifest) {
    const loadedMap = loadSystemMap(root, docsRel, { manifest: loaded.manifest });
    found.errors.push(...loadedMap.errors);
    found.warnings.push(...loadedMap.warnings);
    if (loadedMap.map) {
      map = { components: (loadedMap.map.components || []).length, contracts: (loadedMap.map.contracts || []).length };
      const archetype = archetypeFindings(loadedMap.map);
      found.info.push(...archetype.info);
      found.warnings.push(...archetype.warnings);
    }
  }
  if (loaded.manifest) {
    members = checkMembers(root, loaded.manifest, found);
    checkLayout(root, loaded.manifest, found);
    found.warnings.push(...directPushWarnings(root, docsRel));
  }
  const result = { ok: found.errors.length === 0, errors: found.errors, warnings: found.warnings, info: found.info, members, map };
  return { code: result.ok ? 0 : 1, result, text: render(result) };
}

module.exports = { run };
