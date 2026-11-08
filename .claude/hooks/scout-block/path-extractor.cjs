#!/usr/bin/env node
/**
 * path-extractor.cjs - Extract paths from Claude Code tool inputs
 *
 * Extracts file_path, path, pattern params and parses Bash commands
 * to find all path-like arguments.
 */

// Flags that indicate the following value should NOT be checked as a path
// These are "exclude" semantics - the user is explicitly skipping these paths
const EXCLUDE_FLAGS = [
  '--exclude', '--ignore', '--skip', '--prune',
  '-x',           // tar exclude shorthand
  '-path',        // find -path (used with -prune)
  '--exclude-dir' // grep --exclude-dir
];

// Commands whose purpose is to read, list or search files. Only these are checked:
// every other command (rm, npm, git, cp, mkdir, docker, ...) never triggers a block.
// Bare directory names (node_modules, ...) are treated as paths for these commands;
// other tokens must look like paths to be extracted.
const READ_COMMANDS = [
  'cat', 'head', 'tail', 'less', 'more', 'bat',
  'ls', 'tree', 'find', 'fd', 'du', 'wc',
  'grep', 'egrep', 'fgrep', 'rg', 'ag', 'sed', 'awk'
];

// Prefixes that wrap the real command: sudo cat x, env FOO=1 ls y
const COMMAND_WRAPPERS = ['sudo', 'env', 'nice', 'nohup', 'time', 'timeout'];

/**
 * Extract all paths from a tool_input object
 * Handles: file_path, path, pattern params and command strings
 *
 * @param {Object} toolInput - The tool_input from hook JSON
 * @param {string} [toolName] - Tool name; `pattern` is a path only for Glob (or unknown tools)
 * @returns {string[]} Array of extracted paths
 */
function extractFromToolInput(toolInput, toolName) {
  const isGlobTool = !toolName || toolName === 'Glob' || toolName === 'unknown';
  const paths = [];

  if (!toolInput || typeof toolInput !== 'object') {
    return paths;
  }

  // Direct path params (Read, Edit, Write, Grep, Glob tools)
  // Grep's `pattern` is a regex, not a path
  const directParams = isGlobTool ? ['file_path', 'path', 'pattern'] : ['file_path', 'path'];
  for (const param of directParams) {
    if (toolInput[param] && typeof toolInput[param] === 'string') {
      const normalized = normalizeExtractedPath(toolInput[param]);
      if (normalized) paths.push(normalized);
    }
  }

  // Extract from Bash command if present
  if (toolInput.command && typeof toolInput.command === 'string') {
    const cmdPaths = extractFromCommand(toolInput.command);
    paths.push(...cmdPaths);
  }

  return paths.filter(Boolean);
}

/**
 * Extract path-like segments from a Bash command string.
 *
 * Uses pipe-segment-aware command context: for filesystem commands (cd, cat, ls, rm, etc.)
 * bare blocked directory names are extracted with priority. For non-filesystem commands
 * (grep, echo, sed, etc.) only tokens that structurally look like paths are extracted,
 * preventing false positives on search terms and string arguments.
 *
 * @param {string} command - The command string
 * @returns {string[]} Array of extracted paths
 */
function extractFromCommand(command) {
  if (!command || typeof command !== 'string') {
    return [];
  }

  const paths = [];
  for (const segment of splitSegments(stripHeredocBodies(command))) {
    if (!isReadSegment(segment)) continue;
    paths.push(...extractFromSegment(segment));
  }
  return paths;
}

/**
 * Drop multi-line heredoc bodies so their content is never parsed as commands.
 *
 * @param {string} command
 * @returns {string}
 */
function stripHeredocBodies(command) {
  return command.replace(/<<-?\s*(["']?)(\w+)\1[^\n]*\n[\s\S]*?\n[ \t]*\2(?=\s|$)/g, ' ');
}

/**
 * Split a command on |, ||, &&, ; and $( / backtick substitutions outside single quotes.
 *
 * @param {string} command
 * @returns {string[]}
 */
function splitSegments(command) {
  const segments = [];
  let current = '';
  let quote = null;
  for (let i = 0; i < command.length; i++) {
    const ch = command[i];
    const startsSubstitution = ch === '`' || (ch === '$' && command[i + 1] === '(');
    if (quote) {
      if (ch === quote) quote = null;
      // $(...) and backticks still run inside double quotes
      if (quote === '"' && startsSubstitution) {
        segments.push(current);
        current = '';
        if (ch === '$') i++;
        continue;
      }
      current += ch;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
      current += ch;
    } else if (startsSubstitution) {
      segments.push(current);
      current = '';
      if (ch === '$') i++;
    } else if (ch === ';' || ch === '|' || (ch === '&' && command[i + 1] === '&')) {
      if (ch !== ';' && command[i + 1] === ch) i++;
      segments.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  segments.push(current);
  return segments.map(seg => seg.trim()).filter(Boolean);
}

/**
 * Name of the command a segment runs, skipping VAR=x assignments and wrappers (sudo, env, ...).
 *
 * @param {string} segment
 * @returns {string|null}
 */
function getSegmentCommand(segment) {
  for (const token of segment.split(/\s+/)) {
    if (/^\w+=/.test(token) || COMMAND_WRAPPERS.includes(token) || token.startsWith('-')) continue;
    return token.split('/').pop().toLowerCase();
  }
  return null;
}

// `du -s dir` (or --max-depth=0) prints one line however big the directory is, so it cannot flood the context
const DU_SUMMARY_FLAG = /(?:^|\s)(?:--summarize|--max-depth=0|-d\s*0|-[a-zA-Z]*s[a-zA-Z]*)(?=\s|$)/;

function isReadSegment(segment) {
  const name = getSegmentCommand(segment);
  if (name === 'du' && DU_SUMMARY_FLAG.test(segment)) return false;
  return READ_COMMANDS.includes(name);
}

// Arguments that name a path only to skip it: find -not -path "*/dir/*", -prune, --exclude[-dir],
// --ignore, grep -v, rg -g '!dir'. Quoted or bare value, with space or = separator.
const EXCLUSION_VALUE = '(?:=|\\s+)(?:"[^"]*"|\'[^\']*\'|\\S+)';
const EXCLUSION_ARG_PATTERN = new RegExp(
  `(?:^|\\s)(?:--exclude(?:-dir|-from)?|--ignore|--skip|--prune|--glob|-path|-ipath|-wholename)${EXCLUSION_VALUE}`,
  'g'
);
// find -name X -prune (and -iname): X is skipped, not read
const PRUNED_NAME_PATTERN = new RegExp(`(?:^|\\s)-(?:i?name|i?regex)${EXCLUSION_VALUE}\\s+-prune(?=\\s|$)`, 'g');
// Short flags that take an exclusion value only for specific tools: rg -g '!glob', tree -I pattern, fd -E glob.
// (grep -v takes no value; its pattern is handled by stripPatternArg.)
const TOOL_EXCLUSION_FLAGS = { rg: '-g', tree: '-I', fd: '-E' };

function stripExclusionArgs(command) {
  let stripped = command.replace(PRUNED_NAME_PATTERN, ' ').replace(EXCLUSION_ARG_PATTERN, ' ');
  const flag = TOOL_EXCLUSION_FLAGS[getSegmentCommand(command)];
  if (flag) stripped = stripped.replace(new RegExp(`(?:^|\\s)${flag}${EXCLUSION_VALUE}`, 'g'), ' ');
  return stripped;
}

// Commands whose first positional argument is a pattern or script, not a path:
// grep venv .gitignore, rg node_modules docs, sed '/venv/d' f, awk '/x/' f
const PATTERN_FIRST_COMMANDS = ['grep', 'egrep', 'fgrep', 'rg', 'ag', 'sed', 'awk'];
// Flags whose next token is a value, not the pattern, per command: grep -A 3, rg -t js, awk -F :
// (grep -F means fixed strings and takes no value, so -F is listed for awk only.)
const GREP_VALUE_FLAGS = ['-A', '-B', '-C', '-m', '--max-count', '--context', '--after-context', '--before-context'];
const VALUE_FLAGS = {
  grep: GREP_VALUE_FLAGS, egrep: GREP_VALUE_FLAGS, fgrep: GREP_VALUE_FLAGS,
  rg: [...GREP_VALUE_FLAGS, '-t', '-T', '-j', '--type', '--type-not', '--threads'],
  ag: [...GREP_VALUE_FLAGS, '-G'],
  awk: ['-F', '-v'],
  sed: [],
};
// rg modes without a pattern: every positional is a path
const NO_PATTERN_FLAG = /(?:^|\s)(?:--files|--type-list)(?:\s|$)/;
// When the pattern/script comes from a flag instead, every positional argument is a path
const EXPLICIT_PATTERN_FLAG = /(?:^|\s)(?:-e|-f|--regexp|--file|--expression)(?:=|\s|$)/;

const PATTERN_FLAG_VALUE = new RegExp(`(?:^|\\s)(?:-e|--regexp|--expression)${EXCLUSION_VALUE}`, 'g');

function stripPatternArg(command) {
  const name = getSegmentCommand(command);
  if (!PATTERN_FIRST_COMMANDS.includes(name) || NO_PATTERN_FLAG.test(command)) return command;
  // -e PATTERN / --expression SCRIPT values are patterns too; -f FILE stays a path
  if (EXPLICIT_PATTERN_FLAG.test(command)) return command.replace(PATTERN_FLAG_VALUE, ' ');
  let seenCommand = false;
  let skipValue = false;
  for (const match of command.matchAll(/"[^"]*"|'[^']*'|\S+/g)) {
    const token = match[0];
    if (!seenCommand) {
      if (/^\w+=/.test(token) || COMMAND_WRAPPERS.includes(token) || token.startsWith('-')) continue;
      seenCommand = true; // the command itself
      continue;
    }
    if (skipValue) { skipValue = false; continue; }
    if (VALUE_FLAGS[name].includes(token)) { skipValue = true; continue; }
    if (token.startsWith('-')) continue;
    return command.slice(0, match.index) + ' ' + command.slice(match.index + token.length);
  }
  return command;
}

/**
 * Extract paths from a single read-style command segment.
 *
 * @param {string} command - One segment (no pipes or && / ; operators)
 * @returns {string[]}
 */
function extractFromSegment(rawCommand) {
  const paths = [];
  const command = stripPatternArg(stripExclusionArgs(rawCommand));

  // First, extract quoted strings (preserve spaces in paths)
  const quotedPattern = /["']([^"']+)["']/g;
  let match;
  while ((match = quotedPattern.exec(command)) !== null) {
    const content = match[1];

    // Skip sed/awk regex expressions (s/pattern/replacement/flags)
    if (/^s[\/|@#,]/.test(content)) continue;

    if (looksLikePath(content)) {
      paths.push(normalizeExtractedPath(content));
    }
  }

  // Remove quoted strings for unquoted path extraction
  const withoutQuotes = command.replace(/["'][^"']*["']/g, ' ');

  // Split on whitespace and extract path-like tokens
  const tokens = withoutQuotes.split(/\s+/).filter(Boolean);

  // Track command context per pipe segment
  let commandName = null;
  let isFsCommand = false;
  let skipNextToken = false;
  let heredocDelimiter = null;
  let nextIsHeredocDelimiter = false;

  for (const token of tokens) {
    // Heredoc delimiter capture (after << or <<-)
    if (nextIsHeredocDelimiter) {
      heredocDelimiter = token.replace(/^['"]/, '').replace(/['"]$/, '');
      nextIsHeredocDelimiter = false;
      continue;
    }

    // Skip heredoc body content until closing delimiter
    if (heredocDelimiter) {
      if (token === heredocDelimiter) {
        heredocDelimiter = null;
      }
      continue;
    }

    // Detect heredoc start: <<EOF, <<'EOF', <<"EOF", <<-EOF
    if (token.startsWith('<<') && token.length > 2) {
      heredocDelimiter = token.replace(/^<<-?['"]?/, '').replace(/['"]?$/, '');
      continue;
    }
    if (token === '<<' || token === '<<-') {
      nextIsHeredocDelimiter = true;
      continue;
    }

    // Skip value after exclude flags (--exclude node_modules format)
    if (skipNextToken) {
      skipNextToken = false;
      continue;
    }

    // Reset command context at command/pipe boundaries
    if (token === '&&' || token === ';' || token.startsWith('|')) {
      commandName = null;
      isFsCommand = false;
      continue;
    }

    // Skip flags and shell operators
    if (isSkippableToken(token)) {
      if (EXCLUDE_FLAGS.includes(token)) {
        skipNextToken = true;
      }
      continue;
    }

    // Determine the command for this pipe segment (first non-flag token)
    if (commandName === null) {
      if (/^\w+=/.test(token) || COMMAND_WRAPPERS.includes(token)) continue;
      commandName = getSegmentCommand(token);
      isFsCommand = READ_COMMANDS.includes(commandName);
      // Skip the command word itself
      if (isCommandKeyword(token) || isFsCommand) continue;
      // Non-keyword command (e.g., ./script.sh) — fall through to path check
    }

    // For filesystem commands, extract blocked dir names with priority.
    // "cd build", "ls dist", "cat node_modules/..." — "build"/"dist" are paths here.
    if (isFsCommand && isBlockedDirName(token)) {
      paths.push(normalizeExtractedPath(token));
      continue;
    }

    // Skip common non-path command words
    if (isCommandKeyword(token)) continue;

    // Check if it looks like a path
    if (looksLikePath(token)) {
      paths.push(normalizeExtractedPath(token));
    }
  }

  return paths;
}

// Common blocked directory names that should be extracted even if they
// match command keywords (e.g., "build" is both a subcommand and a dir name)
// Keep in sync with DEFAULT_PATTERNS in pattern-matcher.cjs
const BLOCKED_DIR_NAMES = [
  'node_modules', '__pycache__', '.pytest_cache', '.mypy_cache', '.venv', 'venv'
];

/**
 * Check if token is exactly a blocked directory name
 * This takes priority over command keyword filtering
 *
 * @param {string} token - Token to check
 * @returns {boolean}
 */
function isBlockedDirName(token) {
  return BLOCKED_DIR_NAMES.includes(token);
}

/**
 * Check if a string looks like a file path
 *
 * @param {string} str - String to check
 * @returns {boolean}
 */
function looksLikePath(str) {
  if (!str || str.length < 2) return false;

  // Contains path separator
  if (str.includes('/') || str.includes('\\')) return true;

  // Starts with relative path indicator
  if (str.startsWith('./') || str.startsWith('../')) return true;

  // Has file extension (likely a file)
  if (/\.\w{1,6}$/.test(str)) return true;

  // Looks like a directory path
  if (/^[a-zA-Z0-9_-]+\//.test(str)) return true;

  return false;
}

/**
 * Check if token should be skipped (flags, operators)
 *
 * @param {string} token - Token to check
 * @returns {boolean}
 */
function isSkippableToken(token) {
  // Flags
  if (token.startsWith('-')) return true;

  // Shell operators
  if (['|', '||', '&&', '>', '>>', '<', '<<', '&', ';'].includes(token)) return true;
  if (token.startsWith('|') || token.startsWith('>') || token.startsWith('<')) return true;
  if (token.startsWith('&')) return true;

  // Numeric values
  if (/^\d+$/.test(token)) return true;

  return false;
}

/**
 * Check if token is a common command keyword (not a path)
 *
 * @param {string} token - Token to check
 * @returns {boolean}
 */
function isCommandKeyword(token) {
  const keywords = [
    // Shell commands
    'echo', 'cat', 'ls', 'cd', 'rm', 'cp', 'mv', 'find', 'grep', 'head', 'tail',
    'wc', 'du', 'tree', 'touch', 'mkdir', 'rmdir', 'pwd', 'which', 'env', 'export',
    'source', 'bash', 'sh', 'zsh', 'true', 'false', 'test', 'xargs', 'tee', 'sort',
    'uniq', 'cut', 'tr', 'sed', 'awk', 'diff', 'chmod', 'chown', 'ln', 'file',

    // Package managers and their subcommands
    'npm', 'pnpm', 'yarn', 'bun', 'npx', 'pnpx', 'bunx', 'node',
    'run', 'build', 'test', 'lint', 'dev', 'start', 'install', 'ci', 'exec',
    'add', 'remove', 'update', 'publish', 'pack', 'init', 'create',

    // Build tools
    'tsc', 'esbuild', 'vite', 'webpack', 'rollup', 'turbo', 'nx',
    'jest', 'vitest', 'mocha', 'eslint', 'prettier',

    // Git
    'git', 'commit', 'push', 'pull', 'merge', 'rebase', 'checkout', 'branch',
    'status', 'log', 'diff', 'add', 'reset', 'stash', 'fetch', 'clone',

    // Docker
    'docker', 'compose', 'up', 'down', 'ps', 'logs', 'exec', 'container', 'image',

    // Misc
    'sudo', 'time', 'timeout', 'watch', 'make', 'cargo', 'python', 'python3', 'pip',
    'ruby', 'gem', 'go', 'rust', 'java', 'javac', 'mvn', 'gradle'
  ];

  return keywords.includes(token.toLowerCase());
}

/**
 * Normalize an extracted path
 * - Remove surrounding quotes
 * - Normalize path separators to forward slash
 *
 * @param {string} path - Path to normalize
 * @returns {string} Normalized path
 */
function normalizeExtractedPath(path) {
  if (!path) return '';

  let normalized = path.trim();

  // Remove surrounding quotes
  if ((normalized.startsWith('"') && normalized.endsWith('"')) ||
      (normalized.startsWith("'") && normalized.endsWith("'"))) {
    normalized = normalized.slice(1, -1);
  }

  // Strip shell metacharacters from edges (backticks, parens, braces)
  normalized = normalized.replace(/^[`({\[]+/, '').replace(/[`)};\]]+$/, '');

  // Normalize path separators to forward slash
  normalized = normalized.replace(/\\/g, '/');

  // Remove trailing slash for consistency
  if (normalized.endsWith('/') && normalized.length > 1) {
    normalized = normalized.slice(0, -1);
  }

  return normalized;
}

module.exports = {
  extractFromToolInput,
  extractFromCommand,
  looksLikePath,
  isSkippableToken,
  isCommandKeyword,
  isBlockedDirName,
  normalizeExtractedPath,
  BLOCKED_DIR_NAMES,
  EXCLUDE_FLAGS,
  READ_COMMANDS
};
