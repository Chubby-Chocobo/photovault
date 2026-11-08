/**
 * plan-contract-validator.cjs - The plan contract's rules over what plan-contract-reader read.
 *
 * Every field that is present is checked. A missing recommended field is a warning; the fields
 * named in `required` are problems when missing or empty. See references/plan-contract.md.
 *
 * @module plan-contract-validator
 */

'use strict';

const rules = require('./plan-contract-rules.cjs');
const { checkStatuses } = require('./plan-contract-status.cjs');

const LIST_FIELDS = new Set(['touches', 'acceptance', 'sources', 'dependencies']);

function sink() {
  const problems = [];
  const warnings = [];
  const add = (list) => (code, file, message) => list.push({ code, file, message });
  return { problems, warnings, problem: add(problems), warn: add(warnings) };
}

function checkSources(out, file, label, entries, authoritative) {
  for (const entry of entries) {
    const why = rules.sourceProblem(entry);
    if (why) out.problem('source-invalid', file, `${label} source "${entry}" ${why}`);
  }
  if (entries.filter((e) => e.startsWith('tracker:')).length > 1) out.problem('source-tracker-duplicate', file, `${label} lists more than one tracker source`);
  if (authoritative && !entries.includes(authoritative)) out.problem('authoritative-not-in-sources', file, `${label} authoritative "${authoritative}" is not one of its sources`);
}

function checkBrief(out, brief, raw) {
  if (!brief.id) out.warn('brief-id-missing', brief.file, 'brief has no id');
  else if (!rules.BRIEF_ID_RE.test(brief.id)) out.problem('brief-id-invalid', brief.file, `brief id "${brief.id}" does not match ${rules.BRIEF_ID_RE}`);
  checkLists(out, brief.file, 'brief', raw.briefFm, ['sources']);
  checkSources(out, brief.file, 'brief', brief.sources, brief.authoritative);
  if (brief.principles === null) out.warn('principles-missing', brief.file, 'brief has no "## Principles" section');
}

/** A list field written as an inline list that never closes: reported, because the reader sees no list. */
function checkLists(out, file, label, fm, fields) {
  for (const name of fields) {
    if (rules.malformedList(fm[name])) out.problem('list-malformed', file, `${label}: ${name} is an unclosed inline list ${JSON.stringify(fm[name])}`);
  }
}

function checkDecisions(out, raw, required) {
  const report = required.includes('decisions') ? out.problem : out.warn;
  for (const { code, message } of raw.decisionFindings) report(code, 'plan.md', message);
}

function isPresent(phase, name, raw) {
  if (LIST_FIELDS.has(name)) return phase[name].length > 0;
  const value = raw.phaseFm[phase.file][name];
  return Array.isArray(value) ? value.length > 0 : typeof value === 'string' && value.trim() !== '';
}

function checkGraph(out, phases) {
  const ids = new Set();
  for (const phase of phases) {
    if (!rules.PHASE_ID_RE.test(phase.id)) out.problem('phase-id-invalid', phase.file, `phase id "${phase.id}" does not match ${rules.PHASE_ID_RE}`);
    else if (ids.has(phase.id)) out.problem('phase-id-duplicate', phase.file, `phase id "${phase.id}" is used twice`);
    ids.add(phase.id);
  }
  for (const phase of phases) {
    for (const dep of phase.dependencies) if (!ids.has(dep)) out.problem('dependency-unknown', phase.file, `phase ${phase.id} depends on "${dep}", which is not a phase`);
  }
  for (const cycle of rules.findCycles(new Map(phases.map((p) => [p.id, p.dependencies])))) {
    out.problem('dependency-cycle', null, `dependency cycle: ${cycle.join(' -> ')}`);
  }
}

function checkAcceptance(out, phase, raw) {
  const value = raw.phaseFm[phase.file].acceptance;
  if (typeof value === 'string' && value.trim() !== '') out.warn('acceptance-inline-list', phase.file, `phase ${phase.id}: write acceptance as a block list, one command per line; a comma splits an inline list`);
  for (const command of phase.acceptance) {
    if (rules.nodeTestDir(command)) out.warn('node-test-dir', phase.file, `phase ${phase.id}: "node --test" with a directory fails on Node 24; use node --test "test/**/*.test.cjs"`);
  }
}

function checkPhase(out, phase, plan, raw, required) {
  const missing = (name) => required.includes(name) && !isPresent(phase, name, raw);
  for (const name of required) if (name !== 'decisions' && missing(name)) out.problem('required-missing', phase.file, `phase ${phase.id}: required field "${name}" is missing or empty`);
  for (const name of ['touches', 'acceptance']) {
    if (phase[name].length === 0 && !required.includes(name)) out.warn(`${name}-missing`, phase.file, `phase ${phase.id} has no ${name}`);
  }
  for (const entry of phase.touches) {
    const why = rules.touchProblem(entry);
    if (why) out.problem('touch-invalid', phase.file, `phase ${phase.id}: touches entry "${entry}" ${why}`);
    else if (plan && plan.scope.length > 0 && !rules.underScope(entry, plan.scope)) out.warn('touches-outside-scope', phase.file, `phase ${phase.id}: touches entry "${entry}" is not under a plan scope entry`);
  }
  checkLists(out, phase.file, `phase ${phase.id}`, raw.phaseFm[phase.file], ['dependencies', 'touches', 'acceptance', 'sources']);
  checkSources(out, phase.file, `phase ${phase.id}`, phase.sources, '');
  for (const entry of phase.sources) {
    if (plan && !plan.sources.includes(entry)) out.problem('source-not-in-plan', phase.file, `phase ${phase.id} source "${entry}" is not one of the plan's sources`);
  }
  checkAcceptance(out, phase, raw);
}

/**
 * @param {{ brief: object|null, plan: object|null, phases: object[], raw: object }} read From readPlanDir
 * @param {{ required?: string[] }} [opts] required: phase field names, or `decisions`
 * @returns {{ problems: object[], warnings: object[] }}
 */
function validate({ brief, plan, phases, raw }, { required = [] } = {}) {
  const out = sink();
  if (brief) checkBrief(out, brief, raw);
  if (plan) {
    checkLists(out, plan.file, 'plan', raw.planFm, ['sources', 'scope']);
    checkSources(out, plan.file, 'plan', plan.sources, plan.authoritative);
    checkDecisions(out, raw, required);
    checkStatuses(out, plan, phases, raw);
    if (raw.skippedTableLines > 0) out.warn('plan-line-too-long', plan.file, `${raw.skippedTableLines} line(s) of plan.md over 2000 characters were not read for the phases table`);
    if (phases.length === 0 && !raw.briefExists) {
      const phaseFields = required.filter((n) => n !== 'decisions');
      (phaseFields.length > 0 ? out.problem : out.warn)('no-phases', null, phaseFields.length > 0 ? `plan.md has no phase-*.md file, so required ${phaseFields.join(', ')} cannot hold` : 'plan.md exists but no phase-*.md file does');
    }
  }
  checkGraph(out, phases);
  for (const phase of phases) checkPhase(out, phase, plan, raw, required);
  return { problems: out.problems, warnings: out.warnings };
}

module.exports = { validate };
