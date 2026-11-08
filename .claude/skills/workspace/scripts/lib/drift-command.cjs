/**
 * drift-command.cjs - `workspace drift`: which ref each consumer pins per contract, and which git
 * dependencies are unpinned. Reads local files and a few local git calls; never fetches. Exit 0
 * unless a finding named in `--fail-on` exists. A complete run also refreshes the cached session
 * line, so the next session start is a cache hit. With `--fail-on`, a member that was not cloned
 * also fails the run unless `--allow-missing`, so a CI job without cloned members cannot pass
 * silently.
 *
 * @module drift-command
 */

'use strict';

const { loadManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { loadSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { computeDrift, summarizeDrift } = require('../../../../hooks/lib/contract-drift.cjs');
const { driftTargets, watchedFiles } = require('../../../../hooks/lib/drift-targets.cjs');
const { driftCacheKey, writeCachedDrift } = require('../../../../hooks/lib/drift-cache.cjs');
const { FINDINGS } = require('../../../../hooks/lib/contract-drift-findings.cjs');
const { renderDriftLines } = require('../../../../hooks/lib/contract-drift-render.cjs');
const { list, fail, usageError } = require('./workspace-util.cjs');

/** Finding types present anywhere in the report. */
function presentTypes(result) {
  const found = new Set();
  for (const group of [...result.contracts, ...result.otherGitDeps]) group.findings.forEach((f) => found.add(f.type));
  if (result.missingMembers.length > 0) found.add('member-missing');
  if (result.unreadable.length > 0) found.add('unreadable');
  return found;
}

/**
 * @param {{ root: string, docsRel: string, opts: object }} ctx
 * @returns {{ code: number, result: object, text: string }}
 */
function run({ root, docsRel, opts }) {
  const failOn = list(opts['fail-on']);
  const unknown = failOn.filter((type) => !FINDINGS.includes(type));
  if (unknown.length > 0) return usageError(`--fail-on takes finding names: ${FINDINGS.join(', ')}`);

  const loaded = loadManifest(root);
  if (loaded.errors.length > 0) return fail(loaded.errors.map((e) => `${e}; run workspace.cjs check`));
  const mapped = loadSystemMap(root, docsRel, { manifest: loaded.manifest });
  if (mapped.errors.length > 0) return fail(mapped.errors.map((e) => `${e}; run workspace.cjs check`));
  if (!loaded.manifest && !mapped.map) return fail('no adf-workspace.json and no system map: nothing to compare; run /workspace init');

  const targets = driftTargets({ root, map: mapped.map, manifest: loaded.manifest });
  const key = driftCacheKey(watchedFiles({ root, docsRel, targets }));
  const report = computeDrift({ root, map: mapped.map, manifest: loaded.manifest, budgetMs: Number.POSITIVE_INFINITY, targets });
  if (!report.truncated) writeCachedDrift(root, key, { line: summarizeDrift(report) });
  const present = presentTypes(report);
  const failing = failOn.filter((type) => present.has(type));
  if (failOn.length > 0 && present.has('member-missing') && !opts['allow-missing'] && !failing.includes('member-missing')) failing.push('member-missing');

  const code = failing.length > 0 ? 1 : 0;
  const verdict = failOn.length === 0 ? [] : [
    '',
    failing.length > 0 ? `fail-on: found ${failing.join(', ')} (exit 1)` : `fail-on: none of ${failOn.join(', ')} found`,
  ];
  const text = ['workspace drift', ...renderDriftLines(report), ...verdict].join('\n');
  return { code, result: { ok: code === 0, ...report, failOn, failing }, text };
}

module.exports = { run };
