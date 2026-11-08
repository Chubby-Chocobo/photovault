/**
 * workspace-session-context.cjs - The session-start lines for a workspace or monorepo: what the
 * project is made of, whether search reaches the members, and the scope to work in.
 *
 * Best effort and fast: file reads only, nothing written, one failing builder never hides the
 * others. The one exception is the contract drift line: on a cache miss it may spawn git within a
 * 2 s budget and stores the answer in os.tmpdir(); a cache hit reads files only. To add a line,
 * write a builder `(ctx) => string[]` and list it in LINE_BUILDERS.
 *
 * @module workspace-session-context
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { readBlock } = require('./managed-text-block.cjs');
const { roleDirsOf, memberState } = require('./workspace-manifest.cjs');
const { SAFE_TEXT } = require('./system-map.cjs');
const { loadScopeContext } = require('./scope-context.cjs');
const { staleBlocksLine, memberContextLines } = require('./member-context-session.cjs');
const { readTextCapped } = require('./read-text-capped.cjs');

const BOOTSTRAP_CMD = 'node .claude/skills/workspace/scripts/workspace.cjs bootstrap';
const SETTINGS_REL = '.claude/settings.local.json';
const MAX_MEMBERS_CHECKED = 500;
const MAX_LISTED = 8;
const MAX_SETTINGS_BYTES = 1024 * 1024;

const count = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const listed = (items) => (items.length > MAX_LISTED ? `${items.slice(0, MAX_LISTED).join(', ')} +${items.length - MAX_LISTED} more` : items.join(', '));

function workspaceLine(ctx) {
  if (ctx.shapeType !== 'workspace') return [];
  if (ctx.manifestErrors.length > 0) return [`Workspace manifest has ${count(ctx.manifestErrors.length, 'error', 'errors')}; run workspace.cjs check`];
  const manifest = ctx.manifest;
  if (!manifest) return [];
  const name = typeof manifest.product === 'string' && SAFE_TEXT.test(manifest.product) ? manifest.product : path.basename(ctx.root);
  // File checks only, so even a large workspace is checked whole; past the cap the line says so
  const checked = manifest.members.slice(0, MAX_MEMBERS_CHECKED);
  const missing = checked.filter((m) => memberState(ctx.root, m, { git: false }) !== 'cloned').map((m) => m.path);
  const gap = missing.length > 0 ? `; missing: ${listed(missing)}; run "${BOOTSTRAP_CMD}"` : '';
  const partial = checked.length < manifest.members.length ? `; only the first ${checked.length} of ${manifest.members.length} checked` : '';
  return [`Workspace: ${name} (${count(manifest.members.length, 'member', 'members')}${gap}${partial})`];
}

function searchLine(ctx) {
  if (ctx.shapeType !== 'workspace' || !ctx.manifest) return [];
  const block = require('./workspace-ignore-blocks.cjs').BLOCKS.find((b) => b.file === '.ignore');
  let text = '';
  try { text = fs.readFileSync(path.join(ctx.root, '.ignore'), 'utf8'); } catch { /* no file: the block is absent */ }
  const found = readBlock(text, block.markers);
  if (found.state === 'absent') return ['Search: no .ignore block, so Grep from the root skips all members; run /workspace init'];
  if (found.state === 'malformed') return ['Search: .ignore block markers are damaged; repair them, then run /workspace init'];
  const roleDirs = roleDirsOf(ctx.manifest);
  const body = found.body.replace(/\r/g, '');
  if (body === block.lines(roleDirs).join('\n')) return [];
  const have = new Set(body.split('\n'));
  const lacking = roleDirs.filter((d) => !have.has(block.lines([d])[0]));
  return [lacking.length > 0
    ? `Search: .ignore block does not list ${listed(lacking)}; run /workspace init`
    : 'Search: .ignore block is out of date; run /workspace init'];
}

function mapLine(ctx) {
  if (ctx.manifestErrors.length > 0) return [];
  if (ctx.mapErrors.length > 0) return [`System map has ${count(ctx.mapErrors.length, 'error', 'errors')}; run workspace.cjs check`];
  return ctx.map ? [] : ['No system map: run /workspace init'];
}

function storedScope(root) {
  try {
    const text = readTextCapped(path.join(root, SETTINGS_REL), MAX_SETTINGS_BYTES);
    if (text === null) return null;
    const scope = JSON.parse(text).adfScope;
    return scope && typeof scope === 'object' && !Array.isArray(scope) ? scope : null;
  } catch { return null; }
}

const sameSet = (a, b) => a.length === b.length && [...a].sort().every((v, i) => v === [...b].sort()[i]);

function scopeLines(ctx) {
  if (ctx.manifestErrors.length > 0) return [];
  const { scope, expansion } = ctx;
  const lines = [];
  const ignored = scope.dropped > 0 ? `${count(scope.dropped, 'scope entry', 'scope entries')} ignored` : null;
  if (scope.paths.length > 0) {
    const notes = [
      `from ${scope.source}`,
      expansion.length > 0 ? `contract change adds ${listed(expansion.map((e) => e.path))}` : null,
      ignored,
    ].filter(Boolean).join('; ');
    lines.push(`Scope: ${listed(scope.paths)} (${notes}). Search and edit inside these paths first.`);
  } else if (ignored) {
    lines.push(`Scope: none usable (${ignored}); scope lists paths, component names or contract ids, check with workspace.cjs scope`);
  }
  const stored = storedScope(ctx.root);
  const paths = stored && Array.isArray(stored.paths) ? stored.paths.filter((p) => typeof p === 'string') : [];
  if (stored && !sameSet(paths, scope.paths)) {
    const plan = typeof stored.plan === 'string' && SAFE_TEXT.test(stored.plan) ? stored.plan : 'another scope';
    lines.push(`Scope settings in ${SETTINGS_REL} are for ${plan}; run workspace.cjs scope --write-settings --yes or --clear-settings --yes`);
  }
  return lines;
}

/** Contract drift in one line: served from the tmpdir cache, computed under a budget on a miss. */
function driftLine(ctx) {
  if (ctx.manifestErrors.length > 0 || (!ctx.manifest && !ctx.map)) return [];
  const { map, manifest, root } = ctx;
  const hasContracts = Boolean(map && (map.contracts || []).length > 0);
  if (!manifest && !hasContracts && !fs.existsSync(path.join(root, '.gitmodules'))) return [];
  const { driftTargets, watchedFiles } = require('./drift-targets.cjs');
  // Read at call time, not at module load: tests raise SESSION_DRIFT_BUDGET_MS on the module object
  const { driftCacheKey, readCachedDrift, writeCachedDrift, SESSION_DRIFT_BUDGET_MS, TRUNCATED_DRIFT_TTL_MS } = require('./drift-cache.cjs');
  const { computeDrift, summarizeDrift, SKIPPED_LINE } = require('./contract-drift.cjs');
  const targets = driftTargets({ root, map, manifest });
  const key = driftCacheKey(watchedFiles({ root, docsRel: ctx.config && ctx.config.paths && ctx.config.paths.docs, targets }));
  const hit = readCachedDrift(root, key);
  if (hit) return typeof hit.line === 'string' ? [hit.line] : [];
  const result = computeDrift({ root, map, manifest, budgetMs: SESSION_DRIFT_BUDGET_MS, targets });
  const line = result.truncated ? SKIPPED_LINE : summarizeDrift(result);
  writeCachedDrift(root, key, { line }, result.truncated ? { ttlMs: TRUNCATED_DRIFT_TTL_MS } : {});
  return line ? [line] : [];
}

const LINE_BUILDERS = [workspaceLine, searchLine, mapLine, driftLine, staleBlocksLine, scopeLines];

/**
 * @param {{ baseDir: string, config: object, shapeType: string, resolvedPlan: object, cwd?: string }} args
 * @returns {{ lines: string[] }} empty unless the project is a workspace or a monorepo; never throws
 */
function buildWorkspaceContext({ baseDir, config, shapeType, resolvedPlan, cwd = process.cwd() }) {
  if (shapeType !== 'workspace' && shapeType !== 'monorepo') return { lines: [] };
  let loaded;
  try { loaded = loadScopeContext({ baseDir, config, resolvedPlan, cwd }); } catch { return { lines: [] }; }
  const ctx = { root: baseDir, shapeType, config, ...loaded };
  const lines = [];
  for (const build of LINE_BUILDERS) {
    try { lines.push(...build(ctx)); } catch { /* one builder failing leaves the others */ }
  }
  return { lines };
}

module.exports = { buildWorkspaceContext, memberContextLines };
