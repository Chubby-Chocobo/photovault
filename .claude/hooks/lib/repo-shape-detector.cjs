/**
 * repo-shape-detector.cjs - Polyglot repo-shape detection for hooks and skill scripts.
 *
 * Tells a workspace, monorepo, superproject, library and single repo apart from a handful of
 * stat calls and one readdir per role dir. No recursive walk, no dependencies, fail-open: any
 * fs error makes that one check report "nothing found".
 *
 * @module repo-shape-detector
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { ownerOf, stripCredentials, originUrl } = require('./git-remote-url.cjs');
const { readTextCapped } = require('./read-text-capped.cjs');

const BUILD_FILES = ['package.json', 'go.mod', 'Cargo.toml', 'pyproject.toml', 'requirements.txt', 'pom.xml', 'build.gradle', 'build.gradle.kts', 'foundry.toml', 'composer.json'];
const DEFAULT_ROLE_DIRS = ['services', 'apps', 'contracts', 'infra'];
// contracts/ and infra/ subdirs are not app components, so one repo with infra/terraform is not a monorepo
const COMPONENT_ROLE_DIRS = ['services', 'apps'];
const VENDORED_PREFIXES = ['lib/', 'vendor/', 'external/'];

const ROLE_DIRS_SIGNAL = 'services/+apps/';
const MANIFEST_FILE = 'adf-workspace.json';
const FILE_SIGNALS = ['pnpm-workspace.yaml', 'lerna.json', 'go.work', 'nx.json', 'turbo.json', 'MODULE.bazel', 'WORKSPACE', 'WORKSPACE.bazel'];
const MAX_TEXT_BYTES = 256 * 1024;
const MAX_DIR_ENTRIES = 500;

function isFile(p) {
  try { return fs.statSync(p).isFile(); } catch { return false; }
}

const readText = (p) => readTextCapped(p, MAX_TEXT_BYTES) || '';

function readJson(p) {
  try { return JSON.parse(readText(p)); } catch { return null; }
}

/** A role dir name is a relative path with no `..`; anything else is ignored. */
function safeRoleDirs(roleDirs) {
  const list = Array.isArray(roleDirs) ? roleDirs : DEFAULT_ROLE_DIRS;
  return list.filter(d => typeof d === 'string' && d && !path.isAbsolute(d) && !d.split(/[\\/]/).includes('..'));
}

/**
 * One readdir per role dir; a subdirectory with its own .git (dir or file) is a nested repo.
 * @returns {{ rel: string, isRepo: boolean, hasBuild: boolean }[]}
 */
function scanRoleDirs(root, roleDirs, { build }) {
  const found = [];
  for (const dir of safeRoleDirs(roleDirs)) {
    let entries;
    try { entries = fs.readdirSync(path.join(root, dir), { withFileTypes: true }); } catch { continue; }
    for (const entry of entries.slice(0, MAX_DIR_ENTRIES)) {
      // Symlinked entries are skipped on purpose: members are plain clones (bootstrap refuses symlinks)
      if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
      const abs = path.join(root, dir, entry.name);
      let isRepo = false;
      try { isRepo = fs.existsSync(path.join(abs, '.git')); } catch { /* not a repo */ }
      const hasBuild = build && !isRepo && BUILD_FILES.some(f => isFile(path.join(abs, f)));
      found.push({ rel: `${dir}/${entry.name}`, isRepo, hasBuild });
    }
  }
  return found;
}

/** Component directories (own build file, not their own repo) under services/ and apps/. */
function roleDirComponents(root) {
  return scanRoleDirs(root, COMPONENT_ROLE_DIRS, { build: true }).filter(e => e.hasBuild).map(e => e.rel);
}

/** Role-dir subdirectories that are their own git repos. */
function nestedRepos(root, roleDirs = DEFAULT_ROLE_DIRS) {
  return scanRoleDirs(root, roleDirs, { build: false }).filter(e => e.isRepo).map(e => e.rel);
}

/** Names of the monorepo signals present at the root (empty array: none). */
function monorepoSignals(root) {
  const signals = FILE_SIGNALS.filter(f => isFile(path.join(root, f)));
  const pkg = readJson(path.join(root, 'package.json'));
  if (pkg && pkg.workspaces) signals.push('package.json workspaces');
  if (/^\s*\[workspace\]\s*$/m.test(readText(path.join(root, 'Cargo.toml')))) signals.push('Cargo.toml [workspace]');
  if (/^\s*\[tool\.uv\.workspace\]\s*$/m.test(readText(path.join(root, 'pyproject.toml')))) signals.push('pyproject.toml [tool.uv.workspace]');
  if (roleDirComponents(root).length >= 2) signals.push(ROLE_DIRS_SIGNAL);
  return signals;
}

/**
 * @param {string} text .gitmodules content
 * @returns {{ name: string, path: string, url: string }[]} sections that have both a path and a url
 */
function parseGitmodules(text) {
  const out = [];
  let current = null;
  for (const raw of String(text || '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#') || line.startsWith(';')) continue;
    const section = /^\[submodule\s+"(.*)"\]$/.exec(line);
    if (section) {
      current = { name: section[1], path: '', url: '' };
      out.push(current);
      continue;
    }
    const kv = current && /^([A-Za-z][\w-]*)\s*=\s*(.*)$/.exec(line);
    const key = kv && kv[1].toLowerCase(); // git config keys are case-insensitive
    if (kv && (key === 'path' || key === 'url')) {
      // A quoted value is taken whole; an unquoted one ends at an inline `;` or `#` comment
      const value = kv[2].trim();
      const quoted = /^"(.*)"/.exec(value);
      current[key] = quoted ? quoted[1] : value.replace(/\s*[;#].*$/, '').trim();
    }
  }
  return out.filter(s => s.path && s.url);
}

/**
 * @param {{ path: string, url: string }} sub
 * @param {string[]|null} orgs Trusted owners; null/empty: classify by the path rule only
 * @returns {'vendored'|'sibling'}
 */
function classifySubmodule(sub, orgs) {
  const subPath = String(sub.path).replace(/\\/g, '/').replace(/^\.\//, '');
  if (VENDORED_PREFIXES.some(prefix => subPath.startsWith(prefix))) return 'vendored';
  if (/^\.{1,2}\//.test(sub.url)) return 'sibling';
  if (!Array.isArray(orgs) || orgs.length === 0) return 'sibling';
  const owner = ownerOf(sub.url);
  return owner && orgs.some(o => String(o).toLowerCase() === owner.toLowerCase()) ? 'sibling' : 'vendored';
}

/** Owner of the root's origin remote, or null. One git config call. */
function originOwner(root) {
  const url = originUrl(root, { timeoutMs: 2000 });
  return url ? ownerOf(url) : null;
}

/**
 * @param {string} root Directory to inspect
 * @param {{ orgs?: string[], roleDirs?: string[] }} [opts] orgs: trusted owners for submodule URLs (default: the origin owner)
 * @returns {{ type: 'workspace'|'monorepo'|'superproject'|'library'|'single-repo', signals: string[], submodules: { name: string, path: string, url: string, kind: 'vendored'|'sibling' }[], nestedRepos: string[], hint: 'workspace-candidate'|null, orgUnknown: boolean }}
 */
function detectRepoShape(root, opts = {}) {
  if (typeof root !== 'string' || !root) root = process.cwd(); // fail-open for callers without a root
  const signals = monorepoSignals(root);
  const nested = nestedRepos(root, opts.roleDirs);

  const parsed = parseGitmodules(readText(path.join(root, '.gitmodules')));
  let orgs = Array.isArray(opts.orgs) && opts.orgs.length > 0 ? opts.orgs : null;
  if (!orgs && parsed.length > 0) {
    const owner = originOwner(root);
    orgs = owner ? [owner] : null;
  }
  const submodules = parsed.map(s => ({ ...s, url: stripCredentials(s.url), kind: classifySubmodule(s, orgs) }));

  const pkg = readJson(path.join(root, 'package.json'));
  let type = 'single-repo';
  if (isFile(path.join(root, MANIFEST_FILE))) type = 'workspace';
  else if (signals.length > 0) type = 'monorepo';
  else if (submodules.some(s => s.kind === 'sibling')) type = 'superproject';
  else if (pkg && (pkg.main || pkg.exports)) type = 'library';

  return {
    type,
    signals,
    submodules,
    nestedRepos: nested,
    hint: type !== 'workspace' && nested.length >= 2 ? 'workspace-candidate' : null,
    orgUnknown: submodules.length > 0 && !orgs,
  };
}

module.exports = {
  MANIFEST_FILE,
  BUILD_FILES,
  DEFAULT_ROLE_DIRS,
  COMPONENT_ROLE_DIRS,
  VENDORED_PREFIXES,
  monorepoSignals,
  roleDirComponents,
  nestedRepos,
  parseGitmodules,
  classifySubmodule,
  detectRepoShape,
};
