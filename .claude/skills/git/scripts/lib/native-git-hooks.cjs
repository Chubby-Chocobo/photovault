'use strict';

// Opt-in native git hooks, installed by a person with `git-flow.cjs install-git-hooks`, so pushes and
// commits made outside Claude Code (by people, Codex, Antigravity) follow the same rules:
//   pre-push    no force push or delete of a protected branch, no hand-made release tag, check-push
//               for a direct push to the main branch (native-pre-push-check.cjs)
//   pre-commit  no staged secrets (native-pre-commit.cjs)
// A hook file is written only into a hooks dir under the repository's git common dir. Any other hooks
// dir (husky, .githooks, a global core.hooksPath) belongs to a team or to every repo of a machine, so
// nothing is written there: the command prints the line to add as the first command of its own hook.
// A foreign hook is never overwritten; with --chain it is kept and run first.

const fs = require('fs');
const path = require('path');
const { git } = require('./git-exec.cjs');

const HOOK_NAMES = ['pre-commit', 'pre-push'];
const SCRIPT_DIR = '.claude/skills/git/scripts';
const SCRIPTS = { 'pre-commit': 'native-pre-commit.cjs', 'pre-push': 'git-flow.cjs' };

const marker = (hook) => `# adf-git-flow ${hook}`;
const chainedName = (hook) => `${hook}.adf-chained`;
const blockStart = (hook) => `# >>> adf-git-flow ${hook} (git-flow.cjs install-git-hooks)`;
const blockEnd = (hook) => `# <<< adf-git-flow ${hook}`;
const hasMarker = (content, hook) => content.split('\n').some((l) => l.startsWith(marker(hook)));

/** Exists as any directory entry, a dangling symlink included (fs.existsSync follows it and says no). */
function entryExists(file) {
  try { fs.lstatSync(file); return true; } catch { return false; }
}

function readIfFile(file) {
  try { return fs.statSync(file).isFile() ? fs.readFileSync(file, 'utf8') : null; } catch { return null; }
}

function gitPath(cwd, ...args) {
  return path.resolve(cwd, git(['rev-parse', ...args], { cwd }));
}

const hooksDir = (cwd) => gitPath(cwd, '--git-path', 'hooks');

/** realpath of the nearest existing ancestor plus the rest, so a hooks dir that is not created yet still resolves. */
function realpathLoose(target) {
  const rest = [];
  let current = path.resolve(target);
  for (;;) {
    try { return path.join(fs.realpathSync(current), ...rest.reverse()); } catch { /* go up */ }
    const parent = path.dirname(current);
    if (parent === current) return path.resolve(target);
    rest.push(path.basename(current));
    current = parent;
  }
}

function isUnder(child, parent) {
  return child === parent || child.startsWith(parent + path.sep);
}

/** The project's .husky folder when git's hooks path is husky's generated .husky/_, else null. */
function huskyDir(dir) {
  return path.basename(dir) === '_' && path.basename(path.dirname(dir)) === '.husky' ? path.dirname(dir) : null;
}

function hookScript(hook) {
  const header = `#!/bin/sh
${marker(hook)}: written by git-flow.cjs install-git-hooks; remove with install-git-hooks --uninstall
`;
  if (hook === 'pre-push') {
    return `${header}input=$(cat)
dir=$(dirname "$0")
if [ -x "$dir/${chainedName(hook)}" ]; then
  printf '%s\\n' "$input" | "$dir/${chainedName(hook)}" "$@" || exit $?
fi
script="$(git rev-parse --show-toplevel)/${SCRIPT_DIR}/${SCRIPTS[hook]}"
[ -f "$script" ] || exit 0
printf '%s\\n' "$input" | node "$script" pre-push "$@"
`;
  }
  // git passes no stdin to pre-commit. A tree without the script (an older ADF) passes.
  return `${header}dir=$(dirname "$0")
if [ -x "$dir/${chainedName(hook)}" ]; then
  "$dir/${chainedName(hook)}" "$@" || exit $?
fi
script="$(git rev-parse --show-toplevel)/${SCRIPT_DIR}/${SCRIPTS[hook]}"
[ -f "$script" ] || exit 0
command -v node >/dev/null 2>&1 || { echo "ADF pre-commit: node not found; secret scan skipped" >&2; exit 0; }
exec node "$script"
`;
}

/** Where a team adds the printed line: husky's tracked hook, else the hook file in git's hooks dir. */
const hookTarget = (dir, hook) => path.join(huskyDir(dir) || dir, hook);

/** The line to add as the first command of a team's own hook file. It never execs and exits only on a refusal. */
function printedLine(hook) {
  const args = hook === 'pre-push' ? ' pre-push "$@"' : '';
  return `s="$(git rev-parse --show-toplevel)/${SCRIPT_DIR}/${SCRIPTS[hook]}"; if [ -f "$s" ] && command -v node >/dev/null 2>&1; then node "$s"${args} || exit 1; fi`;
}

/** Hooks that 1.2.x wrote into the project's own .husky/<hook> as a marked block. */
function huskyBlock(husky, hook) {
  if (!husky) return null;
  const file = path.join(husky, hook);
  const content = readIfFile(file);
  if (content === null) return null;
  const start = content.indexOf(blockStart(hook));
  const end = content.indexOf(blockEnd(hook));
  return start === -1 || end === -1 || end < start ? null : { file, content, start, end };
}

/**
 * ADF's hook is there: a file holding the marker in git's hooks dir, a 1.2.x husky block, or the printed
 * line a person added to their own hook file.
 */
function isInstalled(dir, hook) {
  const content = readIfFile(path.join(dir, hook));
  if (content !== null && hasMarker(content, hook)) return true;
  if (huskyBlock(huskyDir(dir), hook) !== null) return true;
  const own = readIfFile(hookTarget(dir, hook));
  // A whole, uncommented line: a commented-out copy does nothing
  return own !== null && own.split('\n').some((line) => line.trim() === printedLine(hook));
}

const label = (hook) => (hook === 'pre-push' ? 'push' : 'commit');

/**
 * Installs the hooks (both, or `only`). Every check runs for every hook before anything is written.
 * @param {string} cwd
 * @param {{ chain?: boolean, only?: string|null }} [opts]
 * @returns {{ dir: string, inside: boolean, hooks: Array<{ hook: string, file: string, state: 'written'|'already'|'printed', chained?: boolean, line?: string }> }}
 */
function installHooks(cwd, { chain = false, only = null } = {}) {
  const top = git(['rev-parse', '--show-toplevel'], { cwd });
  const dir = hooksDir(cwd);
  const inside = isUnder(realpathLoose(dir), realpathLoose(gitPath(cwd, '--git-common-dir')));
  const plan = (only ? [only] : HOOK_NAMES).map((hook) => {
    const file = path.join(dir, hook);
    if (isInstalled(dir, hook)) return { hook, file, state: 'already' };
    const script = path.join(top, SCRIPT_DIR, SCRIPTS[hook]);
    if (!fs.existsSync(script)) {
      throw new Error(`this repository has no ADF scripts (${path.join(SCRIPT_DIR, SCRIPTS[hook])} is missing), so the ${hook} hook would pass every ${label(hook)} unchecked; install ADF here or run git from a repo that has it`);
    }
    if (!inside) return { hook, file, state: 'printed', line: printedLine(hook) };
    const foreign = entryExists(file);
    if (foreign && !chain) throw new Error(`${file} already exists and is not ADF's; pass --chain to keep it and run it first`);
    if (foreign && entryExists(path.join(dir, chainedName(hook)))) throw new Error(`${path.join(dir, chainedName(hook))} already exists; resolve it by hand`);
    return { hook, file, state: 'written', chain: foreign };
  });

  for (const step of plan) {
    if (step.state !== 'written') continue;
    fs.mkdirSync(dir, { recursive: true });
    if (step.chain) fs.renameSync(step.file, path.join(dir, chainedName(step.hook)));
    // 'wx': never write through an entry that appeared since the checks (a symlink included)
    fs.writeFileSync(step.file, hookScript(step.hook), { mode: 0o755, flag: 'wx' });
    fs.chmodSync(step.file, 0o755);
  }
  return {
    dir,
    inside,
    hooks: plan.map(({ hook, file, state, line }) => ({ hook, file, state, line, chained: entryExists(path.join(dir, chainedName(hook))) })),
  };
}

/** A path relative to the repository when it is inside, else absolute. */
function shown(top, target) {
  const rel = path.relative(top, target);
  return rel && !rel.startsWith('..') && !path.isAbsolute(rel) ? rel : target;
}


/** Text and exit code for an installHooks() result. */
function installReport(result, top) {
  const lines = [];
  const printed = result.hooks.filter((h) => h.state === 'printed');
  for (const h of result.hooks) {
    if (h.state === 'written') lines.push(`installed ${h.file}${h.chained ? ' (runs the existing hook first)' : ''}`);
    else if (h.state === 'already') lines.push(`${h.hook}: already installed`);
  }
  if (printed.length) {
    lines.push(`not installed: git's hooks path (${shown(top, result.dir)}) is outside this repository's git directory, so nothing was written.`);
    lines.push("To run a check for everyone who clones the repository, add its line as the first command of the project's own hook file. A command before the pre-push line that reads stdin (for example git lfs pre-push) would leave ADF's check with no ref lines.");
    for (const h of printed) {
      lines.push(`  ${h.hook}, in ${shown(top, hookTarget(result.dir, h.hook))}:`);
      lines.push(`    ${h.line}`);
    }
  }
  return { text: lines.join('\n'), exit: printed.length ? 1 : 0 };
}

function removeBlock(found, hook) {
  const rest = found.content.slice(0, found.start) + found.content.slice(found.end + blockEnd(hook).length).replace(/^\n/, '');
  if (rest.replace(/^#!.*\n?/, '').trim() === '') fs.rmSync(found.file); else fs.writeFileSync(found.file, rest);
}

/**
 * Removes only content that holds ADF's marker, in git's hooks dir wherever it is: a hook file
 * (its chained hook is renamed back, which also undoes the 1.2.4 husky v8 state) and the 1.2.x husky
 * block. A file without the marker is never touched.
 * @returns {Array<{ hook: string, removed: boolean, file: string, restored?: boolean }>}
 */
function uninstallHooks(cwd, { only = null } = {}) {
  const dir = hooksDir(cwd);
  const husky = huskyDir(dir);
  return (only ? [only] : HOOK_NAMES).map((hook) => {
    const file = path.join(dir, hook);
    const content = readIfFile(file);
    if (content !== null && hasMarker(content, hook)) {
      fs.rmSync(file);
      const chained = path.join(dir, chainedName(hook));
      if (entryExists(chained)) fs.renameSync(chained, file);
      return { hook, removed: true, file, restored: entryExists(file) };
    }
    const block = huskyBlock(husky, hook);
    if (block) { removeBlock(block, hook); return { hook, removed: true, file: block.file }; }
    // ADF's hook file is gone but the project's own hook is still parked under the chained name
    const chained = path.join(dir, chainedName(hook));
    if (!entryExists(file) && entryExists(chained)) { fs.renameSync(chained, file); return { hook, removed: false, restored: true, file }; }
    return { hook, removed: false, file };
  });
}

function uninstallReport(results) {
  return results.map((r) => {
    if (r.removed) return `removed ${r.file}${r.restored ? ' (restored the hook it ran first)' : ''}`;
    if (r.restored) return `restored ${r.file} from ${chainedName(r.hook)} (ADF's hook was already gone)`;
    return `no ADF ${r.hook} hook installed`;
  }).join('\n');
}

module.exports = { HOOK_NAMES, hooksDir, hookScript, printedLine, installHooks, installReport, uninstallHooks, uninstallReport };
