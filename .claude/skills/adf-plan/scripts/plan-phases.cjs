#!/usr/bin/env node
/**
 * plan-phases.cjs - Export or check a plan dir against the plan contract.
 *
 * Usage: plan-phases.cjs [--json|--check] [--require <field,...>] <plan-dir>
 * Exit:  0 no problems, 1 problems, 2 usage error or unreadable dir, 3 brief.md without plan.md or phases.
 * The contract is in references/plan-contract.md.
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { locatePlanDir } = require('./lib/plan-contract-project.cjs');
const { readPlanDir } = require('./lib/plan-contract-reader.cjs');
const { validate } = require('./lib/plan-contract-validator.cjs');

const SCHEMA_VERSION = 1;
const FIELD_NAME_RE = /^[a-z][a-zA-Z0-9_-]*$/;
const USAGE = `Usage: plan-phases.cjs [--json|--check] [--require <field,...>] <plan-dir>

  --json      print the plan as JSON (schema v1)
  --check     print problems and warnings as text (default)
  --require   phase fields that must be present and non-empty in every phase;
              "decisions" also requires a well-formed ## Decisions section

Exit codes: 0 no problems, 1 problems, 2 usage error or unreadable dir,
3 brief.md exists but plan.md or the phases do not.`;

class UsageError extends Error {}

function parseArgs(argv) {
  const opts = { json: false, required: [], planDir: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--json') opts.json = true;
    else if (arg === '--check') opts.json = false;
    else if (arg === '--help' || arg === '-h') opts.help = true;
    else if (arg === '--require' || arg.startsWith('--require=')) {
      const value = arg === '--require' ? argv[++i] : arg.slice('--require='.length);
      if (!value || value.startsWith('--')) throw new UsageError('--require needs a comma-separated list of field names');
      const names = value.split(',').map((n) => n.trim());
      const bad = names.find((n) => !FIELD_NAME_RE.test(n));
      if (bad !== undefined) throw new UsageError(`--require: "${bad}" is not a field name`);
      opts.required.push(...names);
    } else if (arg.startsWith('-')) throw new UsageError(`unknown option ${arg}`);
    else if (opts.planDir) throw new UsageError('only one plan dir is accepted');
    else opts.planDir = arg;
  }
  if (!opts.help && !opts.planDir) throw new UsageError('missing <plan-dir>');
  return opts;
}

function adfVersion() {
  try {
    return JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', '..', 'metadata.json'), 'utf8')).version || null;
  } catch { return null; }
}

/** Findings of a plan dir and the exit code that goes with them, or an error to report with exit 2. */
function inspect(opts) {
  const where = locatePlanDir(opts.planDir);
  if (where.error) return { error: where.error };
  const read = readPlanDir(where.planDir);
  if (!read.raw.briefExists && !read.raw.planExists) return { error: `${where.planDir} holds neither plan.md nor brief.md` };

  const problems = [...read.problems];
  if (!where.insidePlansRoot) problems.push({ code: 'plan-dir-outside-root', file: null, message: `plan dir ${where.planDir} is not inside the plans root ${where.plansRoot}` });
  const found = validate(read, { required: opts.required });
  problems.push(...found.problems);
  const warnings = [...read.warnings, ...found.warnings];
  const awaiting = read.raw.briefExists && (!read.raw.planExists || read.phases.length === 0);
  const json = {
    schemaVersion: SCHEMA_VERSION,
    adfVersion: adfVersion(),
    plansRoot: where.plansRoot,
    planDir: where.planDir,
    brief: read.brief,
    plan: read.plan,
    phases: read.phases,
    problems,
    warnings,
  };
  const exitCode = problems.length > 0 ? 1 : awaiting ? 3 : 0;
  return { json, exitCode, awaiting: awaiting && problems.length === 0 };
}

// Values come from plan files: control characters (terminal escapes included) never reach the terminal
const printable = (text) => String(text).replace(/[\x00-\x1f\x7f-\x9f]/g, '?');
const line = (kind, f) => `  ${kind} ${f.code}${f.file ? ` (${printable(f.file)})` : ''}: ${printable(f.message)}`;

function renderText({ json, awaiting }) {
  const out = [`${printable(json.planDir)}: ${json.phases.length} phase(s), ${json.problems.length} problem(s), ${json.warnings.length} warning(s)`];
  if (awaiting) out.push('  awaiting plan: brief.md exists but plan.md or the phases do not');
  for (const p of json.problems) out.push(line('problem', p));
  for (const w of json.warnings) out.push(line('warning', w));
  return out.join('\n');
}

function main(argv) {
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (err) {
    if (!(err instanceof UsageError)) throw err;
    process.stderr.write(`${err.message}\n${USAGE}\n`);
    return 2;
  }
  if (opts.help) {
    process.stdout.write(`${USAGE}\n`);
    return 0;
  }
  let result;
  try {
    result = inspect(opts);
  } catch (err) {
    result = { error: `cannot read ${opts.planDir}: ${printable(String(err.message).split('\n')[0])}` };
  }
  if (result.error) {
    process.stderr.write(`plan-phases: ${result.error}\n`);
    return 2;
  }
  process.stdout.write(`${opts.json ? JSON.stringify(result.json, null, 2) : renderText(result)}\n`);
  return result.exitCode;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { main, parseArgs, inspect };
