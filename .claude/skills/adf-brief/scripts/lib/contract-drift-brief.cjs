'use strict';

// Contract drift for /adf-brief: the same report as `workspace.cjs drift`, computed under the
// brief budget in workspaces and monorepos that have a system map. Never throws.

const { detectRepoShape } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { loadManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { loadSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const { readProjectSection } = require('../../../../hooks/lib/adf-config-utils.cjs');
const contractDrift = require('../../../../hooks/lib/contract-drift.cjs');
const { BRIEF_DRIFT_BUDGET_MS } = require('../../../../hooks/lib/drift-cache.cjs');
const { renderDriftLines } = require('../../../../hooks/lib/contract-drift-render.cjs');

function skip(warnings, what, count) {
  warnings.push(`contract drift skipped: ${what} has ${count} ${count === 1 ? 'error' : 'errors'}`);
  return null;
}

/**
 * @param {string} root Repository root
 * @param {string[]} warnings Receives one line when the report cannot be built
 * @returns {object|null} the drift report, or null outside workspaces and monorepos with a map
 */
function collectContractDrift(root, warnings) {
  try {
    const { type } = detectRepoShape(root);
    if (type !== 'workspace' && type !== 'monorepo') return null;
    const loadedManifest = type === 'workspace' ? loadManifest(root) : { manifest: null, errors: [] };
    if (loadedManifest.errors.length > 0) return skip(warnings, 'workspace manifest', loadedManifest.errors.length);
    const manifest = loadedManifest.manifest;
    const docs = readProjectSection(root, 'paths').docs;
    const { map, errors } = loadSystemMap(root, typeof docs === 'string' ? docs : 'docs', { manifest });
    if (errors.length > 0) return skip(warnings, 'system map', errors.length);
    if (!map) return null;
    return contractDrift.computeDrift({ root, map, manifest, budgetMs: BRIEF_DRIFT_BUDGET_MS });
  } catch (error) {
    warnings.push(`Contract drift unavailable: ${error && error.code ? error.code : 'error'}`);
    return null;
  }
}

/** @returns {string[]} the text section, empty when there is no report */
function renderContractDrift(drift) {
  if (!drift) return [];
  const body = renderDriftLines(drift);
  while (body[0] === '') body.shift();
  return ['', 'Contract drift:', ...body];
}

module.exports = { collectContractDrift, renderContractDrift };
