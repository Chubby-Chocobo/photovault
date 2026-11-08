#!/usr/bin/env node
/**
 * pattern-matcher.cjs - Gitignore-spec compliant pattern matching
 *
 * Uses 'ignore' package for adf-ignore.txt parsing and path matching.
 * Supports negation patterns (!) for allowlisting.
 */

const Ignore = require('./vendor/ignore.cjs');
const fs = require('fs');
const path = require('path');

// Default patterns if adf-ignore.txt doesn't exist or is empty.
// Only dependency/cache directories that are never worth reading; build outputs,
// vendor, coverage and .git are legitimate to inspect and are left alone.
const DEFAULT_PATTERNS = [
  'node_modules',
  '**/.next/cache',
  '__pycache__',
  '.pytest_cache',
  '.mypy_cache',
  '.venv',
  'venv',
];

function readPatternsFromFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) {
    return [];
  }

  try {
    return fs.readFileSync(filePath, 'utf-8')
      .split('\n')
      .map(line => line.trim())
      .filter(line => line && !line.startsWith('#'));
  } catch (error) {
    console.error('WARN: Failed to read adf-ignore.txt:', error.message);
    return [];
  }
}

/**
 * Load patterns from the shipped adf-ignore.txt plus an optional project override.
 * Falls back to DEFAULT_PATTERNS if the shipped file doesn't exist or is empty.
 *
 * @param {string} adfIgnorePath - Path to shipped/global adf-ignore.txt file
 * @param {string} [projectAdfIgnorePath] - Optional project-local adf-ignore.txt path
 * @returns {string[]} Array of patterns
 */
function loadPatterns(adfIgnorePath, projectAdfIgnorePath) {
  const shippedPatterns = readPatternsFromFile(adfIgnorePath);
  const projectPatterns = readPatternsFromFile(projectAdfIgnorePath);
  const basePatterns = shippedPatterns.length > 0 ? shippedPatterns : DEFAULT_PATTERNS;
  return [...basePatterns, ...projectPatterns];
}

/**
 * Create a matcher from patterns
 * Normalizes patterns to match anywhere in the path tree
 *
 * @param {string[]} patterns - Array of patterns from adf-ignore.txt
 * @returns {Object} Matcher object with ig instance and pattern info
 */
function createMatcher(patterns) {
  const ig = Ignore();

  // Normalize patterns to match anywhere in path tree
  // e.g., "node_modules" becomes "**\/node_modules" and "**\/node_modules/**"
  const normalizedPatterns = [];

  for (const p of patterns) {
    if (p.startsWith('!')) {
      // Negation pattern - un-ignore
      const inner = p.slice(1);
      if (inner.includes('/') || inner.includes('*')) {
        // Already has path or glob - use as-is
        normalizedPatterns.push(p);
      } else {
        // Simple dir name - match anywhere
        normalizedPatterns.push(`!**/${inner}`);
        normalizedPatterns.push(`!**/${inner}/**`);
      }
    } else {
      // Block pattern
      if (p.includes('/') || p.includes('*')) {
        // Already has path or glob - use as-is
        normalizedPatterns.push(p);
      } else {
        // Simple dir name - match the dir and contents anywhere
        normalizedPatterns.push(`**/${p}`);
        normalizedPatterns.push(`**/${p}/**`);
        // Also match at root
        normalizedPatterns.push(p);
        normalizedPatterns.push(`${p}/**`);
      }
    }
  }

  ig.add(normalizedPatterns);

  return {
    ig,
    patterns: normalizedPatterns,
    original: patterns
  };
}

/**
 * Check if a path should be blocked
 *
 * @param {Object} matcher - Matcher object from createMatcher
 * @param {string} testPath - Path to test
 * @returns {Object} { blocked: boolean, pattern?: string }
 */
function matchPath(matcher, testPath) {
  if (!testPath || typeof testPath !== 'string') {
    return { blocked: false };
  }

  const normalized = toRelativeMatchPath(testPath);

  // Empty after normalization = not a blockable path
  if (!normalized) {
    return { blocked: false };
  }

  // Fail-open: a matcher error must never block or crash the hook
  try {
    if (!matcher.ig.ignores(normalized)) {
      return { blocked: false };
    }
    return { blocked: true, pattern: findMatchingPattern(matcher.original, normalized) };
  } catch (error) {
    return { blocked: false };
  }
}

/**
 * Convert any extracted path into the clean relative form 'ignore' accepts
 * (it throws on "./x", "../x", "a/../b", "C:/x"). Absolute paths lose their
 * leading slash/drive so "**\/dir" patterns still match them.
 *
 * @param {string} testPath - Raw path
 * @returns {string} Relative posix path ('' when nothing blockable remains)
 */
function toRelativeMatchPath(testPath) {
  let normalized = path.posix.normalize(testPath.replace(/\\/g, '/'));
  normalized = normalized.replace(/^[A-Za-z]:\//, '');
  normalized = normalized.replace(/^(\.\.?\/|\/)+/, '');
  if (normalized === '.' || normalized === '..') return '';
  return normalized.replace(/\/$/, '');
}

/**
 * Find which original pattern matched (for error messages)
 *
 * @param {string[]} originalPatterns - Original patterns from adf-ignore.txt
 * @param {string} path - The path that was blocked
 * @returns {string} The pattern that matched
 */
function findMatchingPattern(originalPatterns, path) {
  for (const p of originalPatterns) {
    if (p.startsWith('!')) continue; // Skip negations

    // Simple substring check for common cases
    const pattern = p.replace(/\*\*/g, '').replace(/\*/g, '');
    if (pattern && path.includes(pattern)) {
      return p;
    }

    // For more complex patterns, use ignore to test individually
    const tempIg = Ignore();
    if (p.includes('/') || p.includes('*')) {
      tempIg.add(p);
    } else {
      tempIg.add([`**/${p}`, `**/${p}/**`, p, `${p}/**`]);
    }

    if (tempIg.ignores(path)) {
      return p;
    }
  }

  return originalPatterns.find(p => !p.startsWith('!')) || 'unknown';
}

module.exports = {
  loadPatterns,
  createMatcher,
  matchPath,
  toRelativeMatchPath,
  findMatchingPattern,
  DEFAULT_PATTERNS
};
