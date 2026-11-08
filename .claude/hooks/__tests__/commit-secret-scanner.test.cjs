'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { scanCommit, chunkByBytes } = require('../lib/commit-secret-scanner.cjs');

// Built by concatenation so this file never contains a literal credential-shaped string
const FAKE_AWS = 'AKIA' + 'QWERTYUIOPASDFGH';

function makeRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'secret-scanner-'));
  process.on('exit', () => fs.rmSync(dir, { recursive: true, force: true }));
  const git = (...args) => execFileSync('git', args, { cwd: dir, stdio: 'ignore' });
  git('init', '--initial-branch=main');
  git('config', 'user.email', 'test@example.com');
  git('config', 'user.name', 'Test');
  return dir;
}

test('untracked files past the byte budget are reported as not scanned, never skipped silently', () => {
  const dir = makeRepo();
  for (const name of ['a.txt', 'b.txt', 'c.txt']) fs.writeFileSync(path.join(dir, name), `${'x'.repeat(99)}\n`);
  fs.writeFileSync(path.join(dir, 'd.txt'), `k = "${FAKE_AWS}"\n`);
  // 100 bytes per clean file, so a budget of 250 reads two of them
  const result = scanCommit(dir, { untracked: true, untrackedByteBudget: 250 });
  assert.deepStrictEqual(result.unscanned, ['c.txt', 'd.txt']);
  assert.deepStrictEqual(result.findings, [], 'd.txt was past the budget, so it is reported instead');
  assert.deepStrictEqual(scanCommit(dir, { untracked: true }).unscanned, []);
  assert.strictEqual(scanCommit(dir, { untracked: true }).findings[0].file, 'd.txt');
});

test('an empty or over-sized untracked file costs at most the per-file read', () => {
  const dir = makeRepo();
  fs.writeFileSync(path.join(dir, 'empty.txt'), '');
  fs.writeFileSync(path.join(dir, 'big.txt'), 'y'.repeat(3 * 1024 * 1024));
  fs.writeFileSync(path.join(dir, 'after.txt'), 'z\n');
  // big.txt is charged 1 MB, not 3: after.txt still fits a 1 MB + 10 byte budget
  assert.deepStrictEqual(scanCommit(dir, { untracked: true, untrackedByteBudget: 1024 * 1024 + 10 }).unscanned, []);
});

test('chunkByBytes keeps every run within the budget and loses no entry', () => {
  const entries = Array.from({ length: 10 }, (_, i) => ({ name: `f${i}`, size: 1000 }));
  const chunks = chunkByBytes(entries, 3 * (1000 + 128));
  assert.deepStrictEqual(chunks.map((c) => c.length), [3, 3, 3, 1]);
  assert.deepStrictEqual(chunks.flat(), entries);
  assert.deepStrictEqual(chunkByBytes([{ name: 'big', size: 5000 }], 100), [[{ name: 'big', size: 5000 }]], 'an entry over the budget still gets a run of its own');
  assert.deepStrictEqual(chunkByBytes([], 100), []);
  const many = Array.from({ length: 1200 }, (_, i) => ({ name: `b${i}`, size: 1024 * 1024 }));
  const peak = Math.max(...chunkByBytes(many).map((c) => c.reduce((sum, e) => sum + e.size, 0)));
  assert.ok(peak <= 16 * 1024 * 1024, `the largest run holds ${peak} bytes`);
});

test('names git quotes in diff headers are scanned, not reported as unscanned', () => {
  const dir = makeRepo();
  const git = (...args) => execFileSync('git', args, { cwd: dir, stdio: 'ignore' });
  const names = ['quo"te.txt', 'back\\slash.txt', 'tab\there.txt', 'new\nline.txt', 'café "x".txt'];
  for (const name of names) fs.writeFileSync(path.join(dir, name), 'clean\n');
  fs.writeFileSync(path.join(dir, 'k"ey.txt'), `k = "${FAKE_AWS}"\n`);
  git('add', '-A');
  const staged = scanCommit(dir);
  assert.deepStrictEqual(staged.unscanned, []);
  assert.deepStrictEqual(staged.findings.map((f) => f.file), ['k"ey.txt']);
  git('commit', '-qm', 'base');
  git('mv', 'quo"te.txt', 'plain.txt');
  git('mv', 'back\\slash.txt', 'still\\quoted.txt');
  fs.appendFileSync(path.join(dir, 'tab\there.txt'), `t = "${FAKE_AWS}"\n`);
  git('add', '-A');
  const renamed = scanCommit(dir);
  assert.deepStrictEqual(renamed.unscanned, []);
  assert.deepStrictEqual(renamed.findings.map((f) => [f.file, f.line]), [['tab\there.txt', 2]]);
});

test('a submodule bump is scanned as its commit ids whatever diff.submodule says', () => {
  const sub = makeRepo();
  fs.writeFileSync(path.join(sub, 'fixture.txt'), `k = "${FAKE_AWS}"\n`);
  execFileSync('git', ['add', 'fixture.txt'], { cwd: sub });
  execFileSync('git', ['commit', '-qm', 'fixture'], { cwd: sub });
  const dir = makeRepo();
  const git = (...args) => execFileSync('git', ['-c', 'protocol.file.allow=always', ...args], { cwd: dir, stdio: 'ignore' });
  git('submodule', 'add', '-q', sub, 'm');
  for (const mode of ['short', 'log', 'diff']) {
    git('config', 'diff.submodule', mode);
    assert.deepStrictEqual(scanCommit(dir), { files: [], findings: [], unscanned: [] }, `diff.submodule=${mode}`);
  }
});
