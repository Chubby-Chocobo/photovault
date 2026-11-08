/**
 * contract-drift.cjs - Contract drift report: which consumers pin each contract repo to which ref,
 * and whether those pins agree. Reads local files and a few local git calls only; the repo of a
 * contract is the one `loadSystemMap` derived from the manifest (never stored twice).
 *
 * @module contract-drift
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { readPins } = require('./contract-pin-readers.cjs');
const { contractReport, otherGroups } = require('./contract-drift-findings.cjs');
const { driftTargets, absOf } = require('./drift-targets.cjs');
const { localHead, originOwnerOf, GIT_TIMEOUT_MS } = require('./drift-git.cjs');
const { SESSION_DRIFT_BUDGET_MS } = require('./drift-cache.cjs');
const { stripCredentials } = require('./git-remote-url.cjs');

const SKIPPED_LINE = 'Contract drift: skipped (slow); run workspace.cjs drift';
const DETAILS = 'Details: /adf-brief or workspace.cjs drift';
const MAX_NAMED = 3;
const SHA_RE = /^[0-9a-f]{40,64}$/i;

/** Owners whose git dependencies count as ours: manifest org, then map org, then the umbrella origin owner. */
function orgsOf({ root, map, manifest }, spendable) {
  for (const list of [manifest && manifest.org, map && map.org]) {
    if (Array.isArray(list) && list.length > 0) return list;
  }
  const owner = spendable() ? originOwnerOf(root) : null;
  return owner ? [owner] : [];
}

/**
 * @param {{ root: string, map?: object|null, manifest?: object|null, budgetMs?: number, targets?: object }} args
 *   map is the joined map from loadSystemMap; targets (from driftTargets) avoids a second scan
 * @returns {{ contracts: object[], otherGitDeps: object[], missingMembers: { name: string, path: string, reason: string }[], unreadable: { path: string, line?: number }[], truncated: boolean }}
 */
function computeDrift({ root, map = null, manifest = null, budgetMs = SESSION_DRIFT_BUDGET_MS, targets = null }) {
  const started = Date.now();
  let truncated = false;
  const spendable = () => {
    if (Date.now() - started < budgetMs) return true;
    truncated = true;
    return false;
  };
  const found = targets || driftTargets({ root, map, manifest });
  const reads = [];
  const skipped = new Set();
  const unreadable = [];
  for (const entry of found.entries) {
    if (!spendable()) { skipped.add(entry.name); continue; }
    const read = readPins(entry.abs, { timeoutMs: GIT_TIMEOUT_MS });
    reads.push({ entry, pins: read.pins });
    for (const u of read.unreadable) unreadable.push({ path: `${entry.rel}/${u.file}`, ...(u.line ? { line: u.line } : {}) });
  }

  const components = (map && map.components) || [];
  const declared = ((map && map.contracts) || []).filter((c) => typeof c.repo === 'string' && c.repo);
  const contracts = declared.map((contract) => {
    const abs = absOf(root, contract.path);
    const head = fs.existsSync(path.join(abs, '.git')) && spendable() ? localHead(abs) : null;
    return contractReport({ ...contract, repo: stripCredentials(contract.repo) }, reads, { components, missingComponents: found.missingComponents, skipped, head });
  });
  const orgs = orgsOf({ root, map, manifest }, spendable);
  const otherGitDeps = otherGroups(reads, declared.map((c) => c.repo), orgs);
  return { contracts, otherGitDeps, missingMembers: found.missing, unreadable, truncated };
}

function countFindings(result, type) {
  const groups = [...result.contracts, ...result.otherGitDeps];
  return groups.reduce((sum, g) => sum + g.findings.filter((f) => f.type === type).length, 0);
}

function contractPhrase(contract) {
  const rows = contract.consumers.filter((c) => c.ref);
  const refs = new Set(rows.map((c) => c.ref));
  const noun = [...refs].every((r) => SHA_RE.test(r)) ? 'commits' : 'versions';
  const placed = rows.filter((c) => c.atLocalHead !== null);
  const atHead = placed.filter((c) => c.atLocalHead).length;
  const where = placed.length === 0 ? '' : atHead === 0 ? ' (none at local HEAD)' : ` (${atHead} at local HEAD)`;
  return `${contract.id} pinned at ${refs.size} ${noun} across ${rows.length} consumers${where}`;
}

/**
 * @param {ReturnType<typeof computeDrift>} result
 * @returns {string|null} the one session line, or null when there is nothing to say
 */
function summarizeDrift(result) {
  const parts = [];
  const split = result.contracts.filter((c) => c.findings.some((f) => f.type === 'differs'));
  split.slice(0, MAX_NAMED).forEach((c) => parts.push(contractPhrase(c)));
  if (split.length > MAX_NAMED) parts.push(`+${split.length - MAX_NAMED} more contracts with differing pins`);
  const unpinned = countFindings(result, 'unpinned');
  if (unpinned > 0) parts.push(`${unpinned} unpinned git ${unpinned === 1 ? 'dependency' : 'dependencies'}`);
  const withCredentials = countFindings(result, 'credential-in-url');
  if (withCredentials > 0) parts.push(`${withCredentials} ${withCredentials === 1 ? 'URL' : 'URLs'} with embedded credentials`);
  return parts.length > 0 ? `Contract drift: ${parts.join('; ')}. ${DETAILS}` : null;
}

module.exports = { computeDrift, summarizeDrift, countFindings, SKIPPED_LINE };
