'use strict';

/**
 * Splits a shell command into the git and gh invocations it runs, for the git workflow hooks.
 * Handles `&&`/`;`/`|` chains, `cd <dir>`/`pushd <dir>` before a command, env prefixes (`FOO=1 git push`),
 * `git -C <dir>`, `--git-dir` and `-c key=value`, and reads `git push` refspecs (`HEAD:main`, `+main`,
 * `:branch`, `--delete`, `--force-with-lease`, `--tags`).
 */

const os = require('node:os');
const path = require('node:path');
const { shellWords } = require('./commit-message-parser.cjs');

const GIT_VALUE_OPTIONS = new Set(['-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path']);
const PUSH_VALUE_OPTIONS = new Set(['--repo', '--receive-pack', '--exec', '-o', '--push-option']);
const ENV = /^[A-Za-z_][A-Za-z0-9_]*=/;

/**
 * The command with heredoc bodies removed (they are data, not commands) and every newline outside
 * quotes turned into ";", so each line is its own command.
 */
function flattenLines(command) {
  const withoutHeredocs = command.replace(/<<-?[ \t]*(['"]?)([A-Za-z_]\w*)\1[^\n]*\n[\s\S]*?\n[ \t]*\2[ \t]*(?=\n|$)/g, '');
  let out = '';
  let quote = null;
  for (let i = 0; i < withoutHeredocs.length; i++) {
    const ch = withoutHeredocs[i];
    if (quote) {
      if (ch === '\\' && quote === '"') { out += ch + (withoutHeredocs[++i] ?? ''); continue; }
      if (ch === quote) quote = null;
    } else if (ch === '\\' && withoutHeredocs[i + 1] === '\n') { i++; out += ' '; continue; }
    else if (ch === "'" || ch === '"') quote = ch;
    else if (ch === '\n') { out += ';'; continue; }
    out += ch;
  }
  return out;
}

/**
 * Directory after `cd <target>`. `~`, `$HOME` and `$PWD` are expanded; a target that depends on
 * something only the shell knows (`$(...)`, another variable, `cd -`) leaves the directory as it was.
 */
function cdTarget(dir, target) {
  const expanded = target
    .replace(/^~(?=\/|$)/, os.homedir())
    .replace(/^\$\{?HOME\}?(?=\/|$)/, os.homedir())
    .replace(/^\$\{?PWD\}?(?=\/|$)/, dir);
  if (/[$`]/.test(expanded) || expanded === '-' || expanded.startsWith('~')) return dir;
  return path.resolve(dir, expanded);
}

/**
 * @returns {Array<{tool: 'git'|'gh', cwd: string, sub: string|null, args: string[]}>}
 */
function parseCommands(command, cwd) {
  const segments = [[]];
  for (const word of shellWords(flattenLines(command))) {
    if (';&|'.includes(word)) segments.push([]); else segments[segments.length - 1].push(word);
  }
  const out = [];
  let dir = cwd;
  for (const raw of segments) {
    // Subshell and group parentheses are not part of the words: "(cd x && git push -f origin main)"
    const words = raw.map((w) => w.replace(/^\(+/, '').replace(/\)+$/, '')).filter(Boolean);
    while (words.length && ENV.test(words[0])) words.shift();
    if ((words[0] === 'cd' || words[0] === 'pushd') && words[1]) { dir = cdTarget(dir, words[1]); continue; }
    if (words[0] === 'git') {
      let here = dir;
      let gitDir = null;
      let i = 1;
      for (; i < words.length && words[i].startsWith('-'); i++) {
        const [name, inline] = words[i].split(/=(.*)/s);
        if (words[i] === '-C') here = path.resolve(here, words[++i] || '.');
        else if (name === '--git-dir') gitDir = inline ?? words[++i];
        else if (GIT_VALUE_OPTIONS.has(words[i])) i++;
      }
      // `--work-tree` does not pick the repository (git still finds it from the current directory);
      // `--git-dir` does, and a `.git` directory is read as the repository in its parent
      if (gitDir && path.basename(gitDir) === '.git') here = path.resolve(here, path.dirname(gitDir));
      out.push({ tool: 'git', cwd: here, sub: words[i] || null, args: words.slice(i + 1) });
    } else if (words[0] === 'gh') {
      out.push({ tool: 'gh', cwd: dir, sub: words.slice(1, 3).join(' '), args: words.slice(3) });
    }
  }
  return out;
}

const stripHeads = (ref) => ref.replace(/^refs\/heads\//, '');

/**
 * What a `git push` does.
 * @returns {{remote: string|null, force: boolean, deletes: boolean, tags: boolean, all: boolean,
 *   updates: Array<{src: string|null, dst: string|null, force: boolean, delete: boolean, tag: boolean}>}}
 *   dst null means "the current branch's upstream"; src or dst 'HEAD' means the current branch
 */
function parsePush(args) {
  const result = { remote: null, force: false, deletes: false, tags: false, all: false, updates: [] };
  const operands = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--') { operands.push(...args.slice(i + 1)); break; }
    if (PUSH_VALUE_OPTIONS.has(a)) { i++; continue; }
    if (/^--force(?:-with-lease|-if-includes)?(?:=.*)?$/.test(a) || /^-[a-zA-Z]*f[a-zA-Z]*$/.test(a) && !a.startsWith('--')) result.force = true;
    if (a === '--delete' || (/^-[a-zA-Z]*d[a-zA-Z]*$/.test(a) && !a.startsWith('--'))) result.deletes = true;
    if (a === '--tags' || a === '--follow-tags') result.tags = true;
    if (a === '--all' || a === '--mirror' || a === '--branches') result.all = true;
    if (!a.startsWith('-')) operands.push(a);
  }
  result.remote = operands[0] || null;
  for (const spec of operands.slice(1)) {
    const force = spec.startsWith('+');
    const body = force ? spec.slice(1) : spec;
    const colon = body.indexOf(':');
    const src = colon === -1 ? body : body.slice(0, colon) || null;
    const dst = colon === -1 ? body : body.slice(colon + 1);
    const tag = /^refs\/tags\//.test(dst);
    const current = (ref) => (ref === '@' || ref === 'HEAD' ? 'HEAD' : ref);
    const del = result.deletes || src === null;
    result.updates.push({ src: del ? null : current(src), dst: tag ? dst : current(stripHeads(dst)), force: force || result.force, delete: del, tag });
  }
  if (result.updates.length === 0) result.updates.push({ src: 'HEAD', dst: null, force: result.force, delete: false, tag: false });
  return result;
}

/** Values of `--name value`, `--name=value` and `-x value` options. */
function optionValue(args, long, short) {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === long || (short && args[i] === short)) return args[i + 1] ?? null;
    if (args[i].startsWith(`${long}=`)) return args[i].slice(long.length + 1);
  }
  return null;
}

const hasFlag = (args, ...names) => args.some((a) => names.includes(a));

/** First operand that is not an option or an option's value. */
function firstOperand(args, valueOptions = new Set()) {
  for (let i = 0; i < args.length; i++) {
    if (valueOptions.has(args[i])) { i++; continue; }
    if (!args[i].startsWith('-')) return args[i];
  }
  return null;
}

// `git add` operands that stage the whole tree
const BULK_ADD = new Set(['-A', '--all', '--no-ignore-removal', '.', ':/', '*']);

/** True when `git add` with these args stages everything. */
const isBulkAdd = (args) => args.some((a) => BULK_ADD.has(a));

/** The git workflow reason for a bulk add, used by git-flow-guard and by commit-guard. */
const bulkAddReason = (args) =>
  `"git add ${args.join(' ')}" stages everything, which can sweep in secrets, local config and unrelated work. Stage the files by name (git add <path> ...).`;

module.exports = { flattenLines, parseCommands, parsePush, optionValue, hasFlag, firstOperand, isBulkAdd, bulkAddReason };
