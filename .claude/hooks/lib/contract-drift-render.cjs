/**
 * contract-drift-render.cjs - Plain-text view of a drift report, shared by `workspace.cjs drift`
 * and `/adf-brief`. One block per contract with a consumer table, then in-org git dependencies,
 * members that were not cloned and files that could not be read. Only fields of the report are
 * printed, and the report holds no credentials.
 *
 * @module contract-drift-render
 */

'use strict';

const HEADER = ['component', 'source', 'ref', 'pinned', 'at local HEAD'];
const SHA_RE = /^[0-9a-f]{40,64}$/i;

const shortRef = (ref) => (!ref ? '-' : SHA_RE.test(ref) ? ref.slice(0, 10) : ref);
const yesNo = (value) => (value === null || value === undefined ? '-' : value ? 'yes' : 'no');

function rowCells(c) {
  if (!c.source) return [c.component, '-', '-', c.note || 'no pin found', '-'];
  const pinned = c.pinned ? 'yes' : `no (${c.reason || 'none'})`;
  return [c.component, c.source, shortRef(c.ref), pinned, yesNo(c.atLocalHead)];
}

function table(consumers) {
  const rows = [HEADER, ...consumers.map(rowCells)];
  const widths = HEADER.map((_, i) => Math.max(...rows.map((r) => r[i].length)));
  return rows.map((r) => `  ${r.map((cell, i) => cell.padEnd(widths[i])).join(' | ').trimEnd()}`);
}

function findingsLine(findings) {
  if (findings.length === 0) return '  findings: none';
  const counts = new Map();
  for (const f of findings) counts.set(f.type, (counts.get(f.type) || 0) + 1);
  return `  findings: ${[...counts].map(([type, n]) => (n > 1 ? `${type} x${n}` : type)).join(', ')}`;
}

function contractBlock(c) {
  const head = c.head ? `local HEAD ${c.head.sha.slice(0, 10)}${c.head.date ? ` (${c.head.date})` : ''}` : 'no local clone to compare with';
  const lines = [`${c.id} (${c.kind}) ${c.path}  ${c.repo}`, `  ${head}`];
  if (c.consumers.length > 0) lines.push(...table(c.consumers));
  else lines.push('  no consumers found');
  lines.push(findingsLine(c.findings));
  return lines;
}

/**
 * @param {object} result From computeDrift
 * @returns {string[]} lines without a title
 */
function renderDriftLines(result) {
  const lines = [];
  if (result.truncated) lines.push('Partial result: the time budget ran out before every directory was read.');
  if (result.contracts.length === 0) lines.push('No contract with a repo to compare (a contract needs a repo in the manifest or the map).');
  for (const c of result.contracts) lines.push('', ...contractBlock(c));
  if (result.otherGitDeps.length > 0) {
    lines.push('', 'In-org git dependencies that are not declared contracts:');
    for (const g of result.otherGitDeps) lines.push('', g.repo, ...table(g.consumers), findingsLine(g.findings));
  }
  const byReason = new Map();
  for (const m of result.missingMembers) byReason.set(m.reason, [...(byReason.get(m.reason) || []), `${m.name} (${m.path})`]);
  for (const [reason, members] of byReason) lines.push('', `member-missing (${reason}, pins not read): ${members.join(', ')}`);
  if (result.unreadable.length > 0) {
    lines.push('', `unreadable: ${result.unreadable.map((u) => `${u.path}${u.line ? `:${u.line}` : ''}`).join(', ')}`);
  }
  return lines;
}

module.exports = { renderDriftLines };
