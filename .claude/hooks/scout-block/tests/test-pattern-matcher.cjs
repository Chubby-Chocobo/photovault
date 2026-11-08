#!/usr/bin/env node
/**
 * test-pattern-matcher.cjs - Unit tests for pattern-matcher module
 */

const path = require('path');
const { loadPatterns, createMatcher, matchPath, DEFAULT_PATTERNS } = require('../pattern-matcher.cjs');

const tests = [
  // === Basic blocking at root ===
  { path: 'node_modules/lodash', expected: true, desc: 'root node_modules with content' },
  { path: 'node_modules', expected: true, desc: 'root node_modules bare' },
  { path: '__pycache__/file.pyc', expected: true, desc: 'root __pycache__' },
  { path: '.venv/lib/site.py', expected: true, desc: 'root .venv' },
  { path: '.next/cache/webpack/x', expected: true, desc: '.next/cache' },

  // === No longer ignored: legitimate to inspect ===
  { path: '.git/objects', expected: false, desc: 'root .git' },
  { path: 'dist/bundle.js', expected: false, desc: 'root dist' },
  { path: 'build/output', expected: false, desc: 'root build' },
  { path: 'vendor/pkg/a.go', expected: false, desc: 'vendor' },
  { path: 'coverage/lcov.info', expected: false, desc: 'coverage' },
  { path: '.next/server/page.js', expected: false, desc: '.next outside cache' },

  // === Path shapes that used to make ignore throw ===
  { path: './testcases', expected: false, desc: './ relative dir' },
  { path: './node_modules/x', expected: true, desc: './ prefixed node_modules' },
  { path: '../node_modules/x', expected: true, desc: '../ prefixed node_modules' },
  { path: 'src/../node_modules/x', expected: true, desc: 'inner .. resolved' },
  { path: 'a//b/./c', expected: false, desc: 'doubled and dotted separators' },
  { path: '/Users/me/app/node_modules/x', expected: true, desc: 'absolute path' },
  { path: 'C:\\app\\node_modules\\x', expected: true, desc: 'windows drive path' },
  { path: '.', expected: false, desc: 'dot' },
  { path: '..', expected: false, desc: 'dotdot' },

  // === Subfolder blocking (THE BUG FIX!) ===
  { path: 'packages/web/node_modules/react', expected: true, desc: 'subfolder node_modules (monorepo)' },
  { path: 'apps/api/node_modules', expected: true, desc: 'subfolder node_modules bare' },
  { path: 'packages/.git/HEAD', expected: false, desc: 'subfolder .git' },
  { path: 'packages/web/dist/index.js', expected: false, desc: 'subfolder dist' },
  { path: 'apps/backend/build/server.js', expected: false, desc: 'subfolder build' },
  { path: 'packages/shared/__pycache__/module.pyc', expected: true, desc: 'subfolder __pycache__' },

  // === Deep nesting ===
  { path: 'a/b/c/d/node_modules/e', expected: true, desc: 'deep nested node_modules' },
  { path: 'projects/monorepo/packages/web/node_modules/react/index.js', expected: true, desc: 'very deep nested' },

  // === Allowed paths ===
  { path: 'src/index.js', expected: false, desc: 'src directory' },
  { path: 'packages/web/src/App.tsx', expected: false, desc: 'nested src' },
  { path: 'lib/utils.js', expected: false, desc: 'lib directory' },
  { path: 'README.md', expected: false, desc: 'root file' },
  { path: 'apps/api/server.ts', expected: false, desc: 'nested app file' },

  // === Edge cases (should NOT be blocked) ===
  { path: 'my-node_modules-project/file.js', expected: false, desc: 'node_modules in project name' },
  { path: 'build-tools/script.sh', expected: false, desc: 'build- prefix in name' },
  { path: 'src/dist-utils.js', expected: false, desc: 'dist- prefix in name' },
  { path: 'nodemodulesbackup/file.js', expected: false, desc: 'node_modules without separator' },
  { path: 'distro/file.js', expected: false, desc: 'dist prefix without separator' },
];

console.log('Testing pattern-matcher module...\n');

const matcher = createMatcher(DEFAULT_PATTERNS);
let passed = 0;
let failed = 0;

for (const test of tests) {
  const result = matchPath(matcher, test.path);
  const success = result.blocked === test.expected;
  if (success) {
    console.log(`\x1b[32m✓\x1b[0m ${test.desc}: ${test.path} -> ${result.blocked ? 'BLOCKED' : 'ALLOWED'}`);
    passed++;
  } else {
    console.log(`\x1b[31m✗\x1b[0m ${test.desc}: expected ${test.expected ? 'BLOCKED' : 'ALLOWED'}, got ${result.blocked ? 'BLOCKED' : 'ALLOWED'}`);
    failed++;
  }
}

console.log(`\nResults: ${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
