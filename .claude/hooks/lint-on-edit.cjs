#!/usr/bin/env node
/**
 * PostToolUse hook (Edit|Write), registered async with asyncRewake: lints the file Claude just
 * edited with the project's own linter and wakes Claude only when it reports problems.
 *
 * Opt-in: `lintOnEdit.enabled: true` in adf-config.json. Uses only linters the project already
 * has, so nothing is downloaded:
 *   - .js/.jsx/.ts/.tsx/.mjs/.cjs/.mts/.cts: Biome (biome.json[c]) or ESLint (eslint config) from node_modules
 *   - .py: Ruff (ruff.toml, .ruff.toml or [tool.ruff] in pyproject.toml) from .venv or PATH
 * Reports problems; never rewrites the file. Exit 2 + stderr wakes Claude; everything else exits 0.
 * Only linter exit code 1 means "problems found"; 2 and above are config errors or crashes,
 * which would otherwise wake Claude after every edit with the same unrelated message.
 */

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { isHookEnabled, readProjectSection, getProjectRoot } = require('./lib/adf-config-utils.cjs');

const JS_EXTENSIONS = new Set(['.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs', '.mts', '.cts']);
const ESLINT_CONFIGS = ['eslint.config.js', 'eslint.config.mjs', 'eslint.config.cjs', 'eslint.config.ts',
  '.eslintrc', '.eslintrc.js', '.eslintrc.cjs', '.eslintrc.json', '.eslintrc.yml', '.eslintrc.yaml'];
const MAX_OUTPUT = 4000;
const TIMEOUT_MS = 60000;

const exists = (root, rel) => fs.existsSync(path.join(root, rel));

/** Command for the project's linter, as [executable, ...args], or null when none applies. */
function linterFor(file, root) {
  const ext = path.extname(file).toLowerCase();
  if (JS_EXTENSIONS.has(ext)) {
    const biome = path.join(root, 'node_modules', '@biomejs', 'biome', 'bin', 'biome');
    if ((exists(root, 'biome.json') || exists(root, 'biome.jsonc')) && fs.existsSync(biome)) {
      return [process.execPath, biome, 'lint', file];
    }
    const eslint = path.join(root, 'node_modules', 'eslint', 'bin', 'eslint.js');
    if (ESLINT_CONFIGS.some((name) => exists(root, name)) && fs.existsSync(eslint)) {
      return [process.execPath, eslint, file];
    }
    return null;
  }
  if (ext === '.py') {
    let configured = exists(root, 'ruff.toml') || exists(root, '.ruff.toml');
    if (!configured) {
      try { configured = /^\[tool\.ruff/m.test(fs.readFileSync(path.join(root, 'pyproject.toml'), 'utf8')); } catch { /* none */ }
    }
    if (!configured) return null;
    const venv = path.join(root, '.venv', ...(process.platform === 'win32' ? ['Scripts', 'ruff.exe'] : ['bin', 'ruff']));
    return [fs.existsSync(venv) ? venv : 'ruff', 'check', '--quiet', file];
  }
  return null;
}

function main() {
  if (!isHookEnabled('lint-on-edit')) return 0;
  const stdin = fs.readFileSync(0, 'utf8').trim();
  if (!stdin) return 0;
  const payload = JSON.parse(stdin);
  const cwd = payload.cwd || process.cwd();
  if (readProjectSection(cwd, 'lintOnEdit').enabled !== true) return 0;

  const file = payload.tool_input?.file_path;
  if (!file || !fs.existsSync(path.resolve(cwd, file))) return 0;
  const root = getProjectRoot(cwd);
  const command = linterFor(path.resolve(cwd, file), root);
  if (!command) return 0;

  const [exe, ...args] = command;
  const result = spawnSync(exe, args, { cwd: root, encoding: 'utf8', timeout: TIMEOUT_MS });
  if (result.error || result.status !== 1) return 0; // missing, timed out, clean, or a config error
  const output = `${result.stdout || ''}${result.stderr || ''}`.trim();
  if (!output) return 0;

  const rel = path.relative(root, path.resolve(cwd, file));
  const tool = path.basename(args[0] === 'check' ? exe : args[0]).replace(/\.js$/, '');
  const body = output.length > MAX_OUTPUT ? `${output.slice(0, MAX_OUTPUT)}\n… (truncated)` : output;
  process.stderr.write(`${tool} reported problems in ${rel} after your last edit. Fix them unless they predate your change:\n${body}\n`);
  return 2;
}

let code = 0;
try {
  code = main();
} catch {
  code = 0; // fail-open
}
process.exit(code);
