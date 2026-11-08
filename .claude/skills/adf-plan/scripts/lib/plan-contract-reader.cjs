/**
 * plan-contract-reader.cjs - Read a plan dir (brief.md, plan.md, phase-*.md) into the plan
 * contract's JSON model, plus the raw values the validator needs.
 *
 * Reads are size-capped. A file that exists but cannot be read becomes a `file-unreadable`
 * problem. Nothing here validates a value; the validator does.
 *
 * @module plan-contract-reader
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { parseFrontmatter, toList } = require('../../../../hooks/lib/front-matter.cjs');
const { readTextCapped } = require('../../../../hooks/lib/read-text-capped.cjs');
const { relativePosix, insideRoot } = require('../../../../hooks/lib/path-containment.cjs');
const { parsePlanPhases } = require('../../../_shared/lib/plan-table-parser.cjs');
const { readDecisions, readPrinciples } = require('./plan-contract-sections.cjs');

const MAX_FILE_BYTES = 512 * 1024;
// The shared table parser backtracks badly on long lines and long whitespace runs
const MAX_TABLE_LINE = 2000;
const FRONT_MATTER_RE = /^---\s*\n[\s\S]*?\n---\s*\n?/;
const PHASE_FILE_RE = /^phase-.+\.md$/;

/** A front matter scalar without a trailing ` # comment` or surrounding quotes. */
function scalar(value) {
  if (typeof value !== 'string') return '';
  const v = value.replace(/\s+#.*$/, '').trim();
  return v.length > 1 && /^(["']).*\1$/.test(v) ? v.slice(1, -1) : v;
}

const statusOf = (value) => scalar(value).toLowerCase().replace(/[\s_]+/g, '-');

/**
 * One contract file: null when absent, unreadable or a symlink leaving the plan dir (the last two
 * are reported). A UTF-8 BOM is dropped. A missing front matter block is a problem for a phase file
 * and a warning for brief.md and plan.md.
 */
function readDoc(ctx, name) {
  const file = path.join(ctx.planDir, name);
  let stat;
  try { stat = fs.lstatSync(file); } catch { return null; }
  ctx.present.add(name);
  if (stat.isSymbolicLink()) {
    let real = null;
    try { real = fs.realpathSync(file); } catch { /* dangling */ }
    if (real === null || !insideRoot(relativePosix(ctx.planDir, real))) {
      ctx.problems.push({ code: 'symlink-outside-plan-dir', file: name, message: `${name} is a symlink that does not resolve to a file inside the plan dir` });
      return null;
    }
  }
  const content = readTextCapped(file, MAX_FILE_BYTES);
  if (content === null) {
    ctx.problems.push({ code: 'file-unreadable', file: name, message: `${name} is not a regular file of at most ${MAX_FILE_BYTES} bytes` });
    return null;
  }
  const text = content.replace(/^\uFEFF/, '');
  if (!FRONT_MATTER_RE.test(text)) {
    const isPhase = PHASE_FILE_RE.test(name);
    (isPhase ? ctx.problems : ctx.warnings).push({ code: 'frontmatter-missing', file: name, message: `${name} does not start with a "---" front matter block` });
  }
  return { name, content: text, fm: parseFrontmatter(text) };
}

/** plan.md text safe for the shared table parser: over-long lines are dropped, whitespace runs shortened. */
function tableText(content) {
  let skipped = 0;
  const text = content.split('\n').map((line) => {
    if (line.length > MAX_TABLE_LINE) { skipped += 1; return ''; }
    return line.replace(/[ \t]{8,}/g, ' ');
  }).join('\n').replace(/\n\s*\n(\s*\n)+/g, '\n\n');
  return { text, skipped };
}

function briefModel(doc) {
  const { fm } = doc;
  return { file: doc.name, id: scalar(fm.id), sources: toList(fm.sources), authoritative: scalar(fm.authoritative), principles: readPrinciples(doc.content) };
}

function planModel(doc) {
  const { fm } = doc;
  const { decisions, findings } = readDecisions(doc.content);
  const model = {
    file: doc.name,
    title: typeof fm.title === 'string' ? fm.title : '',
    status: statusOf(fm.status),
    priority: scalar(fm.priority),
    scope: toList(fm.scope),
    sources: toList(fm.sources),
    authoritative: scalar(fm.authoritative),
    decisions,
  };
  return { model, decisionFindings: findings };
}

function phaseModel(doc) {
  const { fm } = doc;
  const fromName = /^phase-([^-.]+)/.exec(doc.name);
  const dependencies = toList(fm.dependencies).filter((d) => d.toLowerCase() !== 'none');
  return {
    file: doc.name,
    id: scalar(fm.phase) || (fromName ? fromName[1] : ''),
    title: typeof fm.title === 'string' ? fm.title : '',
    status: statusOf(fm.status),
    priority: scalar(fm.priority),
    size: scalar(fm.size),
    dependencies,
    touches: toList(fm.touches),
    acceptance: toList(fm.acceptance),
    sources: toList(fm.sources),
  };
}

/**
 * @param {string} planDir Real path of the plan dir
 * @returns {{ brief: object|null, plan: object|null, phases: object[], raw: object, problems: object[], warnings: object[] }}
 *   raw holds what validation needs beyond the model: front matter per file, decision findings, table rows
 */
function readPlanDir(planDir) {
  const ctx = { planDir, problems: [], warnings: [], present: new Set() };
  const briefDoc = readDoc(ctx, 'brief.md');
  const planDoc = readDoc(ctx, 'plan.md');
  const phaseDocs = fs.readdirSync(planDir).filter((n) => PHASE_FILE_RE.test(n)).sort((a, b) => a.localeCompare(b, 'en', { numeric: true }))
    .map((n) => readDoc(ctx, n)).filter(Boolean);
  const planParts = planDoc ? planModel(planDoc) : null;
  const table = planDoc ? tableText(planDoc.content) : { text: '', skipped: 0 };
  return {
    brief: briefDoc ? briefModel(briefDoc) : null,
    plan: planParts && planParts.model,
    phases: phaseDocs.map(phaseModel),
    raw: {
      briefExists: ctx.present.has('brief.md'),
      planExists: ctx.present.has('plan.md'),
      briefFm: briefDoc ? briefDoc.fm : {},
      planFm: planDoc ? planDoc.fm : {},
      phaseFm: Object.fromEntries(phaseDocs.map((d) => [d.name, d.fm])),
      decisionFindings: planParts ? planParts.decisionFindings : [],
      tableRows: parsePlanPhases(table.text, planDir),
      tableText: table.text,
      skippedTableLines: table.skipped,
    },
    problems: ctx.problems,
    warnings: ctx.warnings,
  };
}

module.exports = { readPlanDir };
