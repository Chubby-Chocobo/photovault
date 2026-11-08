#!/usr/bin/env node
/**
 * error-formatter.cjs - Error messages for scout-block
 *
 * Block messages are plain text; color helpers remain for non-blocking warnings.
 */

const path = require('path');

// ANSI color codes
const COLORS = {
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  cyan: '\x1b[36m',
  bold: '\x1b[1m',
  dim: '\x1b[2m',
  reset: '\x1b[0m'
};

/**
 * Check if terminal supports colors
 * Respects NO_COLOR standard and FORCE_COLOR
 *
 * @returns {boolean}
 */
function supportsColor() {
  // Respect NO_COLOR standard (https://no-color.org/)
  if (process.env.NO_COLOR !== undefined) return false;

  // Respect FORCE_COLOR
  if (process.env.FORCE_COLOR !== undefined) return true;

  // Check if stderr is TTY (we output errors to stderr)
  return process.stderr.isTTY || false;
}

/**
 * Apply color to text if supported
 *
 * @param {string} text - Text to colorize
 * @param {string} color - Color name from COLORS
 * @returns {string}
 */
function colorize(text, color) {
  if (!supportsColor()) return text;
  const colorCode = COLORS[color] || '';
  return `${colorCode}${text}${COLORS.reset}`;
}

/**
 * Get adf-ignore.txt config path
 *
 * @param {string} claudeDir - Path to .claude directory
 * @param {string} [configPath] - Explicit config path to prefer
 * @returns {string}
 */
function formatConfigPath(claudeDir, configPath) {
  if (configPath) {
    return configPath;
  }
  if (claudeDir) {
    return path.join(claudeDir, 'config', 'adf-ignore.txt');
  }
  return '.claude/config/adf-ignore.txt';
}

/**
 * Format a blocked path error: plain text (no ANSI), short, addressed to the model.
 * The config path is a user-facing note; the model is not told to edit it.
 *
 * @param {Object} details - Error details
 * @param {string} details.path - The blocked path
 * @param {string} details.pattern - The pattern that matched
 * @param {string} details.tool - The tool that was blocked
 * @param {string} details.claudeDir - Path to .claude directory
 * @param {string} [details.configPath] - Explicit config path to edit
 * @returns {string}
 */
function formatBlockedError(details) {
  const { path: blockedPath, pattern, claudeDir, configPath } = details;
  const resolvedConfigPath = formatConfigPath(claudeDir, configPath);

  // Truncate path if too long
  const displayPath = blockedPath.length > 60
    ? '...' + blockedPath.slice(-57)
    : blockedPath;

  return `Skipped '${displayPath}': it is dependency/cache content (pattern '${pattern}') ` +
    `and reading it would waste context. The user can change this list in ${resolvedConfigPath}.`;
}

/**
 * Format a simple error message (one line, for piped output)
 *
 * @param {string} pattern - The pattern that matched
 * @param {string} blockedPath - The path that was blocked
 * @returns {string}
 */
function formatSimpleError(pattern, blockedPath) {
  return `ERROR: Blocked pattern '${pattern}' matched path: ${blockedPath}`;
}

/**
 * Format error for machine-readable output (exit code 2)
 * Used when stderr is not a TTY
 *
 * @param {Object} details - Error details
 * @returns {string}
 */
function formatMachineError(details) {
  const { path: blockedPath, pattern, tool, claudeDir, configPath } = details;
  const resolvedConfigPath = formatConfigPath(claudeDir, configPath);

  return JSON.stringify({
    error: 'BLOCKED',
    path: blockedPath,
    pattern: pattern,
    tool: tool,
    config: resolvedConfigPath
  });
}

/**
 * Format a warning message (non-blocking)
 *
 * @param {string} message - Warning message
 * @returns {string}
 */
function formatWarning(message) {
  return colorize('WARN:', 'yellow') + ' ' + message;
}

module.exports = {
  formatBlockedError,
  formatSimpleError,
  formatMachineError,
  formatWarning,
  formatConfigPath,
  supportsColor,
  colorize,
  COLORS
};
