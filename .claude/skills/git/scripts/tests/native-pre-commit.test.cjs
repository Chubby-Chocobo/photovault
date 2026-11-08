'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { sh, makeRepo, write, withAdfScripts } = require('./git-flow-test-repo.cjs');
const { hidingGitEnv } = require('../../../../hooks/__tests__/fixtures/diff-header-hiding-git.cjs');

// Built by concatenation so this file never holds a literal credential-shaped string
const FAKE_AWS = 'AKIA' + 'QWERTYUIOPASDFGH';
const FAKE_GITHUB = 'ghp_' + 'abcdefghijklmnopqrstuvwxyz0123456789AB';
const SCRIPT = path.join(__dirname, '..', 'native-pre-commit.cjs');

// Words the hook's output must never carry: a way past the check, an agent could act on them
const NEVER_PRINTED = /--no-verify|uninstall|commitGuard|adf-allow-secret/;

function adfRepo(t, config = {}) {
  const repo = makeRepo(t);
  withAdfScripts(repo.work);
  write(repo.work, '.claude/config/adf-config.json', JSON.stringify(config));
  return repo;
}

/** Runs the hook script on the staged changes. */
function scan(work, env = {}) {
  const r = spawnSync(process.execPath, [SCRIPT], { cwd: work, encoding: 'utf8', env: { ...process.env, ...env } });
  return { code: r.status, out: r.stdout, err: r.stderr };
}

function stage(work, files) {
  for (const [rel, content] of Object.entries(files)) write(work, rel, content);
  const r = spawnSync('git', ['add', '-f', '--', ...Object.keys(files)], { cwd: work, encoding: 'utf8', env: { ...process.env, GIT_LITERAL_PATHSPECS: '1' } });
  assert.equal(r.status, 0, r.stderr);
}

function refused(r, pattern) {
  assert.equal(r.code, 1, r.err);
  assert.match(r.err, pattern);
  assert.doesNotMatch(r.err, NEVER_PRINTED);
  assert.match(r.err, /If you are an AI agent: stop and tell the user/);
}

describe('native pre-commit scan', () => {
  it('passes clean changes without output', (t) => {
    const { work } = adfRepo(t);
    stage(work, { 'a.js': 'const a = 1;\n' });
    const r = scan(work);
    assert.deepEqual([r.code, r.out, r.err], [0, '', '']);
  });

  it('refuses a staged key and a secret file, naming file:line and rule but never the value', (t) => {
    const { work } = adfRepo(t);
    stage(work, { 'config.js': `const k = "${FAKE_AWS}";\n`, '.env': 'X=1\n' });
    const r = scan(work);
    refused(r, /config\.js:1 \(AWS access key\)/);
    assert.match(r.err, /\.env \(secret file\)/);
    assert.match(r.err, /ADF pre-commit: this commit would record secrets \(values not shown\)/);
    assert.match(r.err, /git restore --staged <file>/);
    assert.match(r.err, /"No staged secrets" in the project's git-workflow\.md/);
    assert.ok(!r.err.includes(FAKE_AWS) && !r.out.includes(FAKE_AWS));
  });

  it('finds a key in a file named like pathspec magic', (t) => {
    const { work } = adfRepo(t);
    stage(work, { ':(exclude)x': `k = "${FAKE_AWS}"\n` });
    refused(scan(work), /:\(exclude\)x:1 \(AWS access key\)/);
  });

  it('finds a key in a -diff file from its staged blob', (t) => {
    const { work } = adfRepo(t);
    write(work, '.gitattributes', '*.dat -diff\n');
    stage(work, { 'blob.dat': `k = "${FAKE_GITHUB}"\n` });
    refused(scan(work), /blob\.dat:1 \(GitHub token\)/);
  });

  it('finds a key in a type change from a symlink to a file', (t) => {
    const { work } = adfRepo(t);
    fs.symlinkSync('package.json', path.join(work, 'link'));
    sh(work, 'git', 'add', 'link');
    sh(work, 'git', 'commit', '--quiet', '-m', 'chore: link');
    fs.rmSync(path.join(work, 'link'));
    stage(work, { link: `k = "${FAKE_AWS}"\n` });
    refused(scan(work), /link:1 \(AWS access key\)/);
  });

  it('checks only the name of a binary, and passes an empty staged file', (t) => {
    const { work } = adfRepo(t);
    stage(work, { 'real.bin': Buffer.concat([Buffer.from([0, 1, 2]), Buffer.from(`k = "${FAKE_AWS}"\n`)]), 'empty.txt': '' });
    assert.equal(scan(work).code, 0);
    stage(work, { 'server.pem': Buffer.from([0, 9, 9]) });
    refused(scan(work), /server\.pem \(secret file\)/);
  });

  it('passes a staged 40 MB binary without reading it whole', (t) => {
    const { work } = adfRepo(t);
    stage(work, { 'big.bin': Buffer.alloc(40 * 1024 * 1024) });
    assert.equal(scan(work).code, 0);
  });

  it('skips a line marked adf-allow-secret', (t) => {
    const { work } = adfRepo(t);
    stage(work, { 'doc.md': `example key ${FAKE_AWS} <!-- adf-allow-secret -->\n` });
    assert.equal(scan(work).code, 0);
  });

  it('skips files under commitGuard.allowSecretFiles, names and lines', (t) => {
    const { work } = adfRepo(t, { commitGuard: { allowSecretFiles: ['test/fixtures/**'] } });
    stage(work, { 'test/fixtures/keys.js': `k = "${FAKE_AWS}"\n`, 'test/fixtures/.env': 'X=1\n' });
    assert.equal(scan(work).code, 0);
    stage(work, { 'src/keys.js': `k = "${FAKE_AWS}"\n` });
    refused(scan(work), /src\/keys\.js:1/);
  });

  it('passes when commitGuard.secrets is false', (t) => {
    const { work } = adfRepo(t, { commitGuard: { secrets: false } });
    stage(work, { 'k.js': `k = "${FAKE_AWS}"\n` });
    assert.equal(scan(work).code, 0);
  });

  it('still scans under git.flow off and git.enforcement off', (t) => {
    const { work } = adfRepo(t, { git: { flow: 'off', enforcement: 'off' } });
    stage(work, { 'k.js': `k = "${FAKE_AWS}"\n` });
    refused(scan(work), /k\.js:1/);
  });

  it('scans with the defaults when the config does not parse, and says so', (t) => {
    const { work } = adfRepo(t);
    write(work, '.claude/config/adf-config.json', '{ "commitGuard": { "secrets": false, ');
    stage(work, { 'k.js': `k = "${FAKE_AWS}"\n` });
    const r = scan(work);
    refused(r, /k\.js:1/);
    assert.match(r.err, /adf-config\.json does not parse, so its commit-guard settings were not applied/);
  });

  it('refuses a name no scan covered, naming the files', (t) => {
    const { work } = adfRepo(t);
    stage(work, { 'hidden.js': 'const a = 1;\n' });
    const r = scan(work, hidingGitEnv('hidden.js'));
    refused(r, /could not be scanned for secrets, so the commit is refused:\n {2}- hidden\.js/);
  });

  it('fails closed when git fails, naming the cause', (t) => {
    const { work } = adfRepo(t);
    stage(work, { 'a.js': 'const a = 1;\n' });
    const r = scan(work, { GIT_DIR: path.join(work, 'no-such-git-dir') });
    refused(r, /the scan failed|could not be scanned/);
    assert.match(r.err, /Cause: git failed/);
  });

  it('fails closed on a staged text diff over the scanner buffer, naming the cause', (t) => {
    const { work } = adfRepo(t);
    stage(work, { 'huge.txt': `${'x'.repeat(99)}\n`.repeat(400000) });
    refused(scan(work), /Cause: the staged text changes are larger than the scanner can read at once \(32 MB\)/);
  });

  it('ignores the session project directory and reads the repository being committed', (t) => {
    const { work, dir } = adfRepo(t, { commitGuard: { secrets: false } });
    const other = path.join(dir, 'other-project');
    write(other, '.claude/config/adf-config.json', '{}');
    stage(work, { 'k.js': `k = "${FAKE_AWS}"\n` });
    assert.equal(scan(work, { CLAUDE_PROJECT_DIR: other }).code, 0, 'the repo setting (secrets off) decides');
    write(work, '.claude/config/adf-config.json', '{}');
    refused(scan(work, { CLAUDE_PROJECT_DIR: other }), /k\.js:1/);
  });

  it('still scans when git is told to read pathspecs literally, by option or by variable', (t) => {
    const { work } = adfRepo(t);
    stage(work, { 'k.js': `k = "${FAKE_AWS}"\n` });
    for (const name of ['GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS']) {
      refused(scan(work, { [name]: '1' }), /k\.js:1 \(AWS access key\)/);
    }
    assert.equal(spawnSync('git', ['config', 'core.hooksPath', '.git/hooks'], { cwd: work }).status, 0);
    assert.equal(spawnSync(process.execPath, [path.join(work, '.claude/skills/git/scripts/git-flow.cjs'), 'install-git-hooks', '--only', 'pre-commit'], { cwd: work }).status, 0);
    const r = spawnSync('git', ['--literal-pathspecs', 'commit', '-m', 'feat: k'], { cwd: work, encoding: 'utf8' });
    assert.equal(r.status, 1, 'the option reaches the hook as an environment variable');
    assert.match(r.stderr, /k\.js:1 \(AWS access key\)/);
  });

  it('finds a key at the top level when diff.relative is set and git runs in a subdirectory', (t) => {
    const { work } = adfRepo(t);
    sh(work, 'git', 'config', 'diff.relative', 'true');
    fs.mkdirSync(path.join(work, 'sub'));
    stage(work, { 'top.js': `k = "${FAKE_AWS}"\n`, 'sub/b.js': `k = "${FAKE_GITHUB}"\n` });
    const r = spawnSync(process.execPath, [SCRIPT], { cwd: path.join(work, 'sub'), encoding: 'utf8' });
    refused({ code: r.status, err: r.stderr }, /top\.js:1 \(AWS access key\)/);
    assert.match(r.stderr, /sub\/b\.js:1 \(GitHub token\)/);
  });

  it('scans staged lines when a textconv driver would hide them, and passes when a driver fails on a clean file', (t) => {
    const { work } = adfRepo(t);
    write(work, '.git/info/attributes', '* diff=nul\n*.sec diff=crypt\n');
    sh(work, 'git', 'config', 'diff.nul.textconv', 'true');
    stage(work, { 'k.js': `k = "${FAKE_AWS}"\n` });
    refused(scan(work), /k\.js:1 \(AWS access key\)/);
    sh(work, 'git', 'reset', '--quiet');
    fs.rmSync(path.join(work, 'k.js'));
    sh(work, 'git', 'config', 'diff.crypt.textconv', 'false');
    stage(work, { 'a.sec': 'clean\n' });
    const r = scan(work);
    assert.deepEqual([r.code, r.err], [0, '']);
  });
});

