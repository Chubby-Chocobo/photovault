#!/usr/bin/env node
/**
 * privacy-checker.cjs - Privacy pattern matching logic for sensitive file detection
 *
 * Extracted from privacy-block.cjs for reuse in Claude hooks.
 * Pure logic module - no stdin/stdout, no exit codes.
 *
 * @module privacy-checker
 */

const path = require('path');
const fs = require('fs');
const { shellWords } = require('./commit-message-parser.cjs');

// ═══════════════════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════

// Shell characters that separate words and path operands in a command (quotes, `=`, `:`, `$`, brackets,
// redirections, separators). Splitting there keeps `FILE=.env`, `$(cat a/.env)` and `$HOME/.aws/credentials`
// apart, and leaves `process.env.X` as one token that no secret-file pattern matches.
const COMMAND_TOKEN_SEPARATORS = /[\s"'`=:(){}<>;|&,$]+/;

// Safe file patterns - exempt from privacy checks (documentation/template files)
const SAFE_PATTERNS = [
  /\.example$/i,   // .env.example, config.example
  /\.sample$/i,    // .env.sample
  /\.template$/i,  // .env.template
];

// Privacy-sensitive patterns
const PRIVACY_PATTERNS = [
  /^\.env$/,              // .env
  /^\.env\./,             // .env.local, .env.production, etc.
  /(^|[/:])\.env$/,        // path/to/.env, APPROVED:.env (not process.env or import.meta.env)
  /\/\.env\./,            // path/to/.env.local
  /^\.?credentials(\.(json|ya?ml|txt|csv|ini|toml|xml|cfg|conf|env))?$/i, // credentials, credentials.json, .credentials.json
  /[._-]credentials\.(json|ya?ml)$/i, // gcp-credentials.json, service_credentials.yaml
  /(^|\/)\.(ssh|aws)(\/|$)/,       // ~/.ssh and ~/.aws hold keys and cloud credentials
  /secrets?\.ya?ml$/i,    // secrets.yaml, secret.yml
  /[^/]\.pem$/,           // Private keys (a bare `.pem` word has no stem)
  /[^/]\.key$/,           // Private keys (a bare `.key` is a jq path, not a file)
  /^id_(rsa|ed25519)(?!.*\.pub$)/, // SSH private keys (not the .pub half)
  /(^|\/)\.mcp\.json$/,  // MCP server config (often holds API keys)
  /(^|\/)\.git-credentials$/, // git credential store: one credential URL per entry
  /(^|\/)\.netrc$/,     // FTP/HTTP logins, read by curl and git
];

// Editing these changes what the agent may do without asking (permissions, hooks). Reading them stays free,
// so the pattern applies to tools that write or run commands only.
const SETTINGS_PATTERN = /(^|\/)\.claude\/settings(\.local)?\.json$/;
const SETTINGS_WRITE_TOOLS = new Set(['Edit', 'MultiEdit', 'Write']);
// Shell commands (and git subcommands) that only read the files they name; naming a settings file in one changes nothing
const READ_ONLY_COMMANDS = new Set(['cat', 'less', 'more', 'head', 'tail', 'bat', 'jq', 'ls', 'stat', 'wc', 'file', 'diff',
  'grep', 'egrep', 'fgrep', 'rg', 'md5', 'md5sum', 'shasum', 'sha256sum']);
const GIT_READ_SUBCOMMANDS = new Set(['diff', 'show', 'log', 'status', 'blame', 'cat-file', 'ls-files', 'grep', 'add',
  'update-index', 'hash-object']);

// ═══════════════════════════════════════════════════════════════════════════
// HELPER FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Check if path is a safe file (example/sample/template)
 * @param {string} testPath - Path to check
 * @returns {boolean} true if file matches safe patterns
 */
function isSafeFile(testPath) {
  if (!testPath) return false;
  const basename = path.basename(testPath);
  return SAFE_PATTERNS.some(p => p.test(basename));
}

/**
 * Check if path matches privacy patterns
 * @param {string} testPath - Path to check
 * @param {boolean} [includeSettings] - Also treat .claude/settings(.local).json as sensitive (write and shell tools)
 * @returns {boolean} true if path matches privacy-sensitive patterns
 */
function isPrivacySensitive(testPath, includeSettings = false) {
  if (!testPath) return false;

  let normalized = testPath.replace(/\\/g, '/');

  // Decode URI components to catch obfuscated paths (%2e = '.')
  try {
    normalized = decodeURIComponent(normalized);
  } catch (e) {
    // Invalid encoding, use as-is
  }

  // Check safe patterns first - exempt example/sample/template files
  if (isSafeFile(normalized)) {
    return false;
  }

  const basename = path.basename(normalized);

  if (includeSettings && SETTINGS_PATTERN.test(normalized.toLowerCase())) return true;

  // Case-insensitive: macOS and Windows file systems treat .ENV as .env
  for (const pattern of PRIVACY_PATTERNS) {
    const ci = new RegExp(pattern.source, pattern.flags.includes('i') ? pattern.flags : pattern.flags + 'i');
    if (ci.test(basename) || ci.test(normalized)) {
      return true;
    }
  }
  return false;
}

// File names a glob word could expand to; used to catch `.e*`, `.en[v]`, `cred*` and similar spellings
const SECRET_NAME_SAMPLES = ['.env', '.env.local', '.env.production', '.mcp.json', 'credentials', 'credentials.json',
  '.credentials.json', 'id_rsa', 'id_ed25519', 'secrets.yml', 'secrets.yaml', 'server.pem', 'server.key',
  '.git-credentials', '.netrc'];

/** True when a glob word (`.e*`, `.en[v]`) could name a secret file. Globs that start with a wildcard are left alone. */
function globCouldNameSecret(word) {
  const segment = word.replace(/\\/g, '/').split('/').pop();
  if (!/[*?[]/.test(segment) || /^[*?[]/.test(segment)) return false;
  let source = '';
  for (let i = 0; i < segment.length; i++) {
    const ch = segment[i];
    if (ch === '*') source += '.*';
    else if (ch === '?') source += '.';
    else if (ch === '[' || ch === ']') source += ch;
    else source += ch.replace(/[.+^${}()|\\]/g, '\\$&');
  }
  try {
    const re = new RegExp(`^${source}$`, 'i');
    return SECRET_NAME_SAMPLES.some((name) => re.test(name));
  } catch { return false; }
}

/** True when a shell command could change a `.claude/settings(.local).json`: a segment that is not a plain read names one. */
function commandMayWriteSettings(command) {
  for (const segment of String(command || '').split(/[;|&\n]+/)) {
    const words = shellWords(segment.replace(/\\/g, '/'));
    let i = 0;
    while (i < words.length && (/^\w+=/.test(words[i]) || WRAPPER_COMMANDS.has(words[i]))) i++;
    const name = (words[i] || '').split('/').pop().toLowerCase();
    let readOnly = READ_ONLY_COMMANDS.has(name);
    if (name === 'git') {
      let sub = '';
      for (let j = i + 1; j < words.length; j++) {
        if (words[j] === '-C' || words[j] === '-c') { j++; continue; }
        if (!words[j].startsWith('-')) { sub = words[j]; break; }
      }
      readOnly = GIT_READ_SUBCOMMANDS.has(sub);
    }
    if (readOnly && !segment.includes('>')) continue; // a redirection turns a read into a write
    const named = words.some((w) => w.split(COMMAND_TOKEN_SEPARATORS).some((piece) => SETTINGS_PATTERN.test(piece.toLowerCase())));
    if (named) return true;
  }
  return false;
}

/** Whether `.claude/settings(.local).json` counts as sensitive for this call: write tools always, Bash only when the command may change it. */
function settingsGuarded(toolName, toolInput) {
  if (SETTINGS_WRITE_TOOLS.has(toolName)) return true;
  return toolName === 'Bash' && commandMayWriteSettings(toolInput && toolInput.command);
}

/** The form of `value` that is sensitive (as written, without a trailing glob, or via a glob match), else null. */
function sensitiveForm(value, includeSettings = false) {
  const bare = String(value).replace(/[*?]+$/, '');
  if (isPrivacySensitive(value, includeSettings)) return value;
  if (bare && isPrivacySensitive(bare, includeSettings)) return bare;
  return globCouldNameSecret(value) ? value : null;
}

// Commands whose first operand is a search pattern or script, not a path
const PATTERN_FIRST_COMMANDS = new Set(['grep', 'egrep', 'fgrep', 'rg', 'ag', 'ack', 'jq', 'sed', 'awk', 'gawk']);
const WRAPPER_COMMANDS = new Set(['sudo', 'env', 'nice', 'nohup', 'time', 'timeout', 'command']);
// Flags that take a separate value (a number, type or glob), so the next word is not the pattern
const VALUE_FLAGS = new Set(['-A', '-B', '-C', '-m', '-t', '-T', '-g', '-j', '--include', '--exclude', '--exclude-dir', '--type', '--max-count']);
// Flags whose value is a pattern, for any command (`git log --grep credentials`, `grep -e x`)
const PATTERN_VALUE_FLAGS = new Set(['--grep', '--regexp', '-e', '--expression']);

/** Words of a shell command that can be paths: quotes removed, pattern operands of grep/rg/jq/sed/awk left out. */
function commandPathWords(command) {
  const out = [];
  // Backslashes become slashes first so Windows paths and `a\.env` survive quote removal
  for (const segment of String(command).split(/[;|&\n]+/)) {
    const words = shellWords(segment.replace(/\\/g, '/')).map((w) => w.replace(/^\(+/, ''));
    let i = 0;
    while (i < words.length && (/^\w+=/.test(words[i]) || WRAPPER_COMMANDS.has(words[i]))) {
      if (/^\w+=/.test(words[i])) out.push(words[i]); // FILE=.env cat $FILE
      i++;
    }
    const name = (words[i] || '').split('/').pop().toLowerCase();
    const patternCommand = PATTERN_FIRST_COMMANDS.has(name);
    const hasExplicitPattern = words.some((w) => w === '-e' || w === '--regexp' || w === '--expression' || w === '-f');
    let patternSkipped = !patternCommand || hasExplicitPattern;
    for (i += 1; i < words.length; i++) {
      const word = words[i];
      if (PATTERN_VALUE_FLAGS.has(word) || (patternCommand && VALUE_FLAGS.has(word))) { i++; continue; }
      if (word.startsWith('--grep=') || word.startsWith('--regexp=')) continue;
      if (!patternSkipped && !word.startsWith('-')) { patternSkipped = true; continue; }
      out.push(word);
    }
  }
  return out;
}

/**
 * Extract paths from tool input
 * @param {Object} toolInput - Tool input object with file_path, path, pattern, or command
 * @returns {Array<{value: string, field: string}>} Array of extracted paths with field names
 */
function extractPaths(toolInput, toolName) {
  const paths = [];
  if (!toolInput) return paths;
  const includeSettings = settingsGuarded(toolName, toolInput);

  if (toolInput.file_path) paths.push({ value: toolInput.file_path, field: 'file_path' });
  if (toolInput.path) paths.push({ value: toolInput.path, field: 'path' });
  // Grep's pattern is a search regex, not a path; Glob's pattern is a path glob
  if (toolInput.pattern && toolName !== 'Grep') paths.push({ value: toolInput.pattern, field: 'pattern' });
  // Grep's glob filter names the files to search, so it is a path
  if (toolInput.glob) paths.push({ value: toolInput.glob, field: 'glob' });

  // Bash: every word of the command is a candidate path; the sensitive ones are returned (`cat ~/.aws/credentials`, `FILE=.env`,
  // `cat .env*`). A trailing glob is dropped so `.env*` reads as `.env`. Words are split on shell
  // separators, so `process.env.X` stays one word that no secret-file pattern matches.
  if (toolInput.command) {
    for (const word of commandPathWords(toolInput.command)) {
      for (const piece of word.split(COMMAND_TOKEN_SEPARATORS)) {
        const hit = piece && sensitiveForm(piece, includeSettings);
        if (hit) paths.push({ value: hit, field: 'command' });
      }
    }
  }

  return paths.filter(p => p.value);
}

/** `Read(...)` globs from permissions.deny in the project's settings.json and settings.local.json. */
function readDenyGlobs(baseDir) {
  const globs = [];
  for (const name of ['settings.json', 'settings.local.json']) {
    try {
      const settings = JSON.parse(fs.readFileSync(path.join(baseDir, '.claude', name), 'utf8'));
      for (const rule of settings?.permissions?.deny || []) {
        const m = /^Read\((.+)\)$/.exec(String(rule));
        if (m) globs.push(m[1]);
      }
    } catch { /* missing or unreadable settings: no rules from this file */ }
  }
  return globs;
}

// gitignore-style glob (a name, *.pem, dir/*.key, a double-star prefix) as a RegExp over a project-relative path
function globToRegExp(glob) {
  const g = glob.replace(/^\.\//, '').replace(/^\//, '');
  // A pattern without a directory part matches that name at any depth
  const anywhere = !g.replace(/^\*\*\//, '').includes('/');
  let re = '';
  for (let i = 0; i < g.length; i++) {
    const ch = g[i];
    if (ch === '*' && g[i + 1] === '*') {
      i++;
      if (g[i + 1] === '/') { i++; re += '(?:.*/)?'; } else re += '.*';
    } else if (ch === '*') re += '[^/]*';
    else if (ch === '?') re += '[^/]';
    else re += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${anywhere && !re.startsWith('(?:.*/)?') ? '(?:.*/)?' : ''}${re}$`);
}

/**
 * True when a `Read(...)` rule in the project's permissions.deny already covers this path:
 * Claude Code refuses those reads itself, so asking the user first would be a prompt whose
 * approval cannot take effect. The rules are those Claude Code loaded: the launch project's
 * settings files, found from `cwd` via the project root (not the hook's cwd, which follows `cd`
 * into subdirectories whose own `.claude/settings.json` is not in effect). A project that removes
 * or narrows them gets the ask back. Rules only match inside the project, so paths outside it
 * (parent dirs, --add-dir folders, `~`) still get asked.
 * @param {string} testPath - Path to check, relative to `cwd` when not absolute
 * @param {string} [cwd] - Directory the hook runs in (hook input `cwd`)
 * @returns {boolean}
 */
function isReadDeniedBySettings(testPath, cwd = process.cwd()) {
  const normalized = String(testPath).replace(/\\/g, '/');
  if (normalized.startsWith('~')) return false; // unexpanded home path: outside the deny rules' reach
  const root = require('./adf-config-utils.cjs').getProjectRoot(cwd);
  const relative = path.relative(root, path.resolve(cwd, normalized)).split(path.sep).join('/');
  if (relative.startsWith('..') || path.isAbsolute(relative)) return false;
  return readDenyGlobs(root).some((glob) => globToRegExp(glob).test(relative));
}

/**
 * Load adf-config.json config to check if privacy block is disabled
 * @param {string} [configDir] - Directory containing adf-config.json (defaults to .claude/config in the project root)
 * @returns {boolean} true if privacy block should be skipped
 */
function isPrivacyBlockDisabled(configDir) {
  try {
    const configPath = configDir
      ? path.join(configDir, 'adf-config.json')
      : path.join(require('./adf-config-utils.cjs').getProjectRoot(), '.claude', 'config', 'adf-config.json');
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    return config.privacyBlock === false;
  } catch {
    return false; // Default to enabled on error (file not found or invalid JSON)
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MAIN ENTRY POINT
// ═══════════════════════════════════════════════════════════════════════════

/**
 * Check if a tool call accesses privacy-sensitive files
 *
 * @param {Object} params
 * @param {string} params.toolName - Name of tool (Read, Write, Bash, etc.)
 * @param {Object} params.toolInput - Tool input with file_path, path, command, etc.
 * @param {Object} [params.options]
 * @param {boolean} [params.options.disabled] - Skip checks if true
 * @param {string} [params.options.configDir] - Directory for adf-config.json config
 * @param {string} [params.options.cwd] - Session working directory (hook input `cwd`)
 * @returns {{ sensitive: boolean, filePath?: string, reason?: string }}
 */
function checkPrivacy({ toolName, toolInput, options = {} }) {
  const { disabled, configDir, cwd } = options;

  // Check if disabled via options or config
  if (disabled || isPrivacyBlockDisabled(configDir)) {
    return { sensitive: false };
  }

  const includeSettings = settingsGuarded(toolName, toolInput);
  for (const { value: found } of extractPaths(toolInput, toolName)) {
    const testPath = sensitiveForm(found, includeSettings);
    if (!testPath) continue;
    if (toolName === 'Read' && isReadDeniedBySettings(testPath, cwd)) continue;
    const settingsOnly = includeSettings && !isPrivacySensitive(testPath) && SETTINGS_PATTERN.test(testPath.replace(/\\/g, '/').toLowerCase());
    return {
      sensitive: true,
      filePath: testPath,
      reason: settingsOnly
        ? `${path.basename(testPath)} sets this project's permissions and hooks. Approve only if you want it changed.`
        : `${path.basename(testPath)} may contain secrets (API keys, tokens, passwords). Approve only if Claude needs its contents.`
    };
  }

  return { sensitive: false };
}

// ═══════════════════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════════════════

module.exports = {
  // Main entry point
  checkPrivacy,

  // Helper functions (for testing and direct use)
  isSafeFile,
  isPrivacySensitive,
  extractPaths,
  isReadDeniedBySettings,
  isPrivacyBlockDisabled,

  // Constants
  SAFE_PATTERNS,
  PRIVACY_PATTERNS
};
