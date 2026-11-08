#!/usr/bin/env node
/**
 * Git Worktree Manager for ADF
 * Cross-platform Node.js script for creating isolated git worktrees
 *
 * Usage: node worktree.cjs <command> [options]
 * Commands:
 *   create <project> <feature>  Create a new worktree (project optional for standalone)
 *   remove <name-or-path>       Remove a worktree (exact name, path or branch); keeps the branch
 *   create-scope <feature> --plan <dir>  Workspace: one worktree per member in the plan scope
 *   remove-scope <feature> --plan <dir>  Workspace: remove those worktrees (branches kept)
 *   info                        Get repo info (type, projects, env files)
 *   list                        List existing worktrees
 *   status                      Show worktree health and branch status
 *   prune                       Remove stale worktree metadata
 *
 * Options:
 *   --prefix <type>        Branch prefix (feat|fix|refactor|docs|test|chore|perf)
 *   --base <branch>        Override the base branch (default: from the git workflow, else dev→develop→main→master)
 *   --checkout-submodules  Initialize submodules in the new worktree after create
 *   --worktree-root <path> Explicit worktree directory (Claude's decision)
 *   --json                 Output in JSON format for LLM consumption
 *   --env <files>          Comma-separated list of .env files to copy (legacy)
 *   --force                remove: discard uncommitted/untracked changes (git --force)
 *   --delete-branch        remove: also delete the branch with git branch -d (never -D)
 *   --dry-run              Show what would be done without executing
 *   --no-prefix            Skip branch prefix and preserve original case
 */

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { listProjects, runScope } = require('./lib/workspace-projects.cjs');

function sanitizeBranchPrefix(value) {
  const raw = String(value || '').trim().toLowerCase();
  if (!raw) return 'feat';
  const safe = raw
    .replace(/[^a-z0-9-]/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 20);
  return safe || 'feat';
}

function isSafeEnvFileName(fileName) {
  if (!fileName || typeof fileName !== 'string') return false;
  if (fileName.includes('\0')) return false;
  if (path.isAbsolute(fileName)) return false;
  const normalized = path.normalize(fileName.trim());
  if (normalized.startsWith('..') || normalized.includes(`..${path.sep}`)) return false;
  if (normalized.includes(path.sep)) return false;
  return /^\.env[\w.-]*$/.test(normalized);
}

// Sanitize and validate base branch name to prevent command injection
// Returns null if invalid (caller should fall back to auto-detection or error)
function sanitizeBaseBranch(value) {
  if (!value || typeof value !== 'string') return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  // Reject values that look like flags (start with -)
  if (trimmed.startsWith('-')) return { error: 'LOOKS_LIKE_FLAG', value: trimmed };
  // Reject shell metacharacters that could enable command injection
  if (/[;|&$`()\n\r\0\\'"<>]/.test(trimmed)) return { error: 'SHELL_CHARS', value: trimmed };
  // Allow valid git ref characters: alphanumeric, dash, underscore, slash, dot, tilde, caret, at, colon
  // This covers: branch names, remote refs (origin/main), HEAD~N, HEAD^, tags, etc.
  if (!/^[a-zA-Z0-9_./:~^@-]+$/.test(trimmed)) return { error: 'INVALID_CHARS', value: trimmed };
  return trimmed;
}

// Minimum Node.js version check
const MIN_NODE_VERSION = 18;
const nodeVersion = parseInt(process.version.slice(1).split('.')[0], 10);
if (nodeVersion < MIN_NODE_VERSION) {
  outputError('NODE_VERSION_ERROR', `Node.js ${MIN_NODE_VERSION}+ required. Current: ${process.version}`);
  process.exit(1);
}

// Parse arguments
const args = process.argv.slice(2);
const jsonOutput = args.includes('--json');
const jsonIndex = args.indexOf('--json');
if (jsonIndex > -1) args.splice(jsonIndex, 1);

const prefixIndex = args.indexOf('--prefix');
let branchPrefix = 'feat';
let branchPrefixWarning = null;
if (prefixIndex > -1) {
  const rawPrefix = args[prefixIndex + 1] || 'feat';
  branchPrefix = sanitizeBranchPrefix(rawPrefix);
  if (branchPrefix !== rawPrefix.toLowerCase()) {
    branchPrefixWarning = `Branch prefix sanitized: "${rawPrefix}" → "${branchPrefix}"`;
  }
  args.splice(prefixIndex, 2);
}

const envIndex = args.indexOf('--env');
let envFilesToCopy = [];
if (envIndex > -1) {
  envFilesToCopy = (args[envIndex + 1] || '').split(',').map(v => v.trim()).filter(Boolean);
  args.splice(envIndex, 2);
}

const dryRunIndex = args.indexOf('--dry-run');
const dryRun = dryRunIndex > -1;
if (dryRunIndex > -1) args.splice(dryRunIndex, 1);

// --no-prefix: skip branch prefix and preserve original case in feature name
const noPrefixIndex = args.indexOf('--no-prefix');
const noPrefix = noPrefixIndex > -1;
if (noPrefixIndex > -1) args.splice(noPrefixIndex, 1);

// --worktree-root: explicit override for worktree location (Claude's decision)
const worktreeRootIndex = args.indexOf('--worktree-root');
let explicitWorktreeRoot = null;
if (worktreeRootIndex > -1) {
  explicitWorktreeRoot = args[worktreeRootIndex + 1];
  args.splice(worktreeRootIndex, 2);
}

// --base: explicit override for base branch (skip auto-detection)
const baseIndex = args.indexOf('--base');
let explicitBase = null;
let explicitBaseError = null;
if (baseIndex > -1) {
  const rawBase = args[baseIndex + 1];
  const sanitized = sanitizeBaseBranch(rawBase);
  if (sanitized && typeof sanitized === 'object' && sanitized.error) {
    // Store error for later — will be reported during cmdCreate
    explicitBaseError = sanitized;
  } else {
    explicitBase = sanitized; // null if empty/invalid, string if valid
  }
  args.splice(baseIndex, 2);
}

// --plan: plan folder whose scope create-scope / remove-scope act on
const planIndex = args.indexOf('--plan');
const planDir = planIndex > -1 ? args[planIndex + 1] : null;
if (planIndex > -1) args.splice(planIndex, 2);

const checkoutSubmodulesIndex = args.indexOf('--checkout-submodules');
const checkoutSubmodules = checkoutSubmodulesIndex > -1;
if (checkoutSubmodulesIndex > -1) args.splice(checkoutSubmodulesIndex, 1);

// remove: --force discards uncommitted work, --delete-branch also runs `git branch -d`
const forceIndex = args.indexOf('--force');
const force = forceIndex > -1;
if (forceIndex > -1) args.splice(forceIndex, 1);

const deleteBranchIndex = args.indexOf('--delete-branch');
const deleteBranch = deleteBranchIndex > -1;
if (deleteBranchIndex > -1) args.splice(deleteBranchIndex, 1);

const command = args[0];
// For create: args[1] is project (or feature for standalone), args[2] is feature
// For remove: args[1] is worktree name or path
const arg1 = args[1];
const arg2 = args[2];

// Output helpers
function output(data) {
  if (jsonOutput) {
    console.log(JSON.stringify(data, null, 2));
  } else {
    if (data.success) {
      console.log(`\n✅ ${data.message}`);
      if (data.worktreePath) {
        console.log(`\n📋 Next Steps:`);
        console.log(`   1. cd ${data.worktreePath}`);
        console.log(`   2. claude`);
        console.log(`   3. Start working on your feature`);
        console.log(`\n🧹 Cleanup when done:`);
        console.log(`   git worktree remove ${data.worktreePath}`);
        console.log(`   git branch -d ${data.branch}`);
      }
      if (data.envTemplatesCopied && data.envTemplatesCopied.length > 0) {
        console.log(`\n📄 Environment templates copied:`);
        data.envTemplatesCopied.forEach(t => console.log(`   ✓ ${t.from} → ${t.to}`));
      }
      if (data.envFilesCopied && data.envFilesCopied.length > 0) {
        console.log(`\n📄 Environment files copied:`);
        data.envFilesCopied.forEach(f => console.log(`   ✓ ${f}`));
      }
      if (data.warnings && data.warnings.length > 0) {
        console.log(`\n⚠️  Warnings:`);
        data.warnings.forEach(w => console.log(`   ${w}`));
      }
    } else if (data.info) {
      // Info output
      console.log(`\n📦 Repository Info:`);
      console.log(`   Type: ${data.repoType}`);
      console.log(`   Base branch: ${data.baseBranch}`);
      if (data.worktreeRoot) {
        console.log(`\n📂 Worktree location:`);
        console.log(`   Path: ${data.worktreeRoot}`);
        console.log(`   Source: ${data.worktreeRootSource}`);
      }
      if (data.projects && data.projects.length > 0) {
        console.log(`\n📁 Available projects:`);
        data.projects.forEach(p => console.log(`   - ${p.name} (${p.path})`));
      }
      if (data.envFiles && data.envFiles.length > 0) {
        console.log(`\n🔐 Environment files found:`);
        data.envFiles.forEach(f => console.log(`   - ${f}`));
      }
      if (data.dirtyState) {
        console.log(`\n⚠️  Working directory has uncommitted changes`);
      }
    }
  }
}

function outputError(code, message, details = {}) {
  const errorData = {
    success: false,
    error: { code, message, ...details }
  };
  if (jsonOutput) {
    console.log(JSON.stringify(errorData, null, 2));
  } else {
    console.error(`\n❌ Error [${code}]: ${message}`);
    if (details.suggestion) {
      console.error(`   💡 ${details.suggestion}`);
    }
    if (details.availableProjects) {
      console.error(`\n   Available projects:`);
      details.availableProjects.forEach(p => console.error(`     - ${p}`));
    }
  }
  process.exit(1);
}

// Git wrapper with error handling. args is an argv array: no shell is involved,
// so ref names and paths are never interpreted.
function git(args, options = {}) {
  try {
    const result = execFileSync('git', args, {
      encoding: 'utf-8',
      stdio: options.silent ? 'pipe' : ['pipe', 'pipe', 'pipe'],
      cwd: options.cwd || process.cwd()
    });
    return { success: true, output: result.trim() };
  } catch (error) {
    return {
      success: false,
      error: error.message,
      stderr: error.stderr?.toString().trim() || '',
      code: error.status
    };
  }
}

// Check if in git repo
function checkGitRepo() {
  const result = git(['rev-parse', '--show-toplevel'], { silent: true });
  if (!result.success) {
    outputError('NOT_GIT_REPO', 'Not in a git repository', {
      suggestion: 'Run this command from within a git repository'
    });
  }
  return result.output;
}

// Check git version supports worktree
function checkGitVersion() {
  const result = git(['worktree', 'list'], { silent: true });
  if (!result.success && result.stderr.includes('not a git command')) {
    outputError('GIT_VERSION_ERROR', 'Git version too old (worktree requires git 2.5+)', {
      suggestion: 'Upgrade git to version 2.5 or newer'
    });
  }
}

// Detect base branch
function detectBaseBranch(cwd) {
  const branches = ['dev', 'develop', 'main', 'master'];
  for (const branch of branches) {
    const local = git(['show-ref', '--verify', '--quiet', `refs/heads/${branch}`], { silent: true, cwd });
    if (local.success) return branch;
    const remote = git(['show-ref', '--verify', '--quiet', `refs/remotes/origin/${branch}`], { silent: true, cwd });
    if (remote.success) return branch;
  }
  return 'main'; // fallback
}

/**
 * Where a new branch starts under the project's git workflow (git section of adf-config.json):
 * the active release for feat/fix and other work in a release train, the main branch for hotfix and
 * release branches and in trunk. Returns null when the flow is off or ADF's git libs are missing.
 * With no open release, a release train starts from the main branch and says so: a release cut later
 * from main still contains it. Prefers the remote-tracking ref, which is fresher.
 */
function flowBaseBranch(cwd, prefix) {
  let config;
  let openReleases;
  try {
    config = require('../../../hooks/lib/git-flow-config.cjs').getGitConfig(cwd);
    ({ openReleases } = require('../../git/scripts/lib/release-version.cjs'));
  } catch {
    return null;
  }
  if (!config.enabled) return null;
  const ref = (name) => {
    if (git(['show-ref', '--verify', '--quiet', `refs/remotes/origin/${name}`], { silent: true, cwd }).success) return `origin/${name}`;
    return git(['show-ref', '--verify', '--quiet', `refs/heads/${name}`], { silent: true, cwd }).success ? name : null;
  };
  if (config.flow === 'trunk' || prefix === 'hotfix' || prefix === 'release') return { base: ref(config.mainBranch) };
  // raw execFileSync: this call needs stderr discarded and no exit-status wrapper
  const list = (args) => {
    try { return execFileSync('git', args, { cwd, encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).split('\n').filter(Boolean); } catch { return []; }
  };
  const { open } = openReleases(config, {
    tags: list(['tag', '--list']),
    branches: list(['for-each-ref', '--format=%(refname:lstrip=3)', `refs/remotes/origin/${config.branches.release}`]),
  });
  if (open.length === 0) {
    return { base: ref(config.mainBranch), warning: `No open release branch: starting from ${config.mainBranch}. Cut a release (git-flow.cjs cut-release <x.y.z>) before opening this branch's PR.` };
  }
  return { base: ref(open[0]) };
}

// Find the topmost superproject by walking up the directory tree
// This handles submodules within monorepos - worktrees go to the root monorepo
// Safety limit prevents infinite loops in edge cases (max 10 levels deep)
const MAX_SUPERPROJECT_DEPTH = 10;

function findTopmostSuperproject(gitRoot) {
  let current = gitRoot;
  let topmost = gitRoot;
  let depth = 0;

  // Keep walking up while we find superprojects (with safety limit)
  while (depth < MAX_SUPERPROJECT_DEPTH) {
    const result = git(['rev-parse', '--show-superproject-working-tree'], { silent: true, cwd: current });
    if (!result.success || !result.output) {
      break; // No more superprojects above
    }
    topmost = result.output;
    current = result.output;
    depth++;
  }

  return topmost;
}

// Validate that a path can be used as worktree root (exists or can be created)
function validateWorktreeRoot(rootPath) {
  if (typeof rootPath !== 'string' || rootPath.trim().length === 0) {
    return { valid: false, error: 'Worktree root path is empty' };
  }
  if (/[\0\r\n]/.test(rootPath)) {
    return { valid: false, error: 'Worktree root contains invalid control characters' };
  }
  const resolved = path.resolve(rootPath);

  // Check if path exists and is a directory
  if (fs.existsSync(resolved)) {
    const stat = fs.statSync(resolved);
    if (!stat.isDirectory()) {
      return { valid: false, error: `Path exists but is not a directory: ${resolved}` };
    }
    return { valid: true, path: resolved };
  }

  // Check if parent directory exists (we can create the worktree dir)
  const parent = path.dirname(resolved);
  if (fs.existsSync(parent)) {
    const parentStat = fs.statSync(parent);
    if (!parentStat.isDirectory()) {
      return { valid: false, error: `Parent path is not a directory: ${parent}` };
    }
    return { valid: true, path: resolved };
  }

  // Parent doesn't exist - check if grandparent exists (allows mkdir -p one level)
  const grandparent = path.dirname(parent);
  if (fs.existsSync(grandparent)) {
    return { valid: true, path: resolved };
  }

  return { valid: false, error: `Cannot create worktree directory: parent path does not exist: ${parent}` };
}

// Determine the worktree root directory with priority:
// 1. Explicit --worktree-root flag (Claude's decision)
// 2. WORKTREE_ROOT env var (explicit override)
// 3. Topmost superproject's worktrees/ (for submodules)
// 4. Monorepo: worktrees/ inside repo (keeps related worktrees together)
// 5. Standalone: sibling worktrees/ (avoids polluting repo)
function getWorktreeRoot(gitRoot, isMonorepo, explicitRoot = null) {
  // Priority 0: Explicit --worktree-root flag (Claude's decision)
  if (explicitRoot) {
    const validation = validateWorktreeRoot(explicitRoot);
    if (!validation.valid) {
      outputError('INVALID_WORKTREE_ROOT', validation.error, {
        suggestion: 'Provide a valid directory path that exists or can be created'
      });
    }
    return { dir: validation.path, source: '--worktree-root flag' };
  }

  // Priority 1: Environment variable override
  const envRoot = process.env.WORKTREE_ROOT;
  if (envRoot) {
    const validation = validateWorktreeRoot(envRoot);
    if (!validation.valid) {
      outputError('INVALID_WORKTREE_ROOT', validation.error, {
        suggestion: 'Fix WORKTREE_ROOT env var or unset it'
      });
    }
    return { dir: validation.path, source: 'WORKTREE_ROOT env' };
  }

  // Priority 2: Check for superproject (we might be in a submodule)
  const topmostRoot = findTopmostSuperproject(gitRoot);
  if (topmostRoot !== gitRoot) {
    return {
      dir: path.join(topmostRoot, 'worktrees'),
      source: `superproject (${path.basename(topmostRoot)})`
    };
  }

  // Priority 3: Monorepo - use worktrees/ inside the repo
  // Keeps all project worktrees organized together within the monorepo
  if (isMonorepo) {
    return { dir: path.join(gitRoot, 'worktrees'), source: 'monorepo internal' };
  }

  // Priority 4: Standalone repos - use sibling worktrees/
  // Avoids polluting the repo with worktree directories
  return { dir: path.join(path.dirname(gitRoot), 'worktrees'), source: 'sibling directory' };
}

// Check for uncommitted changes
function checkDirtyState(cwd = process.cwd()) {
  const diff = git(['diff', '--quiet'], { silent: true, cwd });
  const diffCached = git(['diff', '--cached', '--quiet'], { silent: true, cwd });
  return !diff.success || !diffCached.success;
}

// Get dirty state details
function getDirtyStateDetails(cwd = process.cwd()) {
  const status = git(['status', '--porcelain'], { silent: true, cwd });
  if (!status.success) return null;
  const lines = status.output.split('\n').filter(Boolean);
  const modified = lines.filter(l => l.startsWith(' M') || l.startsWith('M ')).length;
  const staged = lines.filter(l => l.startsWith('A ') || l.startsWith('M ') || l.startsWith('D ')).length;
  const untracked = lines.filter(l => l.startsWith('??')).length;
  return { modified, staged, untracked, total: lines.length };
}

// Find .env files
function findEnvFiles(dir) {
  try {
    const files = fs.readdirSync(dir);
    return files.filter(f => {
      if (!f.startsWith('.env')) return false;
      const fullPath = path.join(dir, f);
      const stat = fs.statSync(fullPath);
      return stat.isFile() && !stat.isSymbolicLink();
    });
  } catch {
    return [];
  }
}

// Find .env template files (*.example)
function findEnvTemplates(dir) {
  try {
    const files = fs.readdirSync(dir);
    return files.filter(f => {
      if (!f.startsWith('.env') || !f.endsWith('.example')) return false;
      const fullPath = path.join(dir, f);
      const stat = fs.statSync(fullPath);
      return stat.isFile() && !stat.isSymbolicLink();
    });
  } catch {
    return [];
  }
}

// Copy env templates to worktree (strips .example suffix)
function copyEnvTemplates(srcDir, destDir) {
  const templates = findEnvTemplates(srcDir);
  const copied = [];
  const warnings = [];

  templates.forEach(template => {
    const srcPath = path.join(srcDir, template);
    const destName = template.replace(/\.example$/, '');
    const destPath = path.join(destDir, destName);

    try {
      // COPYFILE_EXCL: never replace a file the checkout already provides (e.g. a tracked .env)
      fs.copyFileSync(srcPath, destPath, fs.constants.COPYFILE_EXCL);
      copied.push({ from: template, to: destName });
    } catch (err) {
      if (err.code === 'EEXIST') return;
      warnings.push(`Failed to copy ${template}: ${err.message}`);
    }
  });

  return { copied, warnings };
}

// Find matching projects
function findMatchingProjects(projects, query) {
  const queryLower = query.toLowerCase();
  const exact = projects.filter(p => p.name.toLowerCase() === queryLower);
  if (exact.length === 1) return exact; // "order" is not ambiguous next to "order-book"
  return projects.filter(p =>
    p.name.toLowerCase().includes(queryLower) ||
    p.path.toLowerCase().includes(queryLower)
  );
}

// Check if branch is already checked out
function isBranchCheckedOut(branchName, cwd) {
  const result = git(['worktree', 'list', '--porcelain'], { silent: true, cwd });
  if (!result.success) return false;
  return result.output.includes(`branch refs/heads/${branchName}`);
}

// Check if branch exists
function branchExists(branchName, cwd) {
  const local = git(['show-ref', '--verify', '--quiet', `refs/heads/${branchName}`], { silent: true, cwd });
  if (local.success) return 'local';
  const remote = git(['show-ref', '--verify', '--quiet', `refs/remotes/origin/${branchName}`], { silent: true, cwd });
  if (remote.success) return 'remote';
  return false;
}

function getGitCommonDir(cwd) {
  const result = git(['rev-parse', '--git-common-dir'], { silent: true, cwd });
  if (!result.success || !result.output) return null;
  return path.resolve(cwd, result.output);
}

function getMainWorktreePath(gitRoot, cwd) {
  const gitCommonDir = getGitCommonDir(cwd);
  if (!gitCommonDir) return gitRoot;

  const configResult = git(['config', '--file', path.join(gitCommonDir, 'config'), '--get', 'core.worktree'], {
    silent: true,
    cwd
  });
  if (!configResult.success || !configResult.output) return gitRoot;

  return path.resolve(gitCommonDir, configResult.output);
}

function parseWorktreeListPorcelain(output, options = {}) {
  const gitCommonDir = options.gitCommonDir ? path.resolve(options.gitCommonDir) : null;
  const mainWorktreePath = options.mainWorktreePath ? path.resolve(options.mainWorktreePath) : null;
  const worktrees = [];
  let current = null;

  output.split('\n').map(line => line.replace(/\r$/, '')).forEach(line => {
    if (!line) {
      if (current && current.path) {
        worktrees.push(current);
      }
      current = null;
      return;
    }

    if (line.startsWith('worktree ')) {
      if (current && current.path) {
        worktrees.push(current);
      }
      current = {
        adminPath: line.slice('worktree '.length),
        path: line.slice('worktree '.length),
        commit: null,
        branch: 'detached',
        bare: false,
        detached: false,
        locked: false,
        prunable: false
      };
      return;
    }

    if (!current) return;

    if (line.startsWith('HEAD ')) {
      current.commit = line.slice('HEAD '.length);
      return;
    }
    if (line.startsWith('branch ')) {
      current.branch = line.replace('branch refs/heads/', '');
      return;
    }
    if (line === 'bare') {
      current.bare = true;
      current.branch = 'bare';
      return;
    }
    if (line === 'detached') {
      current.detached = true;
      current.branch = 'detached';
      return;
    }
    if (line.startsWith('locked')) {
      current.locked = true;
      current.lockReason = line.slice('locked'.length).trim() || null;
      return;
    }
    if (line.startsWith('prunable')) {
      current.prunable = true;
      current.prunableReason = line.slice('prunable'.length).trim() || null;
    }
  });

  if (current && current.path) {
    worktrees.push(current);
  }

  return worktrees.map(worktree => {
    const normalizedAdminPath = path.resolve(worktree.adminPath);
    const normalizedPath = gitCommonDir && mainWorktreePath && normalizedAdminPath === gitCommonDir
      ? mainWorktreePath
      : path.resolve(worktree.path);
    return {
      ...worktree,
      path: normalizedPath,
      isMainWorktree: mainWorktreePath ? normalizedPath === mainWorktreePath : false
    };
  });
}

function getWorktreeRecords(gitRoot, cwd) {
  const result = git(['worktree', 'list', '--porcelain'], { silent: true, cwd });
  if (!result.success) {
    outputError('WORKTREE_LIST_ERROR', 'Failed to list worktrees', {
      suggestion: 'Ensure you are in a git repository'
    });
  }

  return parseWorktreeListPorcelain(result.output, {
    gitCommonDir: getGitCommonDir(cwd),
    mainWorktreePath: getMainWorktreePath(gitRoot, cwd)
  });
}

function getAheadBehind(branchName, baseBranch, cwd) {
  if (!branchName || !baseBranch || branchName === 'detached' || branchName === 'bare') {
    return { ahead: 0, behind: 0 };
  }

  const result = git(['rev-list', '--left-right', '--count', `${branchName}...${baseBranch}`, '--'], { silent: true, cwd });
  if (!result.success || !result.output) {
    return { ahead: 0, behind: 0 };
  }

  const [ahead, behind] = result.output.trim().split(/\s+/).map(value => Number.parseInt(value, 10));
  return {
    ahead: Number.isFinite(ahead) ? ahead : 0,
    behind: Number.isFinite(behind) ? behind : 0
  };
}

// Sanitize feature name to valid branch name
function sanitizeFeatureName(name, preserveCase = false) {
  const raw = String(name || '').trim();
  if (!raw) return '';

  // Keep ASCII branch names; drop diacritics first for better readability.
  let ascii = raw
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '');

  // When preserveCase is true (--no-prefix), keep original casing
  if (!preserveCase) ascii = ascii.toLowerCase();

  // preserveCase (--no-prefix): preserve `/` for multi-segment branch names (e.g. kai/feat/foo)
  // Security: reject `..` path components to prevent directory traversal
  if (preserveCase && ascii.split('/').some(seg => seg === '..')) {
    return '';
  }

  ascii = ascii
    .replace(preserveCase ? /[^a-zA-Z0-9/.-]/g : /[^a-z0-9-]/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');

  if (preserveCase) {
    // Clean up slash sequences: collapse consecutive, trim leading/trailing
    ascii = ascii
      .replace(/\/+/g, '/')
      .replace(/^\/|\/$/g, '');
    // Remove dashes adjacent to slashes (e.g. -/- becomes /)
    ascii = ascii
      .replace(/-?\/-?/g, '/');
  }

  // Multi-segment names need longer limit to accommodate user/type/feature patterns
  ascii = ascii.slice(0, preserveCase ? 80 : 50);

  if (ascii) return ascii;

  // If input had alphanumeric Unicode but collapsed to empty, keep deterministic fallback.
  if (/[\p{L}\p{N}]/u.test(raw)) {
    const hash = crypto.createHash('sha1').update(raw).digest('hex').slice(0, 8);
    return `feature-${hash}`;
  }

  return '';
}

// Flatten branch name segments for filesystem-safe directory naming
function flattenForDirectoryName(branchSegment) {
  return branchSegment.replace(/\//g, '-');
}

// COMMANDS

function cmdInfo() {
  const gitRoot = checkGitRepo();
  checkGitVersion();

  const { repoType, projects } = listProjects(gitRoot);
  const isMonorepo = projects.length > 0;
  const baseBranch = (flowBaseBranch(gitRoot, 'feat') || {}).base || detectBaseBranch(gitRoot);
  const dirtyState = checkDirtyState();
  const dirtyDetails = dirtyState ? getDirtyStateDetails() : null;
  const envFiles = findEnvFiles(gitRoot);

  // Get worktree root info (shows where worktrees will be created)
  const worktreeRoot = getWorktreeRoot(gitRoot, isMonorepo);

  // For monorepo, also check each project for env files
  const projectEnvFiles = {};
  if (isMonorepo) {
    projects.forEach(p => {
      const projectDir = path.join(gitRoot, p.path);
      if (fs.existsSync(projectDir)) {
        const files = findEnvFiles(projectDir);
        if (files.length > 0) {
          projectEnvFiles[p.name] = files;
        }
      }
    });
  }

  output({
    info: true,
    repoType: repoType === 'workspace' ? 'workspace' : isMonorepo ? 'monorepo' : 'standalone',
    gitRoot,
    baseBranch,
    worktreeRoot: worktreeRoot.dir,
    worktreeRootSource: worktreeRoot.source,
    projects: isMonorepo ? projects : [],
    envFiles,
    projectEnvFiles: isMonorepo ? projectEnvFiles : {},
    dirtyState,
    dirtyDetails
  });
}

function cmdList() {
  const gitRoot = checkGitRepo();
  const worktrees = getWorktreeRecords(gitRoot, gitRoot);

  if (jsonOutput) {
    console.log(JSON.stringify({ success: true, worktrees }, null, 2));
  } else {
    console.log('\n📂 Existing worktrees:');
    worktrees.forEach(w => {
      console.log(`   ${w.path}`);
      console.log(`      Branch: ${w.branch} (${(w.commit || '').slice(0, 7)})`);
    });
  }
}

function cmdStatus() {
  const gitRoot = checkGitRepo();
  checkGitVersion();

  const worktrees = getWorktreeRecords(gitRoot, gitRoot).map(worktree => {
    const existsOnDisk = fs.existsSync(worktree.path);
    const isCurrentWorktree = path.resolve(worktree.path) === path.resolve(gitRoot);
    const branchIsTracked = worktree.branch !== 'detached' && worktree.branch !== 'bare';
    const branchExistsLocally = existsOnDisk && branchIsTracked
      ? branchExists(worktree.branch, worktree.path) === 'local'
      : false;
    const baseBranch = existsOnDisk && !worktree.bare ? detectBaseBranch(worktree.path) : null;
    const dirtyState = existsOnDisk && !worktree.bare ? checkDirtyState(worktree.path) : false;
    const dirtyDetails = dirtyState ? getDirtyStateDetails(worktree.path) : null;
    const divergence = existsOnDisk && branchExistsLocally && baseBranch
      ? getAheadBehind(worktree.branch, baseBranch, worktree.path)
      : { ahead: 0, behind: 0 };

    return {
      ...worktree,
      isCurrentWorktree,
      branchExists: branchExistsLocally,
      baseBranch,
      dirtyState,
      dirtyDetails,
      ahead: divergence.ahead,
      behind: divergence.behind
    };
  });

  const currentWorktree = worktrees.find(worktree => worktree.isCurrentWorktree) || null;

  if (jsonOutput) {
    console.log(JSON.stringify({
      success: true,
      currentWorktree,
      worktrees
    }, null, 2));
    return;
  }

  console.log('\n🩺 Worktree Status');
  if (currentWorktree) {
    console.log(`   Current: ${currentWorktree.path}`);
    console.log(`   Branch: ${currentWorktree.branch}`);
    console.log(`   Base: ${currentWorktree.baseBranch || 'n/a'}`);
    console.log(`   Dirty: ${currentWorktree.dirtyState ? 'yes' : 'no'}`);
    console.log(`   Ahead/Behind: ${currentWorktree.ahead}/${currentWorktree.behind}`);
  }

  console.log('\n📂 Known worktrees:');
  worktrees.forEach(worktree => {
    const flags = [];
    if (worktree.isMainWorktree) flags.push('main');
    if (worktree.isCurrentWorktree) flags.push('current');
    if (worktree.dirtyState) flags.push('dirty');
    if (!worktree.branchExists && worktree.branch !== 'detached' && worktree.branch !== 'bare') flags.push('missing-branch');
    if (worktree.prunable) flags.push('prunable');
    const suffix = flags.length > 0 ? ` [${flags.join(', ')}]` : '';
    console.log(`   ${worktree.path}${suffix}`);
    console.log(`      Branch: ${worktree.branch}`);
    console.log(`      Base: ${worktree.baseBranch || 'n/a'} | Ahead/Behind: ${worktree.ahead}/${worktree.behind}`);
  });
}

function cmdCreate() {
  const gitRoot = checkGitRepo();
  checkGitVersion();

  const { projects } = listProjects(gitRoot);
  const isMonorepo = projects.length > 0;
  const warnings = [];
  if (branchPrefixWarning) warnings.push(branchPrefixWarning);
  const safeEnvFilesToCopy = [];
  if (envFilesToCopy.length > 0) {
    envFilesToCopy.forEach(envFile => {
      if (!isSafeEnvFileName(envFile)) {
        warnings.push(`Skipped unsafe env file entry: ${envFile}`);
        return;
      }
      if (!safeEnvFilesToCopy.includes(envFile)) {
        safeEnvFilesToCopy.push(envFile);
      }
    });
  }

  // Parse arguments based on repo type
  // Monorepo: create <project> <feature>
  // Standalone: create <feature>
  let project, feature;
  if (isMonorepo) {
    project = arg1;
    feature = arg2;
    if (!project || !feature) {
      outputError('MISSING_ARGS', 'Both project and feature are required for monorepo', {
        suggestion: 'Usage: node worktree.cjs create <project> <feature> --prefix <type>',
        availableProjects: projects.map(p => p.name)
      });
    }
  } else {
    feature = arg1;
    if (!feature) {
      outputError('MISSING_FEATURE', 'Feature name is required', {
        suggestion: 'Usage: node worktree.cjs create <feature> --prefix <type>'
      });
    }
  }

  // Determine working directory
  let workDir = gitRoot;
  let projectPath = '';
  let projectName = '';

  if (isMonorepo) {
    const matches = findMatchingProjects(projects, project);

    if (matches.length === 0) {
      outputError('PROJECT_NOT_FOUND', `Project "${project}" not found`, {
        suggestion: 'Check available projects with: node worktree.cjs info',
        availableProjects: projects.map(p => p.name)
      });
    }

    if (matches.length > 1) {
      outputError('MULTIPLE_PROJECTS_MATCH', `Multiple projects match "${project}"`, {
        suggestion: 'Use AskUserQuestion to let user select one',
        matchingProjects: matches.map(p => ({ name: p.name, path: p.path }))
      });
    }

    projectPath = matches[0].path;
    projectName = matches[0].name;
    workDir = path.join(gitRoot, projectPath);

    if (!fs.existsSync(workDir)) {
      outputError('PROJECT_DIR_NOT_FOUND', `Project directory not found: ${workDir}`, {
        suggestion: 'Initialize submodules: git submodule update --init'
      });
    }
  }

  // Uncommitted changes in the repo the worktree branches from (the member, in a workspace)
  if (checkDirtyState(workDir)) {
    const details = getDirtyStateDetails(workDir);
    warnings.push(`Uncommitted changes: ${details.modified} modified, ${details.staged} staged, ${details.untracked} untracked`);
  }

  // Sanitize feature name
  const sanitizedFeature = sanitizeFeatureName(feature, noPrefix);
  if (!sanitizedFeature) {
    outputError('INVALID_FEATURE_NAME', 'Feature name became empty after sanitization', {
      suggestion: 'Use letters/numbers in feature name (example: "login-validation")'
    });
  }
  const expectedFeature = noPrefix ? feature.replace(/\s+/g, '-') : feature.toLowerCase().replace(/\s+/g, '-');
  if (sanitizedFeature !== expectedFeature) {
    warnings.push(`Feature name sanitized: "${feature}" → "${sanitizedFeature}"`);
  }

  // Create branch name — --no-prefix uses sanitized feature as-is
  const branchName = noPrefix ? sanitizedFeature : `${branchPrefix}/${sanitizedFeature}`;

  // Handle --base validation errors
  if (explicitBaseError) {
    const errorMessages = {
      LOOKS_LIKE_FLAG: `Base branch "${explicitBaseError.value}" looks like a flag`,
      SHELL_CHARS: `Base branch "${explicitBaseError.value}" contains invalid shell characters`,
      INVALID_CHARS: `Base branch "${explicitBaseError.value}" contains invalid characters`
    };
    outputError('INVALID_BASE_BRANCH', errorMessages[explicitBaseError.error] || 'Invalid base branch', {
      suggestion: 'Provide a valid branch name (e.g., main, dev, feature/branch-name)'
    });
  }

  // Base branch: explicit --base, else the git workflow's, else the first of dev/develop/main/master
  const flowBase = explicitBase ? null : flowBaseBranch(workDir, noPrefix ? null : branchPrefix);
  if (flowBase && flowBase.warning) warnings.push(flowBase.warning);
  const baseBranch = explicitBase || (flowBase && flowBase.base) || detectBaseBranch(workDir);
  const baseBranchSource = explicitBase ? 'explicit' : flowBase && flowBase.base ? 'git-workflow' : 'auto-detected';

  // Validate explicit base branch exists (auto-detected branches are already verified)
  if (explicitBase) {
    const baseExists = branchExists(explicitBase, workDir);
    if (!baseExists) {
      outputError('BASE_BRANCH_NOT_FOUND', `Base branch "${explicitBase}" does not exist`, {
        suggestion: 'Check branch name or use auto-detection by omitting --base',
        availableBranches: ['dev', 'develop', 'main', 'master'].filter(b => branchExists(b, workDir))
      });
    }
  }

  // Check if branch already checked out
  if (isBranchCheckedOut(branchName, workDir)) {
    outputError('BRANCH_CHECKED_OUT', `Branch "${branchName}" is already checked out in another worktree`, {
      suggestion: 'Use a different feature name or remove the existing worktree'
    });
  }

  // Determine worktree path using smart root detection
  // explicitWorktreeRoot comes from --worktree-root flag (Claude's decision)
  const worktreeRoot = getWorktreeRoot(gitRoot, isMonorepo, explicitWorktreeRoot);
  const worktreesDir = worktreeRoot.dir;

  // Build worktree name: always include repo name for clarity
  // Flatten slashes to dashes for filesystem-safe directory names
  const repoName = path.basename(gitRoot);
  const flatFeature = flattenForDirectoryName(sanitizedFeature);
  const worktreeName = isMonorepo
    ? `${projectName}-${flatFeature}`
    : `${repoName}-${flatFeature}`;

  const worktreePath = path.join(worktreesDir, worktreeName);

  // Check if worktree already exists
  if (fs.existsSync(worktreePath)) {
    outputError('WORKTREE_EXISTS', `Worktree already exists: ${worktreePath}`, {
      suggestion: `To use: cd ${worktreePath} && claude\nTo remove: git worktree remove ${worktreePath}`
    });
  }

  // Check if branch exists
  const branchStatus = branchExists(branchName, workDir);

  // Dry-run mode: show what would be done
  if (dryRun) {
    output({
      success: true,
      dryRun: true,
      message: 'Dry run - no changes made',
      wouldCreate: {
        worktreePath,
        worktreeRootSource: worktreeRoot.source,
        branch: branchName,
        baseBranch,
        baseBranchSource,
        checkoutSubmodules,
        branchExists: !!branchStatus,
        project: isMonorepo ? projectName : null,
        envFilesToCopy: safeEnvFilesToCopy.length > 0 ? safeEnvFilesToCopy : undefined
      },
      warnings: warnings.length > 0 ? warnings : undefined
    });
    return;
  }

  // Create worktrees directory
  try {
    fs.mkdirSync(worktreesDir, { recursive: true });
  } catch (err) {
    outputError('MKDIR_FAILED', `Failed to create worktrees directory: ${worktreesDir}`, {
      suggestion: 'Check write permissions'
    });
  }

  // Fetch remote branch if needed
  if (branchStatus === 'remote') {
    const fetchResult = git(['fetch', 'origin', branchName], { silent: true, cwd: workDir });
    if (!fetchResult.success) {
      outputError('FETCH_FAILED', `Failed to fetch branch from remote: ${branchName}`, {
        suggestion: 'Check network connection and remote repository access'
      });
    }
  }

  // Create worktree
  let createResult;
  if (branchStatus) {
    createResult = git(['worktree', 'add', worktreePath, branchName], { cwd: workDir });
  } else {
    createResult = git(['worktree', 'add', '-b', branchName, worktreePath, baseBranch], { cwd: workDir });
  }

  if (!createResult.success) {
    outputError('WORKTREE_CREATE_FAILED', `Failed to create worktree`, {
      suggestion: createResult.stderr || createResult.error,
      gitError: createResult.stderr
    });
  }

  // Auto-copy env templates (.env*.example → .env*)
  const sourceDir = isMonorepo ? workDir : gitRoot;
  const envResult = copyEnvTemplates(sourceDir, worktreePath);
  envResult.warnings.forEach(w => warnings.push(w));

  // Also copy explicitly specified env files (legacy --env flag support). envFilesCopied lists
  // only these real files; files made from templates are reported in envTemplatesCopied.
  const envFilesCopied = [];
  if (safeEnvFilesToCopy.length > 0) {
    safeEnvFilesToCopy.forEach(envFile => {
      const sourcePath = path.join(sourceDir, envFile);
      const destPath = path.join(worktreePath, envFile);
      if (fs.existsSync(sourcePath)) {
        try {
          fs.copyFileSync(sourcePath, destPath);
          if (!envFilesCopied.includes(envFile)) {
            envFilesCopied.push(envFile);
          }
        } catch (err) {
          warnings.push(`Failed to copy ${envFile}: ${err.message}`);
        }
      } else {
        warnings.push(`Env file not found: ${envFile}`);
      }
    });
  }

  if (checkoutSubmodules) {
    const submoduleResult = git(['submodule', 'update', '--init', '--checkout', '--recursive'], {
      silent: true,
      cwd: worktreePath
    });
    if (!submoduleResult.success) {
      outputError('SUBMODULE_CHECKOUT_FAILED', 'Worktree created but submodule checkout failed', {
        suggestion: submoduleResult.stderr || submoduleResult.error || 'Inspect the new worktree and run git submodule update manually',
        worktreePath
      });
    }
  }

  output({
    success: true,
    message: 'Worktree created successfully!',
    worktreePath,
    worktreeRootSource: worktreeRoot.source,
    branch: branchName,
    baseBranch,
    baseBranchSource,
    checkoutSubmodules,
    project: isMonorepo ? projectName : null,
    envFilesCopied,
    // A template whose target was then overwritten by an --env copy no longer applies
    envTemplatesCopied: envResult.copied.filter(c => !envFilesCopied.includes(c.to)),
    warnings: warnings.length > 0 ? warnings : undefined
  });
}

// create-scope / remove-scope: one create / remove per workspace member in the plan scope
function cmdScope(kind) {
  const gitRoot = checkGitRepo();
  if (listProjects(gitRoot).repoType !== 'workspace') outputError('NOT_A_WORKSPACE', `${kind}-scope runs at the root of a workspace (adf-workspace.json)`);
  if (!arg1 || !planDir) outputError('MISSING_ARGS', `Usage: node worktree.cjs ${kind}-scope <feature> --plan <dir> [--prefix <type>] [--dry-run]`);
  const sanitized = sanitizeFeatureName(arg1, noPrefix);
  if (!sanitized) outputError('INVALID_FEATURE_NAME', 'Feature name became empty after sanitization');
  const flags = [...(prefixIndex > -1 ? ['--prefix', branchPrefix] : []), ...(noPrefix ? ['--no-prefix'] : []), ...(kind === 'remove' && force ? ['--force'] : [])];
  const r = runScope(kind, { gitRoot, script: __filename, plan: planDir, feature: arg1, branch: noPrefix ? sanitized : `${branchPrefix}/${sanitized}`, worktreeName: flattenForDirectoryName(sanitized), flags, dryRun });
  if (r.error) outputError('SCOPE_FAILED', r.error);
  console.log(JSON.stringify({ success: r.ok, dryRun: dryRun || undefined, results: r.results }, null, 2));
  if (!r.ok) process.exit(1);
}

function cmdRemove() {
  if (!arg1) {
    outputError('MISSING_WORKTREE', 'Worktree name or path is required', {
      suggestion: 'Usage: node worktree.cjs remove <exact-name-or-path> [--force] [--delete-branch]\nUse "node worktree.cjs list" to see available worktrees'
    });
  }

  const gitRoot = checkGitRepo();
  checkGitVersion();
  const worktrees = getWorktreeRecords(gitRoot, gitRoot);

  // Only an exact name, path or branch selects a worktree; anything looser could delete the wrong one
  // Separators are normalised and a path is resolved against the cwd, so ../wt/foo and C:\\wt\\foo match git's C:/wt/foo
  const toKey = v => v.replace(/\\/g, '/').toLowerCase();
  const searchTerm = toKey(arg1);
  const resolvedTerm = toKey(path.resolve(arg1));
  const removable = worktrees.filter(w => !w.isMainWorktree);
  const fields = w => [path.basename(w.path), w.path, w.adminPath || '', w.branch || ''].map(toKey);
  const removableMatches = removable.filter(w => fields(w).some(v => v === searchTerm || v === resolvedTerm));

  if (removableMatches.length === 0) {
    const candidates = removable
      .filter(w => fields(w).some(v => v.includes(searchTerm)))
      .map(w => ({ name: path.basename(w.path), path: w.path, branch: w.branch }));
    outputError('WORKTREE_NOT_FOUND', `No worktree exactly matching "${arg1}" found`, {
      suggestion: candidates.length > 0
        ? 'Partial matches are never removed. Re-run with the exact name, path or branch of one of the candidates'
        : 'Use "node worktree.cjs list" to see available worktrees',
      candidates,
      availableWorktrees: removable.map(w => path.basename(w.path))
    });
  }

  if (removableMatches.length > 1) {
    outputError('MULTIPLE_WORKTREES_MATCH', `Multiple worktrees match "${arg1}"`, {
      suggestion: 'Use the full path',
      matchingWorktrees: removableMatches.map(w => ({ name: path.basename(w.path), path: w.path, branch: w.branch }))
    });
  }

  const worktree = removableMatches[0];
  const worktreePath = worktree.path;
  const branchName = worktree.branch;
  const hasBranch = !!branchName && branchName !== 'detached' && branchName !== 'bare';

  // Dry-run mode
  if (dryRun) {
    output({
      success: true,
      dryRun: true,
      message: 'Dry run - no changes made',
      wouldRemove: {
        worktreePath,
        branch: branchName,
        force,
        deleteBranch: deleteBranch && hasBranch
      }
    });
    return;
  }

  // Never discard uncommitted or untracked work unless the caller passed --force
  if (!force) {
    // --ignore-submodules=none: a submodule's own changes count even where .gitmodules or git config hides them
    const status = git(['status', '--porcelain', '--ignore-submodules=none'], { silent: true, cwd: worktreePath });
    if (status.success && status.output) {
      outputError('WORKTREE_DIRTY', `Worktree has uncommitted or untracked changes: ${worktreePath}`, {
        suggestion: 'Commit or stash them, or re-run with --force to discard them',
        changes: status.output.split('\n').filter(Boolean).slice(0, 20)
      });
    }
  }

  const removeArgs = ['worktree', 'remove'];
  if (force) removeArgs.push('--force');
  removeArgs.push('--', worktreePath);
  let removeResult = git(removeArgs, { silent: true });
  if (!removeResult.success && !force && /working trees containing submodules cannot be/.test(removeResult.stderr)) {
    // The status check above found nothing to lose, submodules included; git only refuses because the
    // worktree holds checked-out submodules, as create --checkout-submodules leaves it
    removeResult = git(['worktree', 'remove', '--force', '--', worktreePath], { silent: true });
  }
  if (!removeResult.success) {
    outputError('WORKTREE_REMOVE_FAILED', `Failed to remove worktree: ${worktreePath}`, {
      suggestion: removeResult.stderr || 'git refused to remove the worktree',
      gitError: removeResult.stderr
    });
  }

  // The branch is kept unless --delete-branch is given; `git branch -d` only, never -D
  let branchDeleted = false;
  if (deleteBranch && hasBranch) {
    const deleteResult = git(['branch', '-d', '--', branchName], { silent: true, cwd: (worktrees.find(w => w.isMainWorktree) || {}).path || gitRoot });
    if (deleteResult.success) {
      branchDeleted = true;
    } else {
      outputError('BRANCH_DELETE_FAILED', `Worktree removed, but branch ${branchName} was not deleted`, {
        suggestion: `git branch -d refused (${deleteResult.stderr || 'not fully merged'}). If you are sure, delete it yourself with: git branch -D ${branchName}`,
        removedPath: worktreePath,
        branchKept: branchName
      });
    }
  }

  output({
    success: true,
    message: 'Worktree removed successfully!',
    removedPath: worktreePath,
    branchDeleted: branchDeleted ? branchName : null,
    branchKept: !branchDeleted && hasBranch ? branchName : null
  });
}

function cmdPrune() {
  checkGitRepo();
  checkGitVersion();

  const pruneArgs = ['worktree', 'prune'];
  if (dryRun) pruneArgs.push('--dry-run');
  pruneArgs.push('--verbose');

  const pruneResult = git(pruneArgs, { silent: true });
  if (!pruneResult.success) {
    outputError('WORKTREE_PRUNE_FAILED', 'Failed to prune worktree metadata', {
      suggestion: pruneResult.stderr || pruneResult.error
    });
  }

  const entries = pruneResult.output.split('\n').filter(Boolean);
  if (jsonOutput) {
    console.log(JSON.stringify({
      success: true,
      dryRun,
      message: dryRun ? 'Prune dry run completed' : 'Worktree prune completed',
      entries
    }, null, 2));
    return;
  }

  console.log(`\n🧹 Worktree Prune${dryRun ? ' (dry run)' : ''}`);
  if (entries.length === 0) {
    console.log('   No stale worktree metadata found.');
    return;
  }

  entries.forEach(entry => {
    console.log(`   ${entry}`);
  });
}

function showHelp() {
  const help = `Git Worktree Manager for ADF

Usage: node worktree.cjs <command> [options]

Commands:
  create <project> <feature>  Create a new worktree (project optional for standalone)
  remove <name-or-path>       Remove a worktree (exact name, path or branch); keeps the branch
  create-scope <feature>      Workspace: create <member> <feature> for every member in --plan's scope
  remove-scope <feature>      Workspace: remove those worktrees (branches kept)
  info                        Get repo info (type, projects, env files)
  list                        List existing worktrees
  status                      Inspect worktree health and branch status
  prune                       Remove stale worktree metadata

Options:
  --prefix <type>        Branch prefix (feat|fix|refactor|docs|test|chore|perf)
  --base <branch>        Override auto-detected base branch
  --checkout-submodules  Initialize submodules in the new worktree after create
  --worktree-root <path> Explicit worktree directory
  --json                 Output in JSON format for LLM consumption
  --env <files>          Comma-separated list of .env files to copy (legacy)
  --force                remove: discard uncommitted/untracked changes (git --force)
  --delete-branch        remove: also delete the branch with git branch -d (never -D)
  --dry-run              Show what would be done without executing
  --no-prefix            Skip branch prefix and preserve original case
  --plan <dir>           create-scope / remove-scope: the plan folder whose scope names the members
  --help, -h             Show this help message`;
  console.log(help);
}

// Main
function main() {
  if (command === '--help' || command === '-h' || command === 'help') {
    showHelp();
    return;
  }

  switch (command) {
    case 'create':
      cmdCreate();
      break;
    case 'remove':
      cmdRemove();
      break;
    case 'create-scope':
      cmdScope('create');
      break;
    case 'remove-scope':
      cmdScope('remove');
      break;
    case 'info':
      cmdInfo();
      break;
    case 'list':
      cmdList();
      break;
    case 'status':
      cmdStatus();
      break;
    case 'prune':
      cmdPrune();
      break;
    default:
      outputError('UNKNOWN_COMMAND', `Unknown command: ${command || '(none)'}`, {
        suggestion: 'Available commands: create, remove, create-scope, remove-scope, info, list, status, prune. Use --help for usage.'
      });
  }
}

main();
