'use strict';

/**
 * The project docs layout, in one place: the folders of docs/, the moves from the old flat layout,
 * the conventions index injected at session start, and the notice for a project still on the old layout.
 * Used by session-init and by the docs skill's migration script.
 *
 * Locations are written as `<root>:<path>`, where root is `docs` (paths.docs), `plans` (paths.plans)
 * or `repo` (the project root).
 */

const fs = require('fs');
const path = require('path');

/** Folders of docs/, each answering one question. */
const DOCS_FOLDERS = ['requirements', 'design', 'architecture', 'testing', 'conventions', 'guides'];

/**
 * Old location -> new location. More specific paths come before the folder that contains them,
 * and several old paths may share one target (they are duplicates to merge by hand).
 */
const LEGACY_MOVES = [
  { from: 'docs:project-overview-pdr.md', to: 'docs:requirements/prd.md' },
  { from: 'docs:project-fsd.md', to: 'docs:requirements/srs.md' },
  { from: 'docs:project-roadmap.md', to: 'docs:requirements/roadmap.md' },
  { from: 'docs:development-roadmap.md', to: 'docs:requirements/roadmap.md' },
  { from: 'docs:usecases', to: 'docs:requirements/usecases' },
  { from: 'docs:design-system', to: 'docs:design/design-system' },
  { from: 'repo:design-system', to: 'docs:design/design-system' },
  { from: 'docs:design-mockups', to: 'docs:design/mockups' },
  { from: 'docs:wireframes', to: 'docs:design/wireframes' },
  { from: 'docs:wireframe', to: 'docs:design/wireframes' },
  { from: 'docs:system-architecture.md', to: 'docs:architecture/system-architecture.md' },
  { from: 'docs:codebase-summary.md', to: 'docs:architecture/codebase-summary.md' },
  { from: 'docs:decisions', to: 'docs:architecture/decisions' },
  { from: 'docs:testcases/test-summary.md', to: 'docs:testing/test-summary.md' },
  { from: 'docs:testcases/test-config.md', to: 'docs:testing/test-config.md' },
  { from: 'docs:testcases/export', to: 'docs:testing/exports' },
  { from: 'docs:testcases', to: 'docs:testing/testcases' },
  { from: 'docs:code-standards.md', to: 'docs:conventions/code-standards.md' },
  { from: 'docs:development-rules.md', to: 'docs:conventions/code-standards.md' },
  { from: 'docs:git-workflow.md', to: 'docs:conventions/git-workflow.md' },
  { from: 'docs:deployment-guide.md', to: 'docs:conventions/deployment.md' },
  { from: 'docs:deployment.md', to: 'docs:conventions/deployment.md' },
  { from: 'docs:project-changelog.md', to: 'repo:CHANGELOG.md' },
  { from: 'docs:assets', to: 'repo:assets' },
  { from: 'repo:journals', to: 'plans:journals' },
];

const MAX_INDEX_LINES = 20;
const MAX_DESCRIPTION = 200;

/** Config files of documentation-site generators; their docs/ is a site, not ADF's docs. */
const DOC_SITE_CONFIGS = [
  'mkdocs.yml', 'mkdocs.yaml', 'docusaurus.config.js', 'docusaurus.config.ts', 'docusaurus.config.mjs',
  'docs/.vitepress', '.vitepress', 'docs/conf.py', 'book.toml', 'docs/_config.yml', 'mint.json', 'docs/mint.json',
];

/**
 * The one rule for a configured docs root, shared by the installer, the hooks, the migration and the
 * skill scripts: a relative path inside the project, not the project root, not inside .git/ or .claude/.
 * @returns {string|null} normalized POSIX path, or null when the value is unusable (callers fall back to `docs`)
 */
function normalizeDocsRoot(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim().replace(/[\\/]+$/, '');
  if (!trimmed || /[\x00]/.test(trimmed) || trimmed.includes('\\') || path.posix.isAbsolute(trimmed) || /^[A-Za-z]:/.test(trimmed)) return null;
  if (trimmed.split("/").includes("..")) return null;
  const normalized = path.posix.normalize(trimmed);
  const first = normalized.split('/')[0].toLowerCase();
  if (normalized === '.' || normalized.split('/').includes('..') || first === '.git' || first === '.claude') return null;
  return normalized;
}

/**
 * Whether a value may be written into a Markdown file every agent reads: a string with no backtick, `$`,
 * control or line-separator character (newline included), bidi control or ADF marker text. Checked on top of normalizeDocsRoot, which only
 * decides where the docs are; `.docs`, `_docs` and `docs--internal` pass.
 */
function renderableText(value) {
  return typeof value === 'string' && value !== '' && !/[`$\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]|<!--|-->|>>> ADF|<<< ADF/.test(value);
}

/** Files below a directory, relative to it (no symlinks followed). */
function filesBelow(dir) {
  try {
    return fs.readdirSync(dir, { recursive: true, withFileTypes: true }).filter((d) => d.isFile()).map((d) => path.relative(dir, path.join(d.parentPath || d.path, d.name)));
  } catch { return []; }
}

/**
 * A root design-system/ is old ADF output only when it holds nothing but Markdown and has a MASTER.md
 * (ui-ux-pro-max wrote design-system/MASTER.md or design-system/<project>/MASTER.md). Anything else,
 * such as a code package in a monorepo, is not docs.
 * @returns {null|{from: string}} the folder to move: design-system, or design-system/<project> when it is the only one
 */
function designSystemDocsSource(projectRoot) {
  const dir = path.join(projectRoot, 'design-system');
  const files = filesBelow(dir);
  if (files.length === 0 || !files.every((f) => f.endsWith('.md'))) return null;
  if (files.includes('MASTER.md')) return { from: 'design-system' };
  const masters = files.filter((f) => /^[^/\\]+[/\\]MASTER\.md$/.test(f));
  if (masters.length === 0) return null;
  const projects = [...new Set(files.map((f) => f.split(/[/\\]/)[0]))];
  return projects.length === 1 ? { from: `design-system/${projects[0]}` } : { from: 'design-system' };
}

/** The doc-site config found in the project, or null. */
function detectDocSite(projectRoot) {
  return DOC_SITE_CONFIGS.find((rel) => fs.existsSync(path.join(projectRoot, rel))) || null;
}

/**
 * Old-layout locations that exist in the project, in move order, each with its new place.
 * `docs/assets` is left out when docs/ is a documentation site (its assets belong to the site).
 * @returns {Array<{from: string, to: string}>}
 */
function legacyCandidates(projectRoot, { docs = 'docs', plans = 'plans' } = {}) {
  const roots = { docs, plans };
  const docSite = docs === 'docs' ? detectDocSite(projectRoot) : null;
  const out = [];
  for (const move of LEGACY_MOVES) {
    let from = resolveLocation(move.from, roots);
    const to = resolveLocation(move.to, roots);
    if (from === to || !fs.existsSync(path.join(projectRoot, from))) continue;
    if (move.from === 'docs:assets' && docSite) continue;
    if (move.from === 'repo:design-system') {
      const source = designSystemDocsSource(projectRoot);
      if (!source) continue;
      from = source.from;
    }
    if (move.from === 'repo:journals' && !fs.statSync(path.join(projectRoot, from)).isDirectory()) continue;
    out.push({ from, to });
  }
  return out;
}

/** Turn `<root>:<path>` into a project-relative POSIX path. */
function resolveLocation(location, { docs = 'docs', plans = 'plans' } = {}) {
  const sep = location.indexOf(':');
  const root = location.slice(0, sep);
  const rest = location.slice(sep + 1);
  const base = root === 'docs' ? docs : root === 'plans' ? plans : '';
  return base ? path.posix.join(base, rest) : rest;
}

/** `description` from the front matter, else the first heading, else ''. */
function describeMarkdown(text) {
  const fm = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (fm) {
    const line = fm[1].split(/\r?\n/).find((l) => /^description:\s*/.test(l));
    if (line) return line.replace(/^description:\s*/, '').replace(/^["']|["']$/g, '').trim();
  }
  const heading = text.match(/^#\s+(.+)$/m);
  return heading ? heading[1].trim() : '';
}

/**
 * Markdown files directly in <docsDir>/conventions/, sorted, with their one-line description.
 * @returns {Array<{file: string, description: string}>}
 */
function listConventions(docsDir) {
  const dir = path.join(docsDir, 'conventions');
  let names;
  try { names = fs.readdirSync(dir, { withFileTypes: true }); } catch { return []; }
  return names
    .filter((d) => d.isFile() && d.name.endsWith('.md') && d.name.toLowerCase() !== 'readme.md')
    .map((d) => d.name)
    .sort()
    .map((file) => {
      let description = '';
      try { description = describeMarkdown(fs.readFileSync(path.join(dir, file), 'utf8').slice(0, 4000)); } catch { /* unreadable: list it bare */ }
      return { file, description: description.length > MAX_DESCRIPTION ? `${description.slice(0, MAX_DESCRIPTION - 1)}…` : description };
    });
}

/** Lines for the session context, or [] when there are no conventions. */
function formatConventionsIndex(entries, docsRel) {
  if (entries.length === 0) return [];
  const dir = `${docsRel.replace(/\/+$/, '')}/conventions`;
  const shown = entries.slice(0, MAX_INDEX_LINES);
  const lines = [`Project conventions in ${dir}/ (read the file a task needs before doing it):`];
  for (const { file, description } of shown) lines.push(`- ${file}${description ? ` — ${description}` : ''}`);
  if (entries.length > shown.length) lines.push(`- … ${entries.length - shown.length} more in ${dir}/`);
  return lines;
}

/**
 * Old-layout paths that exist in the project, with where they belong now.
 * Also lists `.claude/rules/project-*.md`, which now belong in docs/conventions/.
 * @returns {Array<{from: string, to: string}>} project-relative paths
 */
function detectLegacyLayout(projectRoot, { docs = 'docs', plans = 'plans' } = {}) {
  const found = [];
  const covered = new Set();
  for (const { from, to } of legacyCandidates(projectRoot, { docs, plans })) {
    if ([...covered].some((dir) => from.startsWith(`${dir}/`))) continue;
    found.push({ from, to });
    covered.add(from);
  }
  let rules = [];
  try { rules = fs.readdirSync(path.join(projectRoot, '.claude', 'rules')).filter((n) => /^project-.+\.md$/.test(n)).sort(); } catch { /* no rules dir */ }
  for (const name of rules) found.push({ from: `.claude/rules/${name}`, to: `${docs}/conventions/${name.replace(/^project-/, '')}` });
  return found;
}

/**
 * Lines for the session context, or [] when the project is on the current layout.
 * When docs/ is a documentation site, the advice is to give ADF its own docs root instead of migrating.
 */
function formatLegacyNotice(found, { docSite = null } = {}) {
  if (found.length === 0) return [];
  if (docSite) {
    return [
      `[!] docs/ looks like a documentation site (${docSite}). Do not migrate it; suggest setting "paths.docs" in .claude/config/adf-config.json to another folder (for example "project-docs") for ADF's docs.`,
      'To hide this note, set "docs": { "legacyLayoutNotice": false } in the same file.',
    ];
  }
  const lines = ['[!] This project still uses the old docs layout. Until it is migrated, read and update the files where they are now:'];
  for (const { from, to } of found.slice(0, MAX_INDEX_LINES)) lines.push(`- ${from} (new place: ${to})`);
  if (found.length > MAX_INDEX_LINES) lines.push(`- … ${found.length - MAX_INDEX_LINES} more`);
  lines.push('Suggest `/docs migrate` to the user (it shows the plan first); do not move files without asking. To hide this note, set "docs": { "legacyLayoutNotice": false } in .claude/config/adf-config.json.');
  return lines;
}

module.exports = {
  DOCS_FOLDERS, LEGACY_MOVES, DOC_SITE_CONFIGS, normalizeDocsRoot, renderableText, designSystemDocsSource, detectDocSite, legacyCandidates, resolveLocation, describeMarkdown, listConventions, formatConventionsIndex, detectLegacyLayout, formatLegacyNotice,
};
