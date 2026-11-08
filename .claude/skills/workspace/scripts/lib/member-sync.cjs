/**
 * member-sync.cjs - `workspace.cjs sync [--member <name>] [--check] [--dry-run] [--force] [--from <workspace dir>]`
 *
 * Writes the "system context" block into each component's CLAUDE.md and AGENTS.md (only into the
 * AGENTS.md when the CLAUDE.md imports it), and in a workspace the `.adf-workspace.json` marker at
 * each member root, from the system map. Text outside the block markers is never touched. It only
 * writes files: it never stages, commits, pushes or opens a PR. Members whose instruction files or
 * marker have uncommitted changes, and blocks edited by hand, are skipped unless `--force`. `--check` writes nothing and fails when a block or marker is out of date.
 *
 * @module member-sync
 */

'use strict';

const fs = require('fs');
const { fail, usageError, needsYes } = require('./workspace-util.cjs');
const { loadPlan, sourceOf, planRows } = require('./member-sync-plan.cjs');

const REPOS_HINT = 'run "node .claude/skills/workspace/scripts/workspace.cjs repos --changed" to see members to commit';
const COMMIT_HINT = 'review the changes with git diff, then commit them';
const MARKER_NEEDS_SYNC = new Set(['missing', 'changed']);

/** Writes each file; a new marker is created exclusively so a symlink planted in its place is refused. */
function applyWrites(row) {
  for (const w of row.writes) {
    try {
      fs.writeFileSync(w.abs, w.content, w.create ? { flag: 'wx' } : undefined);
    } catch (err) {
      return { ...row, action: 'failed', reason: `cannot write ${w.rel} (${err && err.code ? err.code : 'error'})` };
    }
  }
  return { ...row, action: 'written' };
}

const label = (r) => (r.member && r.component && r.member !== r.component ? `${r.member}/${r.component}` : r.member || r.component);

/** The block column: the CLAUDE.md state, with the AGENTS.md state when that file carries a block too. */
function blockCell(r) {
  if (r.viaAgents && r.block === 'current') return `${r.agentsBlock} via AGENTS.md`;
  const agents = r.agentsBlock && r.agentsBlock !== 'n/a' ? `AGENTS.md ${r.agentsBlock === 'symlink' ? 'is a symlink, skipped' : r.agentsBlock}` : null;
  return [r.block, agents].filter(Boolean).join(' + ') || '-';
}

function tableOf(rows) {
  const cells = rows.map((r) => [label(r), blockCell(r), r.action, r.files.join(', ') || '-', r.reason || '']);
  const widths = [0, 1, 2].map((i) => Math.max(...cells.map((c) => c[i].length), ['member', 'block', 'action'][i].length));
  const line = (c) => `${c[0].padEnd(widths[0])}  ${c[1].padEnd(widths[1])}  ${c[2].padEnd(widths[2])}  ${c[3]}${c[4] ? `  (${c[4]})` : ''}`.trimEnd();
  return [line(['member', 'block', 'action', 'files', '']), ...cells.map(line)];
}

function textOf(rows, { check, dryRun, hint }, counts, problems) {
  const lines = tableOf(rows);
  lines.push('', `${counts.written + counts.wouldWrite} ${dryRun ? 'to write' : 'written'}, ${counts.unchanged} unchanged, ${counts.skipped} skipped${counts.failed > 0 ? `, ${counts.failed} failed` : ''}`);
  if (check) {
    const uncounted = rows.filter((r) => r.agentsBlock === 'missing' && !r.outOfDate).length;
    lines.push(problems > 0 ? `${problems} out of date: run sync` : `all blocks are current${uncounted > 0 ? ` (${uncounted} AGENTS.md without a block are not counted: they hold only ADF's installer block or sit next to a CLAUDE.md with its own)` : ''}`);
  }
  if (dryRun) lines.push('Nothing written.');
  else {
    lines.push('Nothing was committed or pushed.');
    if (counts.written > 0) lines.push(hint);
  }
  return lines.join('\n');
}

/** @param {{ root: string, docsRel: string, opts: object }} ctx */
function run({ root, docsRel, opts }) {
  if (opts._.length > 1) return usageError('sync takes no positional arguments');
  const loaded = loadPlan({ root, docsRel, opts });
  if (loaded.outcome) return loaded.outcome;
  const { plan } = loaded;
  const check = Boolean(opts.check);
  const dryRun = check || Boolean(opts['dry-run']);
  plan.source = sourceOf(plan.base, plan.mapRel);

  let rows;
  try {
    rows = planRows(plan, { force: Boolean(opts.force), dryRun });
  } catch (err) {
    return fail([`nothing written: ${err && err.message ? err.message : 'a block did not render'}`]);
  }
  const needsSync = (r) => r.outOfDate || MARKER_NEEDS_SYNC.has(r.marker);
  const problems = check ? rows.filter(needsSync).length : 0;
  if (!dryRun) rows = rows.map((r) => (r.action === 'write' ? applyWrites(r) : r));

  const reported = rows.map(({ writes, outOfDate, viaAgents, ...r }) => r);
  const count = (action) => reported.filter((r) => r.action === action).length;
  const counts = { written: count('written'), wouldWrite: count('would-write'), unchanged: count('unchanged'), skipped: count('skipped'), failed: count('failed') };
  const ok = counts.failed === 0 && problems === 0;
  return {
    code: ok ? 0 : 1,
    result: { ok, mode: plan.manifest ? 'workspace' : 'monorepo', check, dryRun, source: plan.source, counts, rows: reported },
    text: textOf(rows, { check, dryRun, hint: plan.manifest && plan.whole ? REPOS_HINT : COMMIT_HINT }, counts, problems),
  };
}

/** `run` behind the confirmation gate: writing needs `--yes`; `--check` and `--dry-run` do not. */
const runConfirmed = (ctx) => (ctx.opts.check ? run(ctx) : needsYes(run)(ctx));

module.exports = { run, runConfirmed };
