/**
 * workspace-bootstrap-report.cjs - The text `workspace bootstrap` prints.
 *
 * @module workspace-bootstrap-report
 */

'use strict';

/** @param {object} result The bootstrap result object */
function renderBootstrap(result) {
  const lines = [`workspace bootstrap (protocol: ${result.protocol}${result.dryRun ? ', dry run: nothing cloned' : ''})`];
  for (const s of result.members) {
    const tail = s.url ? ` <- ${s.url}` : s.reason ? ` (${s.reason})` : '';
    lines.push(`  ${s.status}: ${s.name} ${s.path}${tail}`);
  }
  for (const fix of result.remoteFixes) {
    lines.push(`origin of ${fix.path} holds credentials; ${fix.applied ? 'rewrote it' : 'run (or pass --fix-remotes)'}: ${fix.command}`);
  }
  return lines.join('\n');
}

module.exports = { renderBootstrap };
