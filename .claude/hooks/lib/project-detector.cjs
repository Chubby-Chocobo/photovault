#!/usr/bin/env node
/**
 * project-detector.cjs - Project and environment detection logic
 *
 * Extracted from session-init.cjs for reuse in Claude hooks.
 * Detects project type, package manager, framework, and runtime versions.
 *
 * @module project-detector
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync, execFileSync } = require('child_process');
const { detectRepoShape } = require('./repo-shape-detector.cjs');

// ═══════════════════════════════════════════════════════════════════════════
// SAFE EXECUTION HELPERS
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Safely execute shell command with optional timeout
 * @param {string} cmd - Command to execute
 * @param {number} [timeoutMs=5000] - Timeout in milliseconds
 * @returns {string|null} Output or null on error
 */
function execSafe(cmd, timeoutMs = 5000) {
  try {
    return execSync(cmd, {
      encoding: 'utf8',
      timeout: timeoutMs,
      stdio: ['pipe', 'pipe', 'pipe']
    }).trim();
  } catch (e) {
    return null;
  }
}

/**
 * Safely execute a binary with arguments (no shell interpolation)
 * @param {string} binary - Path to the executable
 * @param {string[]} args - Arguments array
 * @param {number} [timeoutMs=2000] - Timeout in milliseconds
 * @returns {string|null} Output or null on error
 */
function execFileSafe(binary, args, timeoutMs = 2000) {
  try {
    return execFileSync(binary, args, {
      encoding: 'utf8',
      timeout: timeoutMs,
      stdio: ['pipe', 'pipe', 'pipe']
    }).trim();
  } catch (e) {
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PYTHON DETECTION
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Validate that a path is a file and doesn't contain shell metacharacters
 * @param {string} p - Path to validate
 * @returns {boolean}
 */
function isValidPythonPath(p) {
  if (!p || typeof p !== 'string') return false;
  if (/[;&|`$(){}[\]<>!#*?]/.test(p)) return false;
  try {
    const stat = fs.statSync(p);
    return stat.isFile();
  } catch (e) {
    return false;
  }
}

/**
 * Build platform-specific Python paths for fast filesystem check
 * @returns {string[]} Array of potential Python paths
 */
function getPythonPaths() {
  const paths = [];

  if (process.env.PYTHON_PATH) {
    paths.push(process.env.PYTHON_PATH);
  }

  if (process.platform === 'win32') {
    const localAppData = process.env.LOCALAPPDATA;
    const programFiles = process.env.ProgramFiles || 'C:\\Program Files';
    const programFilesX86 = process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)';

    if (localAppData) {
      paths.push(path.join(localAppData, 'Microsoft', 'WindowsApps', 'python.exe'));
      paths.push(path.join(localAppData, 'Microsoft', 'WindowsApps', 'python3.exe'));
      for (const ver of ['313', '312', '311', '310', '39']) {
        paths.push(path.join(localAppData, 'Programs', 'Python', `Python${ver}`, 'python.exe'));
      }
    }

    for (const ver of ['313', '312', '311', '310', '39']) {
      paths.push(path.join(programFiles, `Python${ver}`, 'python.exe'));
      paths.push(path.join(programFilesX86, `Python${ver}`, 'python.exe'));
    }

    paths.push('C:\\Python313\\python.exe');
    paths.push('C:\\Python312\\python.exe');
    paths.push('C:\\Python311\\python.exe');
    paths.push('C:\\Python310\\python.exe');
    paths.push('C:\\Python39\\python.exe');
  } else {
    paths.push('/usr/bin/python3');
    paths.push('/usr/local/bin/python3');
    paths.push('/opt/homebrew/bin/python3');
    paths.push('/opt/homebrew/bin/python');
    paths.push('/usr/bin/python');
    paths.push('/usr/local/bin/python');
  }

  return paths;
}

/**
 * Find Python binary using fast `which` lookup first, then filesystem check
 * @returns {string|null} Python binary path or null
 */
function findPythonBinary() {
  // Fast path: try `which` command first (10ms vs 2000ms per path)
  if (process.platform !== 'win32') {
    const whichPython3 = execSafe('which python3', 500);
    if (whichPython3 && isValidPythonPath(whichPython3)) return whichPython3;

    const whichPython = execSafe('which python', 500);
    if (whichPython && isValidPythonPath(whichPython)) return whichPython;
  } else {
    // Windows: try `where` command
    const wherePython = execSafe('where python', 500);
    if (wherePython) {
      const firstPath = wherePython.split('\n')[0].trim();
      if (isValidPythonPath(firstPath)) return firstPath;
    }
  }

  // Fallback: check known paths
  const paths = getPythonPaths();
  for (const p of paths) {
    if (isValidPythonPath(p)) return p;
  }
  return null;
}

/**
 * Get Python version with optimized detection
 * @returns {string|null} Python version string or null
 */
function getPythonVersion() {
  const pythonPath = findPythonBinary();
  if (pythonPath) {
    const result = execFileSafe(pythonPath, ['--version']);
    if (result) return result;
  }

  const commands = ['python3', 'python'];
  for (const cmd of commands) {
    const result = execFileSafe(cmd, ['--version']);
    if (result) return result;
  }

  return null;
}

// ═══════════════════════════════════════════════════════════════════════════
// GIT DETECTION
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Check if current directory is inside a git repository (fast check)
 * Uses filesystem traversal instead of git command to avoid command failures
 * @param {string} [startDir] - Directory to check from (defaults to cwd)
 * @returns {boolean}
 */
function isGitRepo(startDir) {
  let dir;
  try {
    dir = startDir || process.cwd();
  } catch (e) {
    // CWD deleted or inaccessible
    return false;
  }
  const root = path.parse(dir).root;

  while (dir !== root) {
    if (fs.existsSync(path.join(dir, '.git'))) return true;
    dir = path.dirname(dir);
  }
  return fs.existsSync(path.join(root, '.git'));
}

/**
 * Get git remote URL
 * @returns {string|null}
 */
function getGitRemoteUrl() {
  if (!isGitRepo()) return null;
  return execFileSafe('git', ['config', '--get', 'remote.origin.url']);
}

/**
 * Get current git branch
 * @returns {string|null}
 */
function getGitBranch() {
  if (!isGitRepo()) return null;
  return execFileSafe('git', ['branch', '--show-current']);
}

/**
 * Get git repository root
 * @returns {string|null}
 */
function getGitRoot() {
  if (!isGitRepo()) return null;
  return execFileSafe('git', ['rev-parse', '--show-toplevel']);
}

// ═══════════════════════════════════════════════════════════════════════════
// PROJECT DETECTION
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Detect project type: the config override, else the repo shape at `root`
 * @param {string} [configOverride] - Manual override from config
 * @param {string} [root] - Directory to inspect (defaults to cwd)
 * @returns {'workspace' | 'monorepo' | 'superproject' | 'library' | 'single-repo' | string} A non-"auto" override is returned as written
 */
function detectProjectType(configOverride, root = process.cwd()) {
  if (configOverride && configOverride !== 'auto') return configOverride;
  return detectRepoShape(root).type;
}

/**
 * Detect package manager from lock files
 * @param {string} [configOverride] - Manual override from config
 * @returns {'npm' | 'pnpm' | 'yarn' | 'bun' | null}
 */
function detectPackageManager(configOverride) {
  if (configOverride && configOverride !== 'auto') return configOverride;

  if (fs.existsSync('bun.lockb')) return 'bun';
  if (fs.existsSync('pnpm-lock.yaml')) return 'pnpm';
  if (fs.existsSync('yarn.lock')) return 'yarn';
  if (fs.existsSync('package-lock.json')) return 'npm';

  return null;
}

/**
 * Detect framework from package.json dependencies
 * @param {string} [configOverride] - Manual override from config
 * @returns {string|null}
 */
function detectFramework(configOverride) {
  if (configOverride && configOverride !== 'auto') return configOverride;
  if (!fs.existsSync('package.json')) return null;

  try {
    const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
    const deps = { ...pkg.dependencies, ...pkg.devDependencies };

    if (deps['next']) return 'next';
    if (deps['nuxt']) return 'nuxt';
    if (deps['astro']) return 'astro';
    if (deps['@remix-run/node'] || deps['@remix-run/react']) return 'remix';
    if (deps['svelte'] || deps['@sveltejs/kit']) return 'svelte';
    if (deps['vue']) return 'vue';
    if (deps['react']) return 'react';
    if (deps['express']) return 'express';
    if (deps['fastify']) return 'fastify';
    if (deps['hono']) return 'hono';
    if (deps['elysia']) return 'elysia';

    return null;
  } catch (e) {
    return null;
  }
}


// ═══════════════════════════════════════════════════════════════════════════
// CONTEXT OUTPUT
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Short reason after the project type: signal names, sibling submodules or nested repos
 * @param {Object|undefined} shape - Result of detectRepoShape
 * @returns {string} e.g. " (go.work, turbo.json)" or ""
 */
function describeShape(shape) {
  if (!shape) return '';
  const siblings = (shape.submodules || []).filter(s => s.kind === 'sibling').map(s => s.path);
  if (shape.type === 'monorepo' && shape.signals?.length) return ` (${shape.signals.join(', ')})`;
  if (shape.type === 'superproject' && siblings.length) return ` (sibling submodules: ${siblings.join(', ')})`;
  if (shape.hint === 'workspace-candidate') {
    return ` (looks like a workspace: ${shape.nestedRepos.length} nested repos; run /workspace init)`;
  }
  return '';
}

/**
 * Build context summary for output (compact, single line)
 * @param {Object} config - Loaded config
 * @param {Object} detections - Project detections
 * @param {{ path: string|null, resolvedBy: string|null }} resolved - Plan resolution
 * @param {string|null} gitRoot - Git repository root
 * @param {Object} [shape] - Optional detectRepoShape result, adds the reason to the type
 * @returns {string}
 */
function buildContextOutput(config, detections, resolved, gitRoot, shape) {
  const lines = [`Project: ${detections.type || 'unknown'}${shape?.type === detections.type ? describeShape(shape) : ''}`];
  if (detections.pm) lines.push(`PM: ${detections.pm}`);
  lines.push(`Plan naming: ${config.plan.namingFormat}`);

  if (gitRoot && gitRoot !== process.cwd()) {
    lines.push(`Root: ${gitRoot}`);
  }

  if (resolved.path) {
    if (resolved.resolvedBy === 'session') {
      lines.push(`Plan: ${resolved.path}`);
    } else {
      lines.push(`Suggested: ${resolved.path}`);
    }
  }

  return lines.join(' | ');
}

// ═══════════════════════════════════════════════════════════════════════════
// MAIN ENTRY POINT
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Build static environment info object
 * @param {string} [configDir] - Config directory path
 * @returns {Object} Static environment info
 */
function buildStaticEnv(configDir) {
  return {
    nodeVersion: process.version,
    pythonVersion: getPythonVersion(),
    osPlatform: process.platform,
    gitUrl: getGitRemoteUrl(),
    gitBranch: getGitBranch(),
    gitRoot: getGitRoot(),
    user: process.env.USERNAME || process.env.USER || process.env.LOGNAME || os.userInfo().username,
    locale: process.env.LANG || '',
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    configDir: configDir || path.join(process.cwd(), '.claude')
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════════════════

module.exports = {
  // Main entry points
  buildStaticEnv,

  // Detection functions
  detectProjectType,
  detectPackageManager,
  detectFramework,
  detectRepoShape,

  // Python detection
  getPythonVersion,
  findPythonBinary,
  getPythonPaths,
  isValidPythonPath,

  // Git detection
  isGitRepo,
  getGitRemoteUrl,
  getGitBranch,
  getGitRoot,

  // Output
  buildContextOutput,

  // Helpers
  execSafe,
  execFileSafe
};
