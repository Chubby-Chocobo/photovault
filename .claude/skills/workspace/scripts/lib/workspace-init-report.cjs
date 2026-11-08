/**
 * workspace-init-report.cjs - The text `workspace init` prints.
 *
 * @module workspace-init-report
 */

'use strict';

const WOULD = { written: 'would write', updated: 'would update', kept: 'kept', malformed: 'malformed', failed: 'failed' };
const DONE = { written: 'written', updated: 'updated', kept: 'kept', malformed: 'malformed', failed: 'failed' };

/** @param {object} result The init result object */
function renderInit(result) {
  const verbs = result.dryRun ? WOULD : DONE;
  const lines = [`workspace init (${result.mode}${result.dryRun ? ', dry run: nothing written' : ''})`];
  for (const o of result.outputs) lines.push(`  ${verbs[o.status] || o.status}: ${o.path}${o.status === 'malformed' ? ' (managed block markers are damaged; fix by hand, left untouched)' : ''}`);
  if (result.org) {
    const counts = result.org.members ? `: ${result.org.members.map((c) => `${c.owner} ${c.members} ${c.members === 1 ? 'member' : 'members'}`).join(', ')}` : '';
    lines.push(`org: ${result.org.list.join(', ')}${result.org.seeded ? ` (from origins${counts}; confirm or pass --org)` : ''}`);
  }
  if (result.archetype) lines.push(`archetype: ${result.archetype.id}${result.archetype.applied ? '' : ' (the map already exists and is kept; use seed-map --merge --archetype to apply it)'}`);
  if (result.members.length > 0) lines.push(`members: ${result.members.length} (${result.members.join(', ')})`);
  for (const note of result.notes) lines.push(`note: ${note}`);
  for (const fix of result.remoteFixes) {
    lines.push(`origin of ${fix.path} holds credentials; ${fix.applied ? 'rewrote it' : 'run (or pass --fix-remotes)'}: ${fix.command}`);
  }
  if (result.directPush) {
    const d = result.directPush;
    const state = { written: 'written', 'would-write': 'proposal, not written: re-run with --yes to write it', kept: d.configured ? 'kept: already set in the project, edit by hand to change it' : 'kept', failed: 'failed' }[d.status];
    lines.push(`git.directPush.paths in ${d.file}: ${state}`, `  before: ${JSON.stringify(d.before)}`, `  after:  ${JSON.stringify(d.after)}`);
  }
  for (const e of result.errors) lines.push(`error: ${e}`);
  return lines.join('\n');
}

module.exports = { renderInit };
