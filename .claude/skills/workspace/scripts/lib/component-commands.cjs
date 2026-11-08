/**
 * component-commands.cjs - Run, build, test and lint commands of one component, and the
 * directories nobody should edit by hand.
 *
 * Everything comes from files in the component: the lockfile picks the package manager,
 * package.json scripts supply the command names (only the names listed here are ever used), and
 * the stack supplies the rest. A command that cannot be known is null.
 *
 * @module component-commands
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { parseGitmodules, classifySubmodule } = require('../../../../hooks/lib/repo-shape-detector.cjs');
const { safeText } = require('../../../../hooks/lib/system-map-validate.cjs');
const { readTextCapped } = require('../../../../hooks/lib/read-text-capped.cjs');
const { readPackage } = require('./component-stack.cjs');

const RUN_SCRIPTS = ['start:dev', 'dev', 'serve', 'start'];
const LOCKFILES = [['pnpm-lock.yaml', 'pnpm'], ['yarn.lock', 'yarn'], ['bun.lockb', 'bun'], ['bun.lock', 'bun']];
const GENERATED_DIRS = {
  nestjs: ['dist/'],
  vue: ['dist/'],
  'react-native': ['ios/Pods', 'android/build'],
  maven: ['target/'],
  foundry: ['out/', 'cache/'],
  python: ['.venv'],
};
const MAX_FILE_BYTES = 1024 * 1024;

const isFile = (dir, name) => { try { return fs.statSync(path.join(dir, name)).isFile(); } catch { return false; } };

const readText = (dir, name) => readTextCapped(path.join(dir, name), MAX_FILE_BYTES);

/** Names of the scripts in package.json, as a Set, or null when there is no readable package.json. */
function scriptNames(dir) {
  const pkg = readPackage(dir);
  if (!pkg) return null;
  const scripts = typeof pkg.scripts === 'object' && pkg.scripts ? pkg.scripts : {};
  return new Set(Object.keys(scripts).filter((k) => typeof scripts[k] === 'string'));
}

/** Submodule paths classified vendored by the repo-shape rules, as safe `dir/` entries. */
function vendoredSubmodules(dir, orgs) {
  const text = readText(dir, '.gitmodules');
  if (text === null) return [];
  return parseGitmodules(text)
    .filter((sub) => classifySubmodule(sub, orgs) === 'vendored')
    .map((sub) => String(sub.path).replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/+$/, ''))
    .filter((p) => safeText(p) && p.split('/').every((s) => s !== '' && s !== '.' && s !== '..'))
    .map((p) => `${p}/`);
}

function nodeCommands(dir) {
  const scripts = scriptNames(dir);
  if (!scripts) return { run: null, test: null, lint: null };
  const pm = (LOCKFILES.find(([file]) => isFile(dir, file)) || [null, 'npm'])[1];
  const script = (name) => (scripts.has(name) ? `${pm} run ${name}` : null);
  return { run: script(RUN_SCRIPTS.find((name) => scripts.has(name))), test: script('test'), lint: script('lint') };
}

/**
 * @param {string} dir Component directory
 * @param {string} stack A stack from component-stack.cjs, or any other label (treated like unknown)
 * @param {{ orgs?: string[] }} [opts] Trusted owners, so vendored submodules can be told from sibling ones
 * @returns {{ run: string|null, build: string|null, test: string|null, lint: string|null, generatedDirs: string[], vendoredDirs: string[] }}
 */
function commandsFor(dir, stack, { orgs } = {}) {
  let commands = { run: null, build: null, test: null, lint: null };
  const vendored = [];
  if (stack === 'maven') commands.test = 'mvn test';
  else if (stack === 'foundry') {
    commands = { run: null, build: 'forge build', test: 'forge test', lint: null };
    vendored.push('lib/');
  } else if (stack === 'python') commands.test = isFile(dir, 'uv.lock') ? 'uv run pytest' : 'pytest';
  else commands = { ...commands, ...nodeCommands(dir) };

  const vendoredDirs = [...new Set([...vendored, ...vendoredSubmodules(dir, orgs)])];
  return { ...commands, generatedDirs: GENERATED_DIRS[stack] || [], vendoredDirs };
}

module.exports = { commandsFor };
