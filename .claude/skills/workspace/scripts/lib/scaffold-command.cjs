/**
 * scaffold-command.cjs - `workspace.cjs scaffold [<component>] [--only agents-md|claude-md|service-docs] [--dry-run] --yes`
 *
 * Writes the instruction files of each component directory that lacks them and a service doc under
 * `<docs>/architecture/services/` for each component that has none. The starter text goes in
 * AGENTS.md (read by every agent) and CLAUDE.md imports it; a component that already has a CLAUDE.md
 * gets an AGENTS.md that points to it. Each AGENTS.md written carries the system-context block; the
 * member markers and the blocks of files that already existed come from `sync`. A file that exists is never touched (`kept`), a component
 * directory that is not a real cloned directory inside the project is skipped, and nothing is
 * rendered into a file until every file has rendered.
 *
 * @module scaffold-command
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { loadManifest } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { loadSystemMap, docsDirFor } = require('../../../../hooks/lib/system-map.cjs');
const { safeText } = require('../../../../hooks/lib/system-map-validate.cjs');
const { MARKERS, INSTALLER_MARKERS, renderBlockBody } = require('../../../../hooks/lib/member-context-block.cjs');
const { withBlock, readBlock } = require('../../../../hooks/lib/managed-text-block.cjs');
const { render, readTemplate } = require('./template-render.cjs');
const { componentDir, servicesDirSkip, claudeMdPlan, importStubPlan, pointerStubPlan, serviceDocPlan } = require('./scaffold-values.cjs');
const { sourceOf } = require('./member-sync-plan.cjs');
const { fail, usageError } = require('./workspace-util.cjs');

const PARTS = ['agents-md', 'claude-md', 'service-docs'];
const MAX_AGENTS_MD_BYTES = 1024 * 1024;
const PREVIEW_LINES = 5;

const exists = (file) => { try { fs.lstatSync(file); return true; } catch { return false; } };
const posix = (p) => p.split(path.sep).join('/');

function renderFile(plan) {
  return render(readTemplate(plan.template), plan.values);
}

/** One planned file: status `would-write` (content set), `kept` or `skipped`. `finish` may add to the rendered text. */
function plannedFile({ kind, component, rel, abs, skip, build, finish = (text) => text }) {
  const base = { kind, component: component.name, path: rel };
  if (skip) return { ...base, status: 'skipped', reason: skip };
  if (exists(abs)) return { ...base, status: 'kept' };
  return { ...base, status: 'would-write', abs, content: finish(renderFile(build())) };
}

/** Whether an existing AGENTS.md holds ADF's installer block (so a CLAUDE.md must not import it); 'absent' when there is none. */
function agentsMdKind(abs) {
  if (!exists(abs)) return 'absent';
  try {
    const stat = fs.statSync(abs);
    if (!stat.isFile() || stat.size > MAX_AGENTS_MD_BYTES) return 'other';
    return readBlock(fs.readFileSync(abs, 'utf8'), INSTALLER_MARKERS).state === 'absent' ? 'plain' : 'installer';
  } catch { return 'other'; }
}

/**
 * Adds the system-context block to a new AGENTS.md, the way `sync` renders it. The source stamp
 * is read once, and only when an AGENTS.md is to be written.
 */
function blockWriter({ root, docs, manifest, map }) {
  let source;
  return (component) => (text) => {
    if (source === undefined) source = sourceOf(root, `${docs}/architecture/system-map.json`);
    const member = manifest && manifest.members.find((m) => m.name === component.member);
    const workspace = manifest ? { memberPath: member ? member.path : component.path, url: manifest.repo } : null;
    return withBlock(text, MARKERS, renderBlockBody({ map, component, docs, source, workspace }));
  };
}

function planFiles({ root, docs, manifest, map, components, parts }) {
  const servicesDir = path.join(root, ...docs.split('/'), 'architecture', 'services');
  const servicesSkip = parts.includes('service-docs') ? servicesDirSkip(root, docs) : null;
  const files = [];
  const withSystemContext = blockWriter({ root, docs, manifest, map });
  for (const component of components) {
    const where = componentDir(root, manifest, component);
    const ctx = { map, component, where, docs };
    const claudeAbs = path.join(where.dir, 'CLAUDE.md');
    const agentsAbs = path.join(where.dir, 'AGENTS.md');
    const agents = agentsMdKind(agentsAbs);
    if (parts.includes('agents-md')) {
      // The starter goes in AGENTS.md unless a CLAUDE.md already holds the component's notes
      const build = () => (exists(claudeAbs) ? pointerStubPlan(ctx) : claudeMdPlan(ctx));
      files.push(plannedFile({ kind: 'agents-md', component, rel: `${component.path}/AGENTS.md`, abs: agentsAbs, skip: where.skip, build, finish: withSystemContext(component) }));
    }
    if (parts.includes('claude-md')) {
      // CLAUDE.md imports the AGENTS.md that exists or is being written; ADF's installer block is not for Claude to import
      const imports = (agents !== 'absent' || parts.includes('agents-md')) && agents !== 'installer';
      files.push(plannedFile({ kind: 'claude-md', component, rel: `${component.path}/CLAUDE.md`, abs: claudeAbs, skip: where.skip, build: () => (imports ? importStubPlan(ctx) : claudeMdPlan(ctx)) }));
    }
    if (parts.includes('service-docs')) {
      const abs = path.join(servicesDir, `${component.name}.md`);
      files.push(plannedFile({ kind: 'service-doc', component, rel: posix(path.relative(root, abs)), abs, skip: servicesSkip, build: () => serviceDocPlan(ctx) }));
    }
  }
  return files;
}

/** Creates the file only when it is absent: the exclusive flag also refuses a symlink in its place. */
function writeNew(file) {
  try {
    fs.mkdirSync(path.dirname(file.abs), { recursive: true });
    fs.writeFileSync(file.abs, file.content, { flag: 'wx' });
    return { ...file, status: 'written' };
  } catch (err) {
    if (err && err.code === 'EEXIST') return { ...file, status: 'kept' };
    return { ...file, status: 'failed', reason: `cannot write (${err && err.code ? err.code : 'error'})` };
  }
}

/** The file as reported: no absolute path, no full content, the first lines only on a dry run. */
function reported({ abs, content, ...file }, dryRun) {
  return dryRun && content !== undefined ? { ...file, preview: content.split('\n').slice(0, PREVIEW_LINES) } : file;
}

function textOf(files, dryRun) {
  const lines = [];
  for (const f of files) {
    lines.push(`${f.status} ${f.path}${f.reason ? ` (${f.reason})` : ''}`);
    for (const line of f.preview || []) lines.push(`    ${line}`.trimEnd());
  }
  const count = (status) => files.filter((f) => f.status === status).length;
  const done = dryRun ? `${count('would-write')} to write` : `${count('written')} written`;
  lines.push('', `${done}, ${count('kept')} kept, ${count('skipped')} skipped${count('failed') > 0 ? `, ${count('failed')} failed` : ''}`);
  if (dryRun) lines.push('Nothing written. Re-run with --yes after confirming.');
  return lines.join('\n');
}

/** @param {{ root: string, docsRel: string, opts: object }} ctx */
function run({ root, docsRel, opts }) {
  const names = opts._.slice(1);
  if (names.length > 1) return usageError('scaffold takes at most one component name');
  if (opts.only !== undefined && !PARTS.includes(opts.only)) return usageError(`--only must be one of ${PARTS.join(', ')}`);
  const parts = opts.only ? [opts.only] : PARTS;

  const { manifest, errors } = loadManifest(root);
  if (errors.length > 0) return fail(errors);
  const docs = posix(path.normalize(docsDirFor(docsRel))).replace(/\/+$/, '');
  // The docs path is written into instruction files, so it must be plain text there
  if ((parts.includes('claude-md') || parts.includes('agents-md')) && !safeText(docs)) {
    return fail(['paths.docs must be plain text (letters, digits, space . _ / : @ -) to be written into an instruction file; rename it or use --only service-docs']);
  }
  const loaded = loadSystemMap(root, docsRel, { manifest });
  if (loaded.errors.length > 0) return fail(loaded.errors);
  if (!loaded.map) return fail(['there is no system map; run `seed-map` first']);

  const all = loaded.map.components || [];
  const components = names.length > 0 ? all.filter((c) => c.name === names[0]) : all;
  if (names.length > 0 && components.length === 0) return usageError(`no such component in the system map; known: ${all.map((c) => c.name).join(', ') || 'none'}`);

  const dryRun = Boolean(opts['dry-run']);
  let files;
  try {
    files = planFiles({ root, docs, manifest, map: loaded.map, components, parts });
  } catch (err) {
    return fail([`a template did not render, nothing written: ${err && err.message ? err.message : 'error'}`]);
  }
  if (!dryRun) files = files.map((f) => (f.status === 'would-write' ? writeNew(f) : f));

  const out = files.map((f) => reported(f, dryRun));
  const failed = out.some((f) => f.status === 'failed');
  return { code: failed ? 1 : 0, result: { ok: !failed, dryRun, files: out }, text: textOf(out, dryRun) };
}

module.exports = { run };
