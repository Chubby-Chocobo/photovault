/**
 * plan-contract-status.cjs - `status` checks of the plan contract: the value is one ADF knows, and
 * the plan.md phases table agrees with the phase files (the phase front matter is the source of truth).
 *
 * @module plan-contract-status
 */

'use strict';

const path = require('node:path');
const { normalizeStatus } = require('../../../_shared/lib/plan-table-parser.cjs');
const { STATUSES } = require('./plan-contract-rules.cjs');

const trimZeros = (id) => String(id).replace(/^0+(?=\d)/, '');
const known = [...STATUSES].join(', ');

/** The shared normalizer reads "cancelled" as pending, so a cancelled phase is matched on the row text. */
function rowCancelled(tableText, rowFile) {
  if (!rowFile) return false;
  return tableText.split('\n').some((line) => line.includes('|') && line.includes(rowFile) && /cancel/i.test(line));
}

function checkStatuses(out, plan, phases, raw) {
  const unknown = (file, label, status) => {
    if (status && !STATUSES.has(status)) out.warn('status-unknown', file, `${label} status "${status}" is not one of ${known}`);
  };
  unknown(plan.file, 'plan', plan.status);
  for (const phase of phases) unknown(phase.file, `phase ${phase.id}`, phase.status);

  for (const row of raw.tableRows) {
    const rowFile = row.file ? path.basename(row.file) : null;
    const phase = phases.find((p) => p.file === rowFile) || phases.find((p) => trimZeros(p.id) === trimZeros(row.phaseId));
    if (!phase) continue;
    const inTable = rowCancelled(raw.tableText, rowFile) ? 'cancelled' : row.status;
    const inFile = phase.status === 'cancelled' ? 'cancelled' : normalizeStatus(phase.status);
    if (inTable !== inFile) out.warn('status-table-mismatch', plan.file, `phases table says "${inTable}" for phase ${phase.id}, ${phase.file} says "${inFile}"`);
  }
}

module.exports = { checkStatuses };
