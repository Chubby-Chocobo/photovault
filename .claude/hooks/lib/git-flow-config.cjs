'use strict';

/**
 * The git workflow settings of a project: the `git` section of .claude/config/adf-config.json
 * (flow, enforcement, mainBranch, versionFiles, directPush.paths, optional tagPrefix and
 * commit.pathTypes) plus everything derived from it. Branch prefixes, merge strategies, protected
 * branches, the direct-push type and the subject limit are fixed by the flow, not configured.
 * Hooks, the git-flow script and CI all read the workflow through getGitConfig().
 */

const fs = require('fs');
const path = require('path');
const { readProjectSection, getProjectRoot } = require('./adf-config-utils.cjs');
const { resolveMemberGitSource, NAME_RE } = require('./workspace-manifest.cjs');
const { relaxLevel } = require('./adf-mode.cjs');

const FLOWS = ['release-train', 'trunk', 'off'];
const LEVELS = ['off', 'ask', 'deny'];
const DEFAULT_TYPES = ['feat', 'fix', 'perf', 'refactor', 'test', 'docs', 'style', 'build', 'ci', 'chore', 'revert'];

const GIT_DEFAULTS = Object.freeze({
  flow: 'release-train',
  enforcement: 'ask',
  mainBranch: 'main',
  versionFiles: [{ path: 'package.json', json: 'version' }],
  directPush: { paths: ['docs/**', '.github/**', 'README.md', 'CHANGELOG.md', 'CLAUDE.md', 'AGENTS.md'] },
  tagPrefix: 'v',
  commit: { pathTypes: {} },
});

const BRANCHES = Object.freeze({ release: 'release/', feature: 'feat/', fix: 'fix/', hotfix: 'hotfix/' });

/** How each kind of branch merges into its base, per flow. */
const MERGE = Object.freeze({
  'release-train': { featureToRelease: 'squash', releaseToMain: 'merge', hotfixToMain: 'squash' },
  trunk: { featureToMain: 'squash', releaseToMain: 'squash', hotfixToMain: 'squash' },
  off: {},
});

const COMMITLINT_JSON = ['.commitlintrc', '.commitlintrc.json'];

/** `**` crosses folders, `*` and `?` stay within one; a trailing `/` matches everything below. */
function globToRegExp(glob) {
  const g = glob.endsWith('/') ? `${glob}**` : glob;
  let re = '';
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === '*' && g[i + 1] === '*') {
      re += g[i + 2] === '/' ? '(?:.*/)?' : '.*';
      i += g[i + 2] === '/' ? 2 : 1;
    } else if (c === '*') re += '[^/]*';
    else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

function matchesAny(file, globs) {
  const rel = file.replace(/\\/g, '/').replace(/^\.\//, '');
  return globs.some((g) => globToRegExp(g).test(rel));
}

/** `type-enum` from the project's JSON commitlint config, or null. JS configs are not executed. */
function readCommitlintTypes(root) {
  const fromRules = (cfg) => {
    const rule = cfg?.rules?.['type-enum'];
    return Array.isArray(rule) && Array.isArray(rule[2]) && rule[2].every((t) => typeof t === 'string') ? rule[2] : null;
  };
  for (const name of COMMITLINT_JSON) {
    try { const types = fromRules(JSON.parse(fs.readFileSync(path.join(root, name), 'utf8'))); if (types) return types; } catch { /* next */ }
  }
  try { return fromRules(JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).commitlint); } catch { return null; }
}

const isRefName = (v) => typeof v === 'string' && /^[A-Za-z0-9._/-]+$/.test(v) && !v.includes('..') && !v.startsWith('/') && !v.endsWith('/');
const isStringArray = (v) => Array.isArray(v) && v.every((x) => typeof x === 'string' && x.trim());

function validVersionFile(v) {
  if (!v || typeof v.path !== 'string' || !v.path.trim() || path.isAbsolute(v.path) || v.path.split(/[\\/]/).includes('..')) return false;
  if (typeof v.json === 'string' && v.json.trim()) return true;
  if (typeof v.regex !== 'string') return false;
  try { new RegExp(v.regex, 'm'); } catch { return false; }
  return /\((?!\?)/.test(v.regex); // the version is the first capture group
}

/**
 * Where a member's rules came from, for the reasons the guards give. The manifest arrives by push
 * and a broken one is read loosely, so the name is printed only when it is a valid member name.
 */
function memberRulesLabel(member) {
  const who = typeof member.member === 'string' && NAME_RE.test(member.member) ? `member ${member.member}` : 'this member';
  if (member.source === 'member config') return `${who}: its .claude/config/adf-config.json`;
  if (member.source === 'manifest') return `${who}: its git entry in adf-workspace.json`;
  return `${who}: the default member rules (no git section in its .claude/config/adf-config.json or adf-workspace.json)`;
}

/**
 * The per-key rules for a raw `git` section (the project's, or a workspace member's): each value is
 * valid or replaced by its default. Pure: no mode relaxation, no member resolution, no file reads, so
 * the result is the same on every machine. getGitConfig() and the settings block in git-workflow.md
 * both read the section through it.
 * @param {object} [raw] the `git` section as written
 */
function normalizeGit(raw) {
  const git = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const versionFilesSet = Array.isArray(git.versionFiles) && git.versionFiles.length > 0 && git.versionFiles.every(validVersionFile);
  const pathTypes = {};
  for (const [prefix, types] of Object.entries(git.commit?.pathTypes || {})) if (isStringArray(types)) pathTypes[prefix] = types;
  return {
    flow: FLOWS.includes(git.flow) ? git.flow : GIT_DEFAULTS.flow,
    enforcement: LEVELS.includes(git.enforcement) ? git.enforcement : GIT_DEFAULTS.enforcement,
    mainBranch: isRefName(git.mainBranch) ? git.mainBranch : GIT_DEFAULTS.mainBranch,
    versionFiles: versionFilesSet ? git.versionFiles : GIT_DEFAULTS.versionFiles,
    versionFilesConfigured: versionFilesSet,
    tagPrefix: typeof git.tagPrefix === 'string' && /^[A-Za-z0-9._-]*$/.test(git.tagPrefix) ? git.tagPrefix : GIT_DEFAULTS.tagPrefix,
    directPushPaths: isStringArray(git.directPush?.paths) ? git.directPush.paths : GIT_DEFAULTS.directPush.paths,
    pathTypes,
  };
}

/**
 * The project's git workflow, with defaults filled in and invalid values replaced by defaults.
 * @param {string} [cwd] directory inside the project
 */
function getGitConfig(cwd = process.cwd()) {
  // Inside a workspace member the member's rules apply, whatever $CLAUDE_PROJECT_DIR says
  const member = resolveMemberGitSource(cwd);
  const root = member ? member.root : getProjectRoot(cwd);
  const raw = member ? member.git : readProjectSection(cwd, 'git');
  const guard = member ? member.commitGuard : readProjectSection(cwd, 'commitGuard');

  const git = normalizeGit(raw);
  const { flow, mainBranch } = git;
  // In auto mode an `ask` runs as `off`; a configured `deny` is kept (see adf-mode.cjs)
  const enforcement = relaxLevel(git.enforcement, cwd);

  // The older commitGuard.messageFormat still decides when it is set: true denies, false turns the check off
  let formatLevel = enforcement;
  if (guard.messageFormat === true) formatLevel = 'deny';
  else if (guard.messageFormat === false) formatLevel = 'off';

  return {
    root,
    // Only inside a member, so a single repo's config object is unchanged
    ...(member ? { rulesFrom: memberRulesLabel(member) } : {}),
    flow,
    enabled: flow !== 'off',
    enforcement,
    mainBranch,
    versionFiles: git.versionFiles,
    versionFilesConfigured: git.versionFilesConfigured,
    tagPrefix: git.tagPrefix,
    branches: BRANCHES,
    merge: MERGE[flow],
    protectedBranches: [mainBranch, `${BRANCHES.release}*`],
    directPush: { types: ['chore'], paths: git.directPushPaths },
    commit: {
      types: isStringArray(guard.types) ? guard.types : readCommitlintTypes(root) || DEFAULT_TYPES,
      subjectMax: 72,
      pathTypes: git.pathTypes,
      formatLevel,
      // commitGuard.secrets: false turns the staged-secret scan off (the guard of the repo being committed decides, not the session's)
      secrets: guard.secrets !== false,
      // commitGuard.allowSecretFiles: globs of files the secret scan skips (a person's entry, e.g. fixtures with fake keys)
      allowSecretFiles: isStringArray(guard.allowSecretFiles) ? guard.allowSecretFiles : [],
    },
  };
}

/** Whether a branch name is protected (the main branch or any release branch). */
function isProtectedBranch(config, branch) {
  return config.protectedBranches.some((p) => (p.endsWith('*') ? branch.startsWith(p.slice(0, -1)) : branch === p));
}

/** feature | fix | hotfix | release | main | other */
function branchKind(config, branch) {
  if (branch === config.mainBranch) return 'main';
  for (const [kind, prefix] of Object.entries(config.branches)) if (branch.startsWith(prefix)) return kind;
  return 'other';
}

// Where a git finding's rules come from when the repository is not a workspace member
const PROJECT_RULES = 'docs/conventions/git-workflow.md';

module.exports = {
  PROJECT_RULES, FLOWS, LEVELS, DEFAULT_TYPES, GIT_DEFAULTS, BRANCHES, MERGE,
  getGitConfig, normalizeGit, isRefName, readCommitlintTypes, globToRegExp, matchesAny, isProtectedBranch, branchKind,
};
