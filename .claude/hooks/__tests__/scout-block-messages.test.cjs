'use strict';

// scout-block block messages: plain text, name the skipped path, point the user at the project adf-ignore.txt.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const HOOK = path.resolve(__dirname, '..', 'scout-block.cjs');

function runHook(payload, cwd) {
  return spawnSync('node', [HOOK], { input: JSON.stringify({ ...payload, cwd }), encoding: 'utf8', cwd });
}

test('broad glob block message is plain text and shows the pattern, never "undefined"', () => {
  const r = runHook({ tool_name: 'Glob', tool_input: { pattern: '**/*' } }, os.tmpdir());
  assert.strictEqual(r.status, 2);
  assert.match(r.stderr, /'\*\*\/\*'/);
  assert.doesNotMatch(r.stderr, /undefined/);
  assert.doesNotMatch(r.stderr, /\x1b/);
});

test('ordinary recursive globs are allowed', () => {
  for (const pattern of ['**/*.ts', 'src/**/*.js']) {
    const r = runHook({ tool_name: 'Glob', tool_input: { pattern } }, os.tmpdir());
    assert.strictEqual(r.status, 0, pattern + ': ' + r.stderr);
  }
});

test('path block message is plain text, names the skipped dir, and points the user at the project adf-ignore.txt', () => {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'scout-msg-'));
  try {
    const hooks = path.join(project, '.claude', 'hooks');
    fs.cpSync(path.resolve(__dirname, '..'), hooks, { recursive: true, filter: (src) => !/__tests__|\/tests(\/|$)|\/\.logs(\/|$)/.test(src) }); // .logs holds live lock files
    fs.mkdirSync(path.join(project, '.claude', 'config'), { recursive: true });
    fs.writeFileSync(path.join(project, '.claude', 'config', 'adf-ignore.txt'), 'secret-dir\n');

    const r = spawnSync('node', [path.join(hooks, 'scout-block.cjs')], {
      input: JSON.stringify({ tool_name: 'Read', tool_input: { file_path: 'secret-dir/file.txt' }, cwd: project }),
      encoding: 'utf8',
      cwd: project,
    });
    assert.strictEqual(r.status, 2);
    const expected = fs.realpathSync(project) + '/.claude/config/adf-ignore.txt';
    assert.ok(r.stderr.replace(/\/private/g, '').includes(expected.replace(/^\/private/, '')), r.stderr);
    assert.match(r.stderr, /secret-dir/);
    assert.match(r.stderr, /dependency\/cache/);
    assert.match(r.stderr, /user can change/i);
    assert.doesNotMatch(r.stderr, /\x1b|!secret-dir/);
  } finally {
    fs.rmSync(project, { recursive: true, force: true });
  }
});
