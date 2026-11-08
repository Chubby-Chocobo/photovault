#!/usr/bin/env node
/**
 * broad-pattern-detector.test.cjs - Unit tests for unbounded glob detection
 *
 * Only match-everything patterns (** and **\/*) at an unscoped root are blocked;
 * ordinary recursive globs must pass.
 *
 * Run: node --test .claude/hooks/tests/scout-block/broad-pattern-detector.test.cjs
 */

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');

const {
  isBroadPattern,
  isRootPath,
  detectBroadPatternIssue,
  formatBroadPatternError
} = require('../../scout-block/broad-pattern-detector.cjs');

describe('isBroadPattern', () => {
  it('detects ** and **/* as broad', () => {
    assert.ok(isBroadPattern('**'));
    assert.ok(isBroadPattern('**/*'));
    assert.ok(isBroadPattern('  **/*  '));
  });

  it('does not treat ordinary recursive globs as broad', () => {
    for (const pattern of ['**/*.ts', '**/*.{ts,tsx}', 'src/**/*.js', '*.js', '*', 'src/**', '**/package.json']) {
      assert.ok(!isBroadPattern(pattern), pattern);
    }
  });

  it('returns false for empty and non-string input', () => {
    assert.ok(!isBroadPattern(''));
    assert.ok(!isBroadPattern(null));
    assert.ok(!isBroadPattern(undefined));
    assert.ok(!isBroadPattern(42));
  });
});

describe('isRootPath', () => {
  it('treats missing path, dot, tilde and home as root', () => {
    for (const p of [undefined, null, '', '.', '/', '~', os.homedir(), os.homedir() + '/']) {
      assert.ok(isRootPath(p), String(p));
    }
  });

  it('treats a scoped directory as not root', () => {
    assert.ok(!isRootPath('src'));
    assert.ok(!isRootPath('/Users/kai/project/src'));
    assert.ok(!isRootPath('packages/web'));
  });
});

describe('detectBroadPatternIssue', () => {
  it('blocks **/* with no path', () => {
    const r = detectBroadPatternIssue({ pattern: '**/*' });
    assert.ok(r.blocked);
    assert.ok(r.reason.includes('**/*'));
    assert.ok(r.suggestions.length > 0);
  });

  it('blocks ** at filesystem root', () => {
    assert.ok(detectBroadPatternIssue({ pattern: '**', path: '/' }).blocked);
  });

  it('allows ordinary recursive globs at project root', () => {
    for (const pattern of ['**/*.ts', 'src/**/*.js', '**/*.{js,ts}', '*.md']) {
      assert.ok(!detectBroadPatternIssue({ pattern }).blocked, pattern);
    }
  });

  it('allows **/* inside a scoped directory', () => {
    assert.ok(!detectBroadPatternIssue({ pattern: '**/*', path: 'src/components' }).blocked);
  });

  it('returns not-blocked for null input, empty object, or missing pattern', () => {
    assert.ok(!detectBroadPatternIssue(null).blocked);
    assert.ok(!detectBroadPatternIssue({}).blocked);
    assert.ok(!detectBroadPatternIssue({ path: 'src' }).blocked);
  });
});

describe('absolute project path', () => {
  it('counts as the root when it equals the project directory', () => {
    assert.ok(isRootPath('/work/proj', '/work/proj'));
    assert.ok(isRootPath('/work/proj/', '/work/proj'));
    assert.ok(detectBroadPatternIssue({ pattern: '**/*', path: '/work/proj' }, '/work/proj').blocked);
  });

  it('does not treat a subdirectory or another project as the root', () => {
    assert.ok(!isRootPath('/work/proj/src', '/work/proj'));
    assert.ok(!detectBroadPatternIssue({ pattern: '**/*', path: '/work/other' }, '/work/proj').blocked);
  });
});

describe('formatBroadPatternError', () => {
  it('is plain text and mentions the pattern', () => {
    const msg = formatBroadPatternError({ pattern: '**/*', suggestions: ['src/**/*.ts'] });
    assert.ok(msg.includes("'**/*'"));
    assert.ok(msg.includes('src/**/*.ts'));
    assert.ok(!msg.includes('\x1b'));
    assert.ok(!msg.includes('undefined'));
  });
});
