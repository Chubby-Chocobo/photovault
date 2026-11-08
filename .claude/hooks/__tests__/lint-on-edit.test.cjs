'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const HOOK = path.resolve(__dirname, '..', 'lint-on-edit.cjs');

/** Project with a stand-in ESLint that exits with `lintExit` and prints a problem when it fails. */
function project({ enabled = true, eslintConfig = true, lintExit = 1 } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lint-on-edit-'));
  fs.mkdirSync(path.join(dir, '.claude', 'config'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.claude', 'config', 'adf-config.json'), JSON.stringify({ lintOnEdit: { enabled } }));
  if (eslintConfig) fs.writeFileSync(path.join(dir, 'eslint.config.js'), 'export default [];\n');
  fs.mkdirSync(path.join(dir, 'node_modules', 'eslint', 'bin'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'node_modules', 'eslint', 'bin', 'eslint.js'),
    `if (${lintExit}) console.log(process.argv[2] + "\\n  1:1  error  Unexpected var  no-var");\nprocess.exit(${lintExit});\n`);
  fs.mkdirSync(path.join(dir, 'src'));
  fs.writeFileSync(path.join(dir, 'src', 'a.js'), 'var a = 1;\n');
  return dir;
}

function run(dir, file = 'src/a.js') {
  return spawnSync('node', [HOOK], {
    input: JSON.stringify({ hook_event_name: 'PostToolUse', tool_name: 'Edit', tool_input: { file_path: path.join(dir, file) }, cwd: dir }),
    encoding: 'utf8',
    cwd: dir,
    env: { ...process.env, HOME: dir, CLAUDE_PROJECT_DIR: '' },
  });
}

test('wakes Claude (exit 2) with the linter output when the edited file has problems', () => {
  const result = run(project());
  assert.strictEqual(result.status, 2);
  assert.match(result.stderr, /eslint reported problems in src\/a\.js/);
  assert.match(result.stderr, /no-var/);
});

test('stays quiet when the linter passes', () => {
  const result = run(project({ lintExit: 0 }));
  assert.strictEqual(result.status, 0);
  assert.strictEqual(result.stderr, '');
});

test('does nothing unless lintOnEdit.enabled is true', () => {
  assert.strictEqual(run(project({ enabled: false })).status, 0);
});

test('does nothing without a linter config or for files no linter covers', () => {
  assert.strictEqual(run(project({ eslintConfig: false })).status, 0);
  const dir = project();
  fs.writeFileSync(path.join(dir, 'README.md'), '# x\n');
  assert.strictEqual(run(dir, 'README.md').status, 0);
});

test('a linter config error or crash (exit 2) does not wake Claude', () => {
  const result = run(project({ lintExit: 2 }));
  assert.strictEqual(result.status, 0);
  assert.strictEqual(result.stderr, '');
});
