#!/usr/bin/env node
'use strict';

// Moves a project from the old flat docs layout to the folder layout (requirements/, design/,
// architecture/, testing/, conventions/, guides/), and journals/ into plans/. Files move with `git mv`
// when git tracks them, so history follows. Relative links in the docs and in every tracked Markdown
// file are rewritten. Duplicates (two roadmaps, two deployment docs...) are never concatenated: the
// larger one moves and the other is listed to merge by hand. Every move is checked before the first one
// runs, and a failed move rolls back the ones before it. Nothing is committed. A second run is a no-op.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { legacyCandidates, normalizeDocsRoot, detectDocSite } = require('../../../hooks/lib/docs-layout.cjs');
const { rewriteLinks } = require('./lib/markdown-link-rewriter.cjs');

const USAGE = `Usage: migrate-docs-layout.cjs [--dry-run] [--include-rules] [--allow-dirty] [--allow-no-git] [--allow-doc-site] [--project <dir>] [--json]

Moves the old flat docs layout to docs/{requirements,design,architecture,testing,conventions,guides}/
and journals/ to plans/journals/, then fixes relative Markdown links. Never commits.

  --dry-run         print the plan and change nothing
  --include-rules   also move .claude/rules/project-*.md to docs/conventions/; they then stop loading
                    in every session and are listed as conventions to read when a task needs them
  --allow-dirty     run even when files it would move or edit have uncommitted changes
  --allow-no-git    run outside a git work tree (nothing to undo the moves with)
  --allow-doc-site  run even though docs/ looks like a documentation site (mkdocs.yml, docusaurus...)
  --project <dir>   project root (default: current directory)
  --json            print the result as JSON`;

const FLAGS = { '--dry-run': 'dryRun', '--include-rules': 'includeRules', '--allow-dirty': 'allowDirty', '--allow-no-git': 'allowNoGit', '--allow-doc-site': 'allowDocSite', '--json': 'json' };

function parseArgs(argv) {
  const opts = { project: process.cwd() };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (FLAGS[arg]) opts[FLAGS[arg]] = true;
    else if (arg === '--project') opts.project = argv[++i];
    else if (arg === '-h' || arg === '--help') opts.help = true;
    else throw new Error(`unknown option: ${arg}`);
  }
  if (!opts.project) throw new Error('--project needs a directory');
  return opts;
}

function fail(code, message) {
  const err = new Error(message);
  err.code = code;
  return err;
}

function readRoots(root) {
  let paths = {};
  try { paths = JSON.parse(fs.readFileSync(path.join(root, '.claude', 'config', 'adf-config.json'), 'utf8'))?.paths || {}; } catch { /* defaults */ }
  return { docs: normalizeDocsRoot(paths.docs) || 'docs', plans: normalizeDocsRoot(paths.plans) || 'plans' };
}

const abs = (root, rel) => path.join(root, ...rel.split('/'));
const lstat = (root, rel) => { try { return fs.lstatSync(abs(root, rel)); } catch { return null; } };
const exists = (root, rel) => lstat(root, rel) !== null;

/** A plain file whose real path stays inside the project: a symlink would let a rewrite land outside it. */
function isRegularFileInside(root, rel) {
  const st = lstat(root, rel);
  if (!st || !st.isFile()) return false;
  try {
    const inside = path.relative(fs.realpathSync(root), fs.realpathSync(abs(root, rel)));
    return inside !== '' && !inside.startsWith('..') && !path.isAbsolute(inside);
  } catch { return false; }
}

function weight(root, rel) {
  const stat = fs.statSync(abs(root, rel));
  return stat.isDirectory() ? fs.readdirSync(abs(root, rel), { recursive: true }).length : stat.size;
}

/** New location of an old project-relative path, following file and folder moves. */
function makeMapper(moves) {
  return (rel) => {
    for (const { from, to } of moves) {
      if (rel === from) return to;
      if (rel.startsWith(`${from}/`)) return `${to}${rel.slice(from.length)}`;
    }
    return rel;
  };
}

/**
 * @returns {{moves: Array<{from, to}>, mergeByHand: Array<{from, to, reason, movesTo?}>, rulesSkipped: string[]}}
 */
function buildMigrationPlan(root, roots, { includeRules = false } = {}) {
  const candidates = legacyCandidates(root, roots);
  const rules = exists(root, '.claude/rules')
    ? fs.readdirSync(abs(root, '.claude/rules')).filter((n) => /^project-.+\.md$/.test(n)).sort().map((n) => `.claude/rules/${n}`)
    : [];
  if (includeRules) for (const rel of rules) candidates.push({ from: rel, to: `${roots.docs}/conventions/${path.posix.basename(rel).replace(/^project-/, '')}` });

  const mergeByHand = [];
  const byTarget = new Map();
  for (const c of candidates) byTarget.set(c.to, [...(byTarget.get(c.to) || []), c]);
  const winners = new Set();
  for (const [to, group] of byTarget) {
    if (exists(root, to)) {
      for (const c of group) mergeByHand.push({ ...c, reason: `${to} already exists` });
      continue;
    }
    const winner = group.reduce((best, c) => (weight(root, c.from) > weight(root, best.from) ? c : best));
    winners.add(winner);
    for (const c of group) if (c !== winner) mergeByHand.push({ ...c, reason: `duplicate of ${winner.from}, which moves to ${to}` });
  }
  const moves = candidates.filter((c) => winners.has(c)).map(({ from, to }) => ({ from, to }));
  // A duplicate inside a folder that moves goes with that folder: say where it really ends up
  const mapPath = makeMapper(moves);
  for (const item of mergeByHand) {
    const now = mapPath(item.from);
    if (now !== item.from) item.movesTo = now;
  }
  return { moves, mergeByHand, rulesSkipped: includeRules ? [] : rules };
}

function git(root, args) {
  return spawnSync('git', args, { cwd: root, encoding: 'utf8' });
}

function isGitWorkTree(root) {
  return git(root, ['rev-parse', '--is-inside-work-tree']).stdout.trim() === 'true';
}

/** Markdown files that may link to a moved path: the docs, the moved files, the root files and every tracked .md. */
function markdownScope(root, roots, moves, inGit) {
  const files = new Set();
  const walk = (rel) => {
    const st = lstat(root, rel);
    if (!st || st.isSymbolicLink()) return;
    if (st.isFile()) { if (rel.endsWith('.md')) files.add(rel); return; }
    if (!st.isDirectory()) return;
    for (const name of fs.readdirSync(abs(root, rel))) if (name !== 'node_modules' && name !== '.git') walk(`${rel}/${name}`);
  };
  walk(roots.docs);
  for (const { from } of moves) walk(from);
  for (const f of ['README.md', 'CLAUDE.md', 'AGENTS.md']) walk(f);
  if (inGit) {
    const r = git(root, ['ls-files', '-z', '--', '*.md']);
    if (r.status === 0) for (const f of r.stdout.split('\0').filter(Boolean)) if (isRegularFileInside(root, f)) files.add(f);
  }
  return [...files].sort();
}

/** Link rewrites, computed from the files at their old place. */
function planLinkRewrites(root, roots, moves, inGit = isGitWorkTree(root)) {
  const mapPath = makeMapper(moves);
  const rewrites = [];
  for (const fileOld of markdownScope(root, roots, moves, inGit)) {
    const fileNew = mapPath(fileOld);
    const text = fs.readFileSync(abs(root, fileOld), 'utf8');
    const result = rewriteLinks(text, { fileOld, fileNew, mapPath, exists: (rel) => exists(root, rel) });
    if (result.changes.length > 0) rewrites.push({ fileOld, file: fileNew, text: result.text, changes: result.changes });
  }
  return rewrites;
}

/** Every reason a move would fail or reach outside the project, before anything is touched. */
function preflight(root, moves) {
  const problems = [];
  const symlinkedAncestor = (rel) => {
    const parts = rel.split('/');
    for (let i = 1; i < parts.length; i++) {
      const st = lstat(root, parts.slice(0, i).join('/'));
      if (st && st.isSymbolicLink()) return parts.slice(0, i).join('/');
    }
    return null;
  };
  for (const { from, to } of moves) {
    const st = lstat(root, from);
    if (!st) problems.push(`${from} no longer exists`);
    else if (st.isSymbolicLink()) problems.push(`${from} is a symlink`);
    for (const rel of [from, to]) {
      const link = symlinkedAncestor(rel);
      if (link) problems.push(`${link} is a symlink; ${rel} would be reached through it`);
    }
    if (exists(root, to)) problems.push(`${to} already exists`);
    const parts = to.split('/');
    for (let i = 1; i < parts.length; i++) {
      const dir = parts.slice(0, i).join('/');
      const dst = lstat(root, dir);
      if (dst && !dst.isDirectory()) problems.push(`${dir} is a file, so ${to} cannot be created`);
    }
  }
  return [...new Set(problems)];
}

function moveOne(root, from, to, inGit) {
  fs.mkdirSync(path.dirname(abs(root, to)), { recursive: true });
  if (inGit && git(root, ['mv', from, to]).status === 0) return 'git mv';
  fs.renameSync(abs(root, from), abs(root, to)); // untracked, ignored, or no git
  return 'rename';
}

/** Remove folders a move emptied, up to (not including) the project root. */
function pruneEmptyParents(root, rel) {
  let dir = path.posix.dirname(rel);
  while (dir && dir !== '.') {
    try { fs.rmdirSync(abs(root, dir)); } catch { return; }
    dir = path.posix.dirname(dir);
  }
}

function applyMoves(root, moves, inGit) {
  const applied = [];
  try {
    for (const m of moves) {
      applied.push({ ...m, how: moveOne(root, m.from, m.to, inGit) });
      pruneEmptyParents(root, m.from);
    }
  } catch (err) {
    for (const m of applied.reverse()) {
      try { moveOne(root, m.to, m.from, inGit); } catch { /* reported below */ }
    }
    throw fail('EMOVE', `a move failed (${err.message}); the ${applied.length} move(s) before it were undone. Nothing else changed.`);
  }
  return applied;
}

function run(opts) {
  const root = path.resolve(opts.project);
  const roots = readRoots(root);
  const inGit = isGitWorkTree(root);
  const docSite = roots.docs === 'docs' ? detectDocSite(root) : null;
  const plan = buildMigrationPlan(root, roots, { includeRules: opts.includeRules });
  const rewrites = planLinkRewrites(root, roots, plan.moves, inGit);
  const problems = preflight(root, plan.moves);
  const result = {
    root, roots, dryRun: Boolean(opts.dryRun), docSite, problems, ...plan,
    rewrites: rewrites.map(({ file, changes }) => ({ file, changes })),
  };
  if (opts.dryRun || plan.moves.length === 0) return result;

  if (docSite && !opts.allowDocSite) {
    throw fail('EDOCSITE', `docs/ looks like a documentation site (${docSite}). Give ADF its own docs root with "paths.docs" in .claude/config/adf-config.json instead, or pass --allow-doc-site.`);
  }
  if (!inGit && !opts.allowNoGit) throw fail('ENOGIT', 'not a git work tree, so the moves could not be undone; commit the project to git first, or pass --allow-no-git.');
  if (problems.length > 0) throw fail('EPREFLIGHT', `nothing was moved:\n${problems.map((p) => `  ${p}`).join('\n')}`);
  if (inGit && !opts.allowDirty) {
    const paths = [...new Set([...plan.moves.map((m) => m.from), ...rewrites.map((w) => w.fileOld)])];
    const dirty = git(root, ['status', '--porcelain', '--', ...paths]).stdout.split('\n').filter(Boolean);
    if (dirty.length > 0) {
      throw fail('EDIRTY', `files it would move or edit have uncommitted changes; commit or stash them, or pass --allow-dirty:\n${dirty.map((l) => `  ${l}`).join('\n')}`);
    }
  }
  result.applied = applyMoves(root, plan.moves, inGit);
  for (const { file, text } of rewrites) fs.writeFileSync(abs(root, file), text);
  return result;
}

function printSummary(r) {
  const out = [];
  if (r.moves.length === 0 && r.mergeByHand.length === 0) out.push('Nothing to migrate: the project already uses the docs folder layout.');
  if (r.docSite) out.push(`Note: docs/ looks like a documentation site (${r.docSite}); set "paths.docs" to another folder rather than migrating it.`);
  if (r.problems.length > 0) out.push('Cannot move until these are fixed:', ...r.problems.map((p) => `  ${p}`));
  if (r.moves.length > 0) {
    out.push(r.dryRun ? 'Would move:' : 'Moved:');
    for (const m of r.moves) out.push(`  ${m.from} -> ${m.to}`);
  }
  if (r.rewrites.length > 0) {
    out.push(r.dryRun ? 'Would rewrite links in:' : 'Rewrote links in:');
    for (const w of r.rewrites) out.push(`  ${w.file}: ${w.changes.map((c) => `${c.from} -> ${c.to}`).join(', ')}`);
  }
  if (r.mergeByHand.length > 0) {
    out.push('Merge by hand:');
    for (const m of r.mergeByHand) {
      out.push(m.movesTo
        ? `  ${m.from} (moves with its folder to ${m.movesTo}) into ${m.to}: ${m.reason}`
        : `  ${m.from} (left in place) into ${m.to}: ${m.reason}`);
    }
  }
  if (r.rulesSkipped.length > 0) out.push(`Project rules not moved (pass --include-rules; they then load only when a task needs them): ${r.rulesSkipped.join(', ')}`);
  if (!r.dryRun && r.moves.length > 0) out.push('Review the changes with `git status`, then commit them.');
  console.log(out.join('\n'));
}

function main(argv) {
  let opts;
  try { opts = parseArgs(argv); } catch (err) { console.error(`${err.message}\n\n${USAGE}`); return 2; }
  if (opts.help) { console.log(USAGE); return 0; }
  try {
    const result = run(opts);
    if (opts.json) console.log(JSON.stringify(result, null, 2));
    else printSummary(result);
    return 0;
  } catch (err) {
    console.error(err.message);
    return 1;
  }
}

if (require.main === module) process.exit(main(process.argv.slice(2)));

module.exports = { buildMigrationPlan, planLinkRewrites, preflight, makeMapper, readRoots, run, main };
