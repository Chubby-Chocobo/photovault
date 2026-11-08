'use strict';

/**
 * Credential redaction for tool output: credentials embedded in URLs (`https://<token>@host/...`)
 * and auth lines of .npmrc, .netrc and .pypirc. Pure string logic, no file access.
 *
 * CREDENTIAL_URL_SOURCE is the single definition of "a credential in a URL". The commit scanner
 * uses it too, and the quality-gates gitleaks rule carries the same text (a test keeps them equal).
 * It must stay RE2-compatible for gitleaks: no lookaround, no backreferences.
 */

const { shellWords } = require('./commit-message-parser.cjs');
const { flattenLines, parseCommands } = require('./git-command-parser.cjs');

const MASK = '***';

// Group 1 is the scheme, group 2 the userinfo. A userinfo that starts with `$`, `<` or `{` is a
// placeholder (`${TOKEN}`, `<user>`), and so is a password that starts with one of them.
const TOKEN_PREFIX = '(?:ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|glpat-|glcbt-|gldt-|glrt-|xox)';
const CREDENTIAL_URL_SOURCE = [
  '((?:git\\+)?https?://)',
  '(',
  '[A-Za-z0-9_.~%+-]+:[^\\s/"\'@:$<{][^\\s/"\']*', // user:password with a non-empty password
  `|${TOKEN_PREFIX}[A-Za-z0-9_-]+`, // known token prefix used as the whole userinfo
  '|[A-Za-z0-9_-]{20,}', // long bare token
  ')@',
].join('');

/** Global: use with String.replace. Use `new RegExp(CREDENTIAL_URL_SOURCE)` for a stateless test. */
const CREDENTIAL_URL = new RegExp(CREDENTIAL_URL_SOURCE, 'g');

// npm `_authToken=`/`_auth=`/`_password=`, netrc `password <x>` and pypirc `password = <x>`: group 1 is kept, group 2 masked
const CONFIG_SECRET_LINE = /((?:_auth(?:Token)?|_password)\s*=\s*|\bpassword(?:\s*[:=]\s*|\s+))(\S+)/gi;

// Files whose content or name makes a Bash command worth inspecting
const REDACT_BASENAMES = new Set([
  'Cargo.toml', 'Cargo.lock', 'package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'pom.xml',
  'build.gradle', 'build.gradle.kts', 'go.mod', 'requirements.txt', 'pyproject.toml', 'composer.json', 'Gemfile',
  '.gitmodules', '.git-credentials', '.npmrc', '.netrc', '.pypirc',
]);
const CONFIG_BASENAMES = new Set(['.npmrc', '.netrc', '.pypirc']);
const GIT_CONFIG_PATH = /(^|\/)\.git\/(config|modules\/.+\/config)$/;
const GIT_SUBCOMMANDS = new Set(['remote', 'config', 'submodule', 'ls-remote']);

const isPlaceholder = (value) => /^[$<{]/.test(value) || value.startsWith(MASK);
const basename = (p) => p.replace(/\\/g, '/').split('/').pop();

/**
 * Replaces credentials in a string with `***`, keeping the scheme and host of URLs.
 * @param {string} text
 * @param {{ configLines?: boolean }} [opts] configLines: also mask npmrc/netrc/pypirc auth lines
 * @returns {{ text: string, count: number }}
 */
function redactText(text, { configLines = false } = {}) {
  if (typeof text !== 'string' || text.length === 0) return { text, count: 0 };
  let count = 0;
  let out = text;
  if (out.includes('://')) {
    out = out.replace(CREDENTIAL_URL, (_match, scheme) => {
      count += 1;
      return `${scheme}${MASK}@`;
    });
  }
  if (configLines) {
    out = out.replace(CONFIG_SECRET_LINE, (match, lead, value) => {
      if (isPlaceholder(value)) return match;
      count += 1;
      return `${lead}${MASK}`;
    });
  }
  return { text: out, count };
}

/**
 * Redacts every string leaf of a JSON value. Keys, array lengths and non-string values are kept,
 * so the result has the same shape as the input. The input is not modified.
 * @param {unknown} value
 * @param {{ configLines?: boolean }} [opts]
 * @returns {{ value: unknown, count: number }}
 */
function redactLeaves(value, opts) {
  let count = 0;
  const walk = (node) => {
    if (typeof node === 'string') {
      const result = redactText(node, opts);
      count += result.count;
      return result.text;
    }
    if (Array.isArray(node)) return node.map(walk);
    // fromEntries defines own properties, so a `__proto__` key survives as data
    if (node && typeof node === 'object') return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, walk(v)]));
    return node;
  };
  const redacted = walk(value);
  return { value: redacted, count };
}

/** Total length of all string leaves of a JSON value. */
function stringLength(value) {
  if (typeof value === 'string') return value.length;
  if (Array.isArray(value)) return value.reduce((sum, item) => sum + stringLength(item), 0);
  if (value && typeof value === 'object') return Object.values(value).reduce((sum, item) => sum + stringLength(item), 0);
  return 0;
}

// Words of a command that can name a file: quotes removed, separators dropped, `a=b`, `<f` and `rev:path` split
function commandPieces(command) {
  return shellWords(flattenLines(command))
    .filter((word) => !';&|'.includes(word))
    .flatMap((word) => word.replace(/^\(+|\)+$/g, '').split(/[=<>:]/))
    .filter(Boolean);
}

/**
 * True when a shell command reads a manifest, lockfile, git config or credential file, or runs a
 * git subcommand that prints remote URLs (`git remote`, `git config`, `git submodule`, `git ls-remote`).
 * @param {string} command
 * @param {string} [cwd] directory the command runs in
 */
function bashNamesRedactTarget(command, cwd) {
  if (typeof command !== 'string' || command === '') return false;
  const named = commandPieces(command).some((piece) => REDACT_BASENAMES.has(basename(piece)) || GIT_CONFIG_PATH.test(piece.replace(/\\/g, '/')));
  if (named) return true;
  return parseCommands(command, cwd || process.cwd()).some((cmd) => cmd.tool === 'git' && GIT_SUBCOMMANDS.has(cmd.sub));
}

/** True when the tool input names an .npmrc, .netrc or .pypirc (file_path, path, glob or a word of the command). */
function namesConfigFile(toolInput) {
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {};
  const candidates = [input.file_path, input.path, input.glob];
  if (typeof input.command === 'string') candidates.push(...commandPieces(input.command));
  return candidates.some((candidate) => typeof candidate === 'string' && CONFIG_BASENAMES.has(basename(candidate)));
}

/**
 * Whether a tool call's output is worth scanning. Bash is narrowed to commands that name a
 * redact-worthy file or git subcommand; other tools are always scanned (the content decides).
 * @param {string} toolName
 * @param {object} toolInput
 * @param {string} [cwd]
 */
function shouldInspect(toolName, toolInput, cwd) {
  if (toolName !== 'Bash') return true;
  return bashNamesRedactTarget(toolInput && toolInput.command, cwd);
}

module.exports = {
  CREDENTIAL_URL_SOURCE,
  CREDENTIAL_URL,
  CONFIG_SECRET_LINE,
  REDACT_BASENAMES,
  redactText,
  redactLeaves,
  stringLength,
  bashNamesRedactTarget,
  namesConfigFile,
  shouldInspect,
};
