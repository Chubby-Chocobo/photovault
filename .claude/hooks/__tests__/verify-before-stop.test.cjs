'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const HOOK = path.resolve(__dirname, '..', 'verify-before-stop.cjs');

function project(config) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'verify-stop-'));
  fs.mkdirSync(path.join(dir, '.claude', 'config'), { recursive: true });
  if (config) fs.writeFileSync(path.join(dir, '.claude', 'config', 'adf-config.json'), JSON.stringify(config));
  return dir;
}

function session(dir) {
  const id = `verify-test-${process.pid}-${Math.random().toString(36).slice(2)}`;
  const run = (payload) => {
    const result = spawnSync('node', [HOOK], {
      input: JSON.stringify({ session_id: id, cwd: dir, ...payload }),
      encoding: 'utf8',
      cwd: dir,
      env: { ...process.env, HOME: dir, CLAUDE_PROJECT_DIR: '' },
    });
    assert.strictEqual(result.status, 0, result.stderr);
    return result.stdout.trim() ? JSON.parse(result.stdout) : null;
  };
  return {
    edit: (file) => run({ hook_event_name: 'PostToolUse', tool_name: 'Edit', tool_input: { file_path: path.join(dir, file) } }),
    bash: (command) => run({ hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: { command } }),
    stop: (active = false) => run({ hook_event_name: 'Stop', stop_hook_active: active }),
  };
}

test('blocks the stop once after an unverified code edit, then lets it through', () => {
  const s = session(project());
  s.edit('src/math.js');
  const out = s.stop();
  assert.strictEqual(out.decision, 'block');
  assert.match(out.reason, /src\/math\.js/);
  assert.strictEqual(s.stop(true), null, 'the retry after a block always stops');
  assert.strictEqual(s.stop(), null, 'the reminder is not repeated for the same edits');
});

test('a test, lint or build command after the edit clears the reminder', () => {
  for (const command of ['npm test', 'cd app && pytest -q', 'npx vitest run', 'node --test x.test.cjs', 'go test ./...', 'make', 'CI=1 npm test', "FOO='a b' pytest"]) {
    const s = session(project());
    s.edit('src/a.ts');
    s.bash(command);
    assert.strictEqual(s.stop(), null, command);
  }
});

test('commands that only mention a check do not count as one', () => {
  for (const command of [`git commit -m "add test"`, 'cat tests/a.js', 'echo build done', 'grep -rn lint src', 'npm ci', 'make clean', 'make install', 'echo npm test']) {
    const s = session(project());
    s.edit('src/a.ts');
    s.bash(command);
    assert.strictEqual(s.stop()?.decision, 'block', command);
  }
});

test('docs, config, plans and env files are not code', () => {
  const s = session(project());
  for (const file of ['README.md', 'package.json', 'config.yml', '.env.local', 'plans/x/plan.md', 'docs/guide.txt', 'src/logo.svg', 'Dockerfile', '.gitignore', '../scratch/try.js']) s.edit(file);
  assert.strictEqual(s.stop(), null);
});

test('an edit after the last check makes the session unverified again', () => {
  const s = session(project());
  s.edit('src/a.py');
  s.bash('pytest');
  s.edit('src/b.py');
  assert.match(s.stop().reason, /src\/b\.py/);
});

test('extra verification commands come from verifyBeforeStop.commands', () => {
  const s = session(project({ verifyBeforeStop: { commands: ['^\\./scripts/check\\.sh', '(['] } }));
  s.edit('src/a.rb');
  s.bash('./scripts/check.sh --fast');
  assert.strictEqual(s.stop(), null, 'an invalid regex in the list is ignored, the valid one applies');
});

test('hooks.verify-before-stop=false disables the reminder', () => {
  const s = session(project({ hooks: { 'verify-before-stop': false } }));
  s.edit('src/a.js');
  assert.strictEqual(s.stop(), null);
});

test('after the reminder the edited files stay recorded until a check runs; new edits remind again', () => {
  const dir = project();
  const s = session(dir);
  s.edit('src/a.js');
  assert.strictEqual(s.stop().decision, 'block');
  assert.strictEqual(s.stop(true), null);
  assert.strictEqual(s.stop(), null, 'no second reminder for the same edits');
  s.edit('src/b.js');
  assert.match(s.stop().reason, /src\/a\.js, src\/b\.js/, 'a new edit reminds again, listing everything still unchecked');
  s.bash('npm test');
  assert.strictEqual(s.stop(), null);
});

test('parallel edit hooks do not drop each other\'s files', async () => {
  const { spawn } = require('node:child_process');
  const { statePath, readState } = require('../verify-before-stop.cjs');
  const dir = project();
  const id = `verify-parallel-${process.pid}`;
  const files = Array.from({ length: 12 }, (_, i) => `src/file${i}.js`);
  try {
    await Promise.all(files.map((file) => new Promise((resolve, reject) => {
      const child = spawn('node', [HOOK], { cwd: dir, env: { ...process.env, HOME: dir, CLAUDE_PROJECT_DIR: '' } });
      child.on('error', reject);
      child.on('close', resolve);
      child.stdin.end(JSON.stringify({ session_id: id, cwd: dir, hook_event_name: 'PostToolUse', tool_name: 'Edit', tool_input: { file_path: path.join(dir, file) } }));
    })));
    assert.deepStrictEqual([...readState(id).files].sort(), [...files].sort());
  } finally {
    fs.rmSync(statePath(id), { force: true });
    fs.rmSync(`${statePath(id)}.lock`, { force: true });
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
