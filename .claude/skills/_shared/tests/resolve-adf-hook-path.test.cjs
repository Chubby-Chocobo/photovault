'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { resolveHookPath } = require('../lib/resolve-adf-hook-path.cjs');

const CLI = path.join(__dirname, '..', 'lib', 'resolve-adf-hook-path.cjs');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-hook-resolver-'));
const mkHook = (root) => {
  fs.mkdirSync(path.join(root, '.claude', 'hooks'), { recursive: true });
  const f = path.join(root, '.claude', 'hooks', 'demo-gate.cjs');
  fs.writeFileSync(f, '// stub');
  return fs.realpathSync(f);
};

test('returns project hook path when project has .claude/hooks', () => {
  const project = path.join(tmp, 'project');
  const expected = mkHook(project);
  const got = fs.realpathSync(resolveHookPath('demo-gate.cjs', { cwd: project }));
  assert.strictEqual(got, expected);
});

test('does not fall back to ~/.claude/hooks when the project has none', () => {
  const project = path.join(tmp, 'bare-project');
  const home = path.join(tmp, 'home');
  fs.mkdirSync(project, { recursive: true });
  mkHook(home);
  const r = spawnSync('node', [CLI, 'demo-gate.cjs'], { cwd: project, env: { ...process.env, HOME: home }, encoding: 'utf8' });
  assert.strictEqual(r.status, 1);
  assert.match(r.stderr, /not found/);
});

test('rejects invalid hook names', () => {
  for (const bad of ['../evil.cjs', 'a/b.cjs', 'noext', 'x.js', '', undefined]) {
    assert.throws(() => resolveHookPath(bad, { cwd: tmp }), /invalid hook name/);
  }
});

test('CLI exits 1 with stderr when the project has no such hook', () => {
  const r = spawnSync('node', [CLI, 'missing-hook.cjs'], {
    cwd: path.join(tmp, 'bare-project'), env: { ...process.env, HOME: path.join(tmp, 'home-empty') }, encoding: 'utf8',
  });
  assert.strictEqual(r.status, 1);
  assert.match(r.stderr, /not found/);
});

test('CLI prints the project hook path on success', () => {
  const project = path.join(tmp, 'project');
  const r = spawnSync('node', [CLI, 'demo-gate.cjs'], { cwd: project, encoding: 'utf8' });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(fs.realpathSync(r.stdout.trim()), fs.realpathSync(path.join(project, '.claude/hooks/demo-gate.cjs')));
});

test('monorepo subfolder: uses $CLAUDE_PROJECT_DIR, else the nearest parent with .claude/hooks, not the git root', () => {
  const mono = path.join(tmp, 'mono');
  fs.mkdirSync(mono, { recursive: true });
  spawnSync('git', ['init', '--quiet'], { cwd: mono });
  const app = path.join(mono, 'apps', 'web');
  const expected = mkHook(app);
  const deep = path.join(app, 'src', 'components');
  fs.mkdirSync(deep, { recursive: true });

  const walked = spawnSync('node', [CLI, 'demo-gate.cjs'], { cwd: deep, env: { ...process.env, CLAUDE_PROJECT_DIR: '' }, encoding: 'utf8' });
  assert.strictEqual(walked.status, 0, walked.stderr);
  assert.strictEqual(fs.realpathSync(walked.stdout.trim()), expected);

  const viaEnv = spawnSync('node', [CLI, 'demo-gate.cjs'], { cwd: deep, env: { ...process.env, CLAUDE_PROJECT_DIR: app }, encoding: 'utf8' });
  assert.strictEqual(viaEnv.status, 0, viaEnv.stderr);
  assert.strictEqual(fs.realpathSync(viaEnv.stdout.trim()), expected);

  // Nothing in a parent and no env: falls back to the git top level, which has no hooks here
  const bare = spawnSync('node', [CLI, 'missing.cjs'], { cwd: mono, env: { ...process.env, CLAUDE_PROJECT_DIR: '' }, encoding: 'utf8' });
  assert.strictEqual(bare.status, 1);
});

test('$CLAUDE_PROJECT_DIR is trusted only when absolute, with .claude/hooks, and containing cwd', () => {
  const real = path.join(tmp, 'trust', 'real');
  const other = path.join(tmp, 'trust', 'other');
  const realHook = mkHook(real);
  mkHook(other);
  const inReal = path.join(real, 'sub');
  fs.mkdirSync(inReal, { recursive: true });
  const run = (cwd, dir) => spawnSync('node', [CLI, 'demo-gate.cjs'], { cwd, env: { ...process.env, CLAUDE_PROJECT_DIR: dir, HOME: path.join(tmp, 'no-home') }, encoding: 'utf8' });

  // cwd is not inside the env dir: ignored, the walk-up from cwd wins
  const outside = run(inReal, other);
  assert.strictEqual(outside.status, 0, outside.stderr);
  assert.strictEqual(fs.realpathSync(outside.stdout.trim()), realHook);
  // relative path: ignored
  const relative = run(inReal, path.relative(inReal, other));
  assert.strictEqual(fs.realpathSync(relative.stdout.trim()), realHook);
  // env dir without .claude/hooks: ignored
  const bare = path.join(tmp, 'trust', 'bare');
  fs.mkdirSync(bare, { recursive: true });
  assert.strictEqual(fs.realpathSync(run(inReal, bare).stdout.trim()), realHook);
  // valid: used (cwd inside)
  assert.strictEqual(fs.realpathSync(run(inReal, real).stdout.trim()), realHook);
});

test('the walk-up stops before $HOME, so an old global ~/.claude/hooks is never picked', () => {
  const home = path.join(tmp, 'globalhome');
  mkHook(home);
  const work = path.join(home, 'work', 'app');
  fs.mkdirSync(work, { recursive: true });
  const r = spawnSync('node', [CLI, 'demo-gate.cjs'], { cwd: work, env: { ...process.env, CLAUDE_PROJECT_DIR: '', HOME: home }, encoding: 'utf8' });
  assert.strictEqual(r.status, 1, r.stdout);
  assert.match(r.stderr, /not found/);
  assert.ok(!r.stdout.includes('globalhome'));
});

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
