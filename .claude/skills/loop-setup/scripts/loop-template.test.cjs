'use strict';

const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const { run, projectRoot, templateNames } = require('./loop-template.cjs');

const TEMPLATES_DIR = path.join(__dirname, '..', 'templates');
const dirs = [];

function project() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'loop-template-'));
  dirs.push(dir);
  return dir;
}
test.after(() => dirs.forEach((dir) => fs.rmSync(dir, { recursive: true, force: true })));

const loopFile = (root) => path.join(root, '.claude', 'loop.md');
const read = (file) => fs.readFileSync(file, 'utf8');
const backups = (root) => {
  const dir = path.join(root, '.claude', 'backups', 'loop-md');
  return fs.existsSync(dir) ? fs.readdirSync(dir).sort().map((f) => read(path.join(dir, f))) : [];
};

test('every template starts with its marker and fits the 25,000-byte loop.md limit', () => {
  assert.deepStrictEqual(templateNames(), ['plan-sync', 'pr-maintenance', 'release-watch']);
  for (const name of templateNames()) {
    const content = read(path.join(TEMPLATES_DIR, `${name}.md`));
    assert.match(content, new RegExp(`^<!-- adf-loop-template: ${name} -->\\r?\\n`), name);
    assert.ok(Buffer.byteLength(content) < 25000, name);
  }
});

test('install writes the template with a content hash; list and status report it', () => {
  const root = project();
  assert.match(run(['status'], root).out[0], /none/);
  assert.strictEqual(run(['install', 'pr-maintenance'], root).code, 0);
  const installed = read(loopFile(root));
  assert.match(installed, /^<!-- adf-loop-template: pr-maintenance sha256:[0-9a-f]{64} -->\n/);
  assert.ok(installed.endsWith(read(path.join(TEMPLATES_DIR, 'pr-maintenance.md')).replace(/^.*\n/, '')));
  assert.match(run(['list'], root).out.join('\n'), /loop\.md: pr-maintenance$/m);
  assert.strictEqual(run(['install', 'plan-sync'], root).code, 0, 'an untouched template is replaced without --force');
  assert.match(run(['status'], root).out[0], /plan-sync$/);
  assert.deepStrictEqual(backups(root), [], 'replacing an untouched template needs no backup');
});

test('an untouched copy of an older template version is not treated as edited', () => {
  const root = project();
  fs.mkdirSync(path.join(root, '.claude'));
  const oldBody = 'Older wording of the PR loop.\n';
  const oldHash = crypto.createHash('sha256').update(oldBody).digest('hex');
  fs.writeFileSync(loopFile(root), `<!-- adf-loop-template: pr-maintenance sha256:${oldHash} -->\n${oldBody}`);
  assert.match(run(['status'], root).out[0], /pr-maintenance \(older version/);
  assert.strictEqual(run(['install', 'pr-maintenance'], root).code, 0);
  assert.match(run(['status'], root).out[0], /pr-maintenance$/);
});

test('a CRLF copy of an installed template still counts as untouched', () => {
  const root = project();
  run(['install', 'release-watch'], root);
  fs.writeFileSync(loopFile(root), read(loopFile(root)).replace(/\n/g, '\r\n'));
  assert.match(run(['status'], root).out[0], /release-watch$/);
});

test('custom and edited files need --force; every --force keeps its own backup', () => {
  const root = project();
  fs.mkdirSync(path.join(root, '.claude'));
  fs.writeFileSync(loopFile(root), 'ORIGINAL\n');
  assert.strictEqual(run(['install', 'release-watch'], root).code, 2);
  assert.strictEqual(read(loopFile(root)), 'ORIGINAL\n');
  assert.strictEqual(run(['install', 'release-watch', '--force'], root).code, 0);

  fs.appendFileSync(loopFile(root), 'extra rule\n');
  assert.match(run(['status'], root).out[0], /release-watch \(edited\)/);
  assert.strictEqual(run(['install', 'plan-sync'], root).code, 2);
  assert.strictEqual(run(['install', 'plan-sync', '--force'], root).code, 0);

  const saved = backups(root);
  assert.strictEqual(saved.length, 2, 'the second --force does not overwrite the first backup');
  assert.strictEqual(saved[0], 'ORIGINAL\n');
  assert.match(saved[1], /extra rule/);
});

test('remove deletes an untouched template; a custom file needs --force and is backed up', () => {
  const root = project();
  run(['install', 'plan-sync'], root);
  assert.strictEqual(run(['remove'], root).code, 0);
  assert.ok(!fs.existsSync(loopFile(root)));
  assert.strictEqual(run(['remove'], root).code, 0, 'nothing to remove is not an error');

  fs.writeFileSync(loopFile(root), 'mine\n');
  assert.strictEqual(run(['remove'], root).code, 2);
  assert.strictEqual(run(['remove', '--force'], root).code, 0);
  assert.ok(!fs.existsSync(loopFile(root)));
  assert.deepStrictEqual(backups(root), ['mine\n']);
});

test('bad input fails cleanly: unknown names or commands, loop.md that is a directory', () => {
  const root = project();
  assert.strictEqual(run(['install', 'nope'], root).code, 1);
  assert.strictEqual(run(['show'], root).code, 1);
  assert.strictEqual(run(['frobnicate'], root).code, 1);
  assert.match(run(['show', 'release-watch'], root).out[0], /default branch/);
  fs.mkdirSync(loopFile(root), { recursive: true });
  assert.strictEqual(run(['install', 'plan-sync', '--force'], root).code, 1);
  assert.match(run(['status'], root).out[0], /not a regular file/);
});

test('project root: the current directory wins when it has .claude/, else the git top level', () => {
  const saved = process.env.CLAUDE_PROJECT_DIR;
  delete process.env.CLAUDE_PROJECT_DIR;
  try {
    const mono = project();
    execFileSync('git', ['init', '-q'], { cwd: mono });
    const pkg = path.join(mono, 'pkg');
    fs.mkdirSync(path.join(pkg, '.claude'), { recursive: true });
    const sub = path.join(mono, 'src');
    fs.mkdirSync(sub);
    assert.strictEqual(fs.realpathSync(projectRoot(pkg)), fs.realpathSync(pkg));
    assert.strictEqual(fs.realpathSync(projectRoot(sub)), fs.realpathSync(mono));
    process.env.CLAUDE_PROJECT_DIR = sub;
    assert.strictEqual(projectRoot(pkg), sub, 'CLAUDE_PROJECT_DIR wins');
  } finally {
    if (saved === undefined) delete process.env.CLAUDE_PROJECT_DIR; else process.env.CLAUDE_PROJECT_DIR = saved;
  }
});

test('project root: nearest .claude/ from a package subfolder; outside git only the current directory', () => {
  const saved = process.env.CLAUDE_PROJECT_DIR;
  delete process.env.CLAUDE_PROJECT_DIR;
  try {
    const mono = project();
    execFileSync('git', ['init', '-q'], { cwd: mono });
    fs.mkdirSync(path.join(mono, '.claude'));
    const src = path.join(mono, 'pkg', 'src');
    fs.mkdirSync(src, { recursive: true });
    fs.mkdirSync(path.join(mono, 'pkg', '.claude'));
    assert.strictEqual(fs.realpathSync(projectRoot(src)), fs.realpathSync(path.join(mono, 'pkg')));

    const outside = project();
    const nested = path.join(outside, 'a');
    fs.mkdirSync(path.join(outside, '.claude'));
    fs.mkdirSync(nested);
    assert.strictEqual(projectRoot(nested), nested, 'never walks up outside git (could reach ~/.claude)');
  } finally {
    if (saved === undefined) delete process.env.CLAUDE_PROJECT_DIR; else process.env.CLAUDE_PROJECT_DIR = saved;
  }
});

test('a symlinked loop.md is never written through; unknown options are rejected', () => {
  const root = project();
  const shared = path.join(project(), 'shared-loop.md');
  fs.writeFileSync(shared, 'SHARED\n');
  fs.mkdirSync(path.join(root, '.claude'));
  fs.symlinkSync(shared, loopFile(root));
  assert.match(run(['status'], root).out[0], /symbolic link/);
  assert.strictEqual(run(['install', 'plan-sync', '--force'], root).code, 1);
  assert.strictEqual(run(['remove', '--force'], root).code, 1);
  assert.strictEqual(read(shared), 'SHARED\n');
  assert.strictEqual(run(['install', 'plan-sync', '--froce'], project()).code, 1);
});
