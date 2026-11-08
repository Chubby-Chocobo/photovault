/**
 * broad-pattern-detector.cjs - Detect truly unbounded glob patterns
 *
 * Only "match every file" patterns (`**` and `**\/*`) aimed at an unscoped
 * root (no path, ".", "/", "~", home dir) are blocked. Ordinary recursive globs such as
 * `**\/*.ts` or `src/**\/*.js` are fine: results are capped, so the old extension-based
 * heuristics only caused false positives. Glob does not honor .gitignore (Grep does), so a broad
 * Glob at the root also lists gitignored paths such as workspace members.
 */

const os = require('os');

// Patterns that match every file below the base path
const BROAD_PATTERN_REGEXES = [
  /^\*\*$/,
  /^\*\*\/\*$/,
];

/**
 * Check if a glob pattern matches every file
 *
 * @param {string} pattern - The glob pattern to check
 * @returns {boolean}
 */
function isBroadPattern(pattern) {
  if (!pattern || typeof pattern !== 'string') return false;
  const normalized = pattern.trim();
  return BROAD_PATTERN_REGEXES.some(regex => regex.test(normalized));
}

/**
 * Check if the base path is an unscoped root (project cwd, filesystem root, home)
 *
 * @param {string} [basePath] - The path where glob will run
 * @returns {boolean}
 */
function isRootPath(basePath, cwd) {
  // No path specified = uses CWD (project root)
  if (!basePath) return true;

  const normalized = basePath.replace(/\\/g, '/').replace(/\/+$/, '');
  if (normalized === '' || normalized === '.' || normalized === '~') return true;

  const same = (dir) => normalized === dir.replace(/\\/g, '/').replace(/\/+$/, '');
  // The home directory and the project directory (given absolutely) are the root too
  return same(os.homedir()) || (typeof cwd === 'string' && cwd !== '' && same(cwd));
}

/**
 * Main detection function - check if a Glob tool call matches every file at the root
 *
 * @param {Object} toolInput - The tool_input from hook JSON
 * @param {string} toolInput.pattern - The glob pattern
 * @param {string} [toolInput.path] - Optional base path
 * @returns {Object} { blocked: boolean, reason?: string, pattern?: string, suggestions?: string[] }
 */
function detectBroadPatternIssue(toolInput, cwd) {
  if (!toolInput || typeof toolInput !== 'object') {
    return { blocked: false };
  }

  const { pattern, path: basePath } = toolInput;

  if (!isBroadPattern(pattern) || !isRootPath(basePath, cwd)) {
    return { blocked: false };
  }

  return {
    blocked: true,
    reason: `Pattern '${pattern.trim()}' matches every file under ${basePath || 'the project root'}`,
    pattern,
    suggestions: ['src/**/*.ts', 'lib/**/*.js', '**/*.md']
  };
}

/**
 * Format a plain-text message for a blocked unbounded glob
 *
 * @param {Object} result - Result from detectBroadPatternIssue
 * @returns {string}
 */
function formatBroadPatternError(result) {
  const { pattern, suggestions } = result;
  return `Blocked: Glob pattern '${pattern}' would list every file and fill the context. ` +
    `Narrow it with a file type or directory, e.g. ${(suggestions || []).join(', ')}.`;
}

module.exports = {
  isBroadPattern,
  isRootPath,
  detectBroadPatternIssue,
  formatBroadPatternError,
  BROAD_PATTERN_REGEXES
};
