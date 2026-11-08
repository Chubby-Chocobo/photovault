'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { spawnSync, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const HOOK = path.resolve(__dirname, '..', 'simplify-gate.cjs');

function writeAdfConfig(dir, config) {
  fs.mkdirSync(path.join(dir, '.claude', 'config'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.claude', 'config', 'adf-config.json'), JSON.stringify(config));
}

function makeRepo({ enableGate = true } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'simplify-gate-'));
  const git = (...args) => execFileSync('git', args, { cwd: dir, stdio: 'ignore' });
  git('init', '--initial-branch=main');
  git('config', 'user.email', 'test@example.com');
  git('config', 'user.name', 'Test');
  fs.writeFileSync(path.join(dir, 'README.md'), '# repo\n');
  // Gate defaults to OFF (opt-in). Most tests exercise enabled-gate behavior,
  // so commit an adf-config.json enabling it (committed so it doesn't pollute diff signals).
  // Tests that need default-off pass enableGate=false.
  if (enableGate) {
    writeAdfConfig(dir, { simplify: { gate: { enabled: true } } });
  }
  git('add', '.');
  git('commit', '-m', 'init');
  return dir;
}

function runHook(payload, env = {}) {
  // Spawn inside the payload cwd (as Claude Code does) so isHookEnabled() reads the temp repo's
  // adf-config, never the live project's. HOME is isolated from any global adf-config.
  const cwd = payload.cwd && fs.existsSync(payload.cwd) ? payload.cwd : os.tmpdir();
  return spawnSync('node', [HOOK], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    cwd,
    env: { ...process.env, HOME: cwd, ...env }
  });
}

function writeBigFile(dir, name, lines) {
  const body = Array.from({ length: lines }, (_, i) => `line ${i}`).join('\n') + '\n';
  fs.writeFileSync(path.join(dir, name), body);
}

function parseStdout(stdout) {
  const trimmed = (stdout || '').trim();
  if (!trimmed) return null;
  return JSON.parse(trimmed);
}

test('exits silently when prompt has no ship/commit verb', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 1000);
  const r = runHook({ cwd: dir, prompt: 'add a new feature please' });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout.trim(), '');
});

test('exits silently when verb present but diff is small', () => {
  const dir = makeRepo();
  fs.writeFileSync(path.join(dir, 'small.ts'), 'one\ntwo\n');
  const r = runHook({ cwd: dir, prompt: 'ship this' });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout.trim(), '');
});

test('reminds before shipping when LOC threshold breached, never blocks the prompt', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  const r = runHook({ cwd: dir, prompt: 'ship it' });
  assert.strictEqual(r.status, 0);
  const out = parseStdout(r.stdout);
  assert.match(out.hookSpecificOutput.additionalContext, /Unsimplified diff/);
  assert.match(out.hookSpecificOutput.additionalContext, /600 LOC/);
  assert.match(out.hookSpecificOutput.additionalContext, /code-simplifier/);
});

test('reminds on explicit ship commands', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  for (const prompt of ['/ship', '/ship', 'ready to ship', 'please ship this']) {
    const r = runHook({ cwd: dir, prompt });
    assert.strictEqual(r.status, 0, `prompt should not be blocked: ${prompt}`);
    assert.match(parseStdout(r.stdout).hookSpecificOutput.additionalContext, /before shipping/i);
  }
});

test('reminds on merge/pr/deploy/publish too', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  for (const verb of ['merge', 'pr', 'deploy', 'publish']) {
    const r = runHook({ cwd: dir, prompt: `${verb} the change` });
    assert.strictEqual(r.status, 0, `${verb} should not be blocked`);
    assert.match(parseStdout(r.stdout).hookSpecificOutput.additionalContext, /before shipping/i);
  }
});

test('soft-warns commit/finalize/release verbs', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  for (const verb of ['commit', 'finalize', 'release']) {
    const r = runHook({ cwd: dir, prompt: `${verb} the change` });
    assert.strictEqual(r.status, 0, `${verb} should soft-warn`);
    const out = parseStdout(r.stdout);
    assert.strictEqual(out.hookSpecificOutput.hookEventName, 'UserPromptSubmit');
    assert.match(out.hookSpecificOutput.additionalContext, /Unsimplified diff/);
  }
});

test('reminds when fileCount threshold breached even with small per-file diff', () => {
  const dir = makeRepo();
  for (let i = 0; i < 10; i++) {
    writeBigFile(dir, `f${i}.ts`, 5);
  }
  const r = runHook({ cwd: dir, prompt: 'ship it' });
  assert.strictEqual(r.status, 0);
  const out = parseStdout(r.stdout);
  assert.match(out.hookSpecificOutput.additionalContext, /10 files/);
});

test('reminds when single file exceeds singleFileLoc threshold', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'huge.ts', 250);
  const r = runHook({ cwd: dir, prompt: 'ship it' });
  assert.strictEqual(r.status, 0);
  const out = parseStdout(r.stdout);
  assert.match(out.hookSpecificOutput.additionalContext, /single file \+250 LOC/);
});

test('ignores false-positive prompts with negation or "ship on"', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  const cases = [
    "Don't ship that yet",
    'What ports does the API ship on?',
    'Check the relationship between X and Y',
    'Update the merger function',
    'never ship a Friday hotfix',
    'ship',
    'Update the ship model entity',
    'ship entity appears in product copy'
  ];
  for (const prompt of cases) {
    const r = runHook({ cwd: dir, prompt });
    assert.strictEqual(r.status, 0, `prompt should not block: ${prompt}`);
    assert.strictEqual(r.stdout.trim(), '', `should be silent for: ${prompt}`);
  }
});

test('ADF_SIMPLIFY_DISABLED=1 short-circuits regardless of signals', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  const r = runHook({ cwd: dir, prompt: 'ship it' }, { ADF_SIMPLIFY_DISABLED: '1' });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout.trim(), '');
});

test('default config (no adf-config.json) leaves gate OFF — exits silently even on big diff + ship verb', () => {
  const dir = makeRepo({ enableGate: false });
  writeBigFile(dir, 'big.ts', 600);
  const r = runHook({ cwd: dir, prompt: 'ship it' });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout.trim(), '');
});

test('respects adf-config.json simplify.gate.enabled=false', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  writeAdfConfig(dir, {
    simplify: { gate: { enabled: false } }
  });
  const r = runHook({ cwd: dir, prompt: 'ship it' });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout.trim(), '');
});

test('hooks.simplify-gate=false in adf-config bypasses a ship prompt on a big diff', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  writeAdfConfig(dir, { hooks: { 'simplify-gate': false }, simplify: { gate: { enabled: true } } });
  // isHookEnabled resolves config from process.cwd(), as Claude Code spawns hooks in the project dir.
  const r = spawnSync('node', [HOOK], {
    input: JSON.stringify({ cwd: dir, prompt: 'ship it' }),
    encoding: 'utf8',
    cwd: dir,
    env: { ...process.env, HOME: dir }
  });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout.trim(), '');
});

test('honors custom thresholds from adf-config.json', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'mid.ts', 100);
  writeAdfConfig(dir, {
    simplify: {
      threshold: { locDelta: 50, fileCount: 100, singleFileLoc: 10000 },
      gate: { enabled: true }
    }
  });
  const r = runHook({ cwd: dir, prompt: 'ship it' });
  assert.strictEqual(r.status, 0);
  const out = parseStdout(r.stdout);
  assert.match(out.hookSpecificOutput.additionalContext, /\d+ LOC/);
});

test('honors custom verbs from adf-config.json', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  writeAdfConfig(dir, {
    simplify: { gate: { enabled: true, hardVerbs: ['launch'], softVerbs: [] } }
  });
  const reminded = runHook({ cwd: dir, prompt: 'launch the rocket' });
  assert.strictEqual(reminded.status, 0);
  assert.match(parseStdout(reminded.stdout).hookSpecificOutput.additionalContext, /before shipping/i);

  const ignored = runHook({ cwd: dir, prompt: 'ship it' });
  assert.strictEqual(ignored.status, 0);
});

test('exits 0 when git diff fails (non-repo cwd)', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'no-git-'));
  const r = runHook({ cwd: tmp, prompt: 'ship it' });
  assert.strictEqual(r.status, 0);
});

test('exits 0 when payload omits prompt', () => {
  const dir = makeRepo();
  writeBigFile(dir, 'big.ts', 600);
  const r = runHook({ cwd: dir });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout.trim(), '');
});

test('exits 0 when payload is missing/invalid JSON on stdin', () => {
  const r = spawnSync('node', [HOOK], { input: '', encoding: 'utf8' });
  assert.strictEqual(r.status, 0);
});
