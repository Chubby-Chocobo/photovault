/**
 * scope-context.cjs - Loads manifest, system map and the resolved scope in one call, for the
 * session and subagent hooks. Never throws: a broken file shows up as messages in the result.
 *
 * @module scope-context
 */

'use strict';

const { loadManifest } = require('./workspace-manifest.cjs');
const { loadSystemMap } = require('./system-map.cjs');
const { resolveScope, expandContracts } = require('./plan-scope.cjs');

/**
 * @param {{ baseDir: string, config: object, resolvedPlan: object, cwd?: string }} args
 * @returns {{ manifest: object|null, manifestErrors: string[], map: object|null, mapErrors: string[],
 *   scope: ReturnType<typeof resolveScope>, expansion: { path: string, component: string, reason: string }[] }}
 */
function loadScopeContext({ baseDir, config, resolvedPlan, cwd = process.cwd() }) {
  const loaded = loadManifest(baseDir);
  const mapped = loadSystemMap(baseDir, config && config.paths && config.paths.docs, { manifest: loaded.manifest });
  const scope = resolveScope({ root: baseDir, map: mapped.map, manifest: loaded.manifest, resolvedPlan, cwd });
  return {
    manifest: loaded.manifest,
    manifestErrors: loaded.errors,
    map: mapped.map,
    mapErrors: mapped.errors,
    scope,
    expansion: expandContracts(mapped.map, scope.paths),
  };
}

/** Scope paths followed by the contract consumers and producers they pull in, unique. Empty unless the project has a manifest or a system map. */
function agentScopePaths(ctx) {
  if (!ctx.manifest && !ctx.map) return [];
  return [...new Set([...ctx.scope.paths, ...ctx.expansion.map((e) => e.path)])];
}

module.exports = { loadScopeContext, agentScopePaths };
