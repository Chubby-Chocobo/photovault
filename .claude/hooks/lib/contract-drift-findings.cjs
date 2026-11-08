/**
 * contract-drift-findings.cjs - Pure part of the drift report: turns the pins read from each
 * directory into per-contract consumer rows and findings. No fs, no git, no credentials: rows
 * carry the stripped URL only.
 *
 * @module contract-drift-findings
 */

'use strict';

const { sameRepo, canonicalUrl, ownerOf } = require('./git-remote-url.cjs');

const FINDINGS = ['differs', 'unpinned', 'not-at-local-head', 'unmapped-consumer', 'credential-in-url', 'member-missing', 'unreadable'];

function pinRow(entry, pin, { mapped, head }) {
  const atLocalHead = pin.source === 'submodule' && head && pin.ref ? pin.ref.toLowerCase() === head.sha.toLowerCase() : null;
  return {
    component: entry.name,
    source: pin.source,
    name: pin.name,
    pinFile: `${entry.rel}/${pin.file}`,
    ref: pin.ref || null,
    refKind: pin.refKind,
    pinned: pin.pinned,
    ...(pin.reason ? { reason: pin.reason } : {}),
    credentialInUrl: pin.credentialInUrl,
    atLocalHead,
    ...(mapped === undefined ? {} : { mapped }),
  };
}

/** Findings of one repo's consumer rows. */
function findingsOf(consumers, head) {
  const findings = [];
  const refs = [...new Set(consumers.map((c) => c.ref).filter(Boolean))];
  if (refs.length > 1) findings.push({ type: 'differs', refs });
  for (const c of consumers) {
    if (c.source && !c.pinned) findings.push({ type: 'unpinned', component: c.component, reason: c.reason });
    if (c.mapped === false) findings.push({ type: 'unmapped-consumer', component: c.component });
    if (c.credentialInUrl) findings.push({ type: 'credential-in-url', component: c.component, source: c.source });
    if (c.atLocalHead === false) findings.push({ type: 'not-at-local-head', component: c.component, ref: c.ref, headSha: head.sha, headDate: head.date });
  }
  return findings;
}

const byRow = (a, b) => a.component.localeCompare(b.component) || String(a.pinFile).localeCompare(String(b.pinFile));

/**
 * @param {{ id: string, kind: string, path: string, repo: string }} contract
 * @param {{ entry: object, pins: object[] }[]} reads
 * @param {{ components: object[], missingComponents: Map<string, string>, skipped: Set<string>, head: { sha: string, date: string }|null }} ctx
 */
function contractReport(contract, reads, { components, missingComponents, skipped, head }) {
  const consumers = [];
  const covered = new Set();
  for (const { entry, pins } of reads) {
    for (const pin of pins) {
      if (!sameRepo(pin.url, contract.repo)) continue;
      const mapped = Boolean(entry.component && (entry.component.consumes || []).includes(contract.id));
      consumers.push(pinRow(entry, pin, { mapped, head }));
      covered.add(entry.name);
    }
  }
  for (const c of components) {
    if (!(c.consumes || []).includes(contract.id) || covered.has(c.name)) continue;
    const note = missingComponents.has(c.name) ? `member ${missingComponents.get(c.name)}` : skipped.has(c.name) ? 'not read (over budget)' : 'no pin found';
    consumers.push({ component: c.name, source: null, pinFile: null, ref: null, pinned: false, atLocalHead: null, note });
  }
  consumers.sort(byRow);
  return { id: contract.id, kind: contract.kind, path: contract.path, repo: contract.repo, head, consumers, findings: findingsOf(consumers, head) };
}

/** In-org git dependencies that are not declared contracts, grouped by repo. */
function otherGroups(reads, contractRepos, orgs) {
  const owners = new Set(orgs.map((o) => String(o).toLowerCase()));
  const groups = new Map();
  for (const { entry, pins } of reads) {
    for (const pin of pins) {
      const repo = canonicalUrl(pin.url);
      const owner = ownerOf(pin.url);
      if (!repo || !owner || !owners.has(owner.toLowerCase()) || contractRepos.some((r) => sameRepo(pin.url, r))) continue;
      if (!groups.has(repo)) groups.set(repo, []);
      groups.get(repo).push(pinRow(entry, pin, { head: null }));
    }
  }
  return [...groups].sort(([a], [b]) => a.localeCompare(b)).map(([repo, rows]) => {
    const consumers = rows.sort(byRow);
    return { repo, consumers, findings: findingsOf(consumers, null) };
  });
}

module.exports = { FINDINGS, contractReport, otherGroups };
