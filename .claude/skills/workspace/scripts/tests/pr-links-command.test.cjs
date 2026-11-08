'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { memberGitWorkspace } = require('../../../../hooks/__tests__/fixtures/member-git-fixtures.cjs');
const { git } = require('./workspace-test-helpers.cjs');
const { run, MARKERS } = require('../lib/pr-links-command.cjs');

const BRANCH = 'feat/login-fix';
const pr = (repo, number, extra = {}) => ({ url: `https://github.com/acme/${repo}/pull/${number}`, number, headRepository: { name: repo }, headRepositoryOwner: { login: 'acme' }, isCrossRepository: false, ...extra });

/**
 * A fake gh on PATH (a node script, so it runs everywhere): `pr list` answers from list/<dir name>.json,
 * `pr view` and `pr edit` read and write bodies/<encoded url>, and every call is logged.
 */
function fakeGh(t, { lists = {}, bodies = {} } = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-fake-gh-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, 'list'));
  fs.mkdirSync(path.join(dir, 'bodies'));
  fs.mkdirSync(path.join(dir, 'bin'));
  for (const [name, prs] of Object.entries(lists)) fs.writeFileSync(path.join(dir, 'list', `${name}.json`), JSON.stringify(prs));
  for (const [url, body] of Object.entries(bodies)) fs.writeFileSync(path.join(dir, 'bodies', encodeURIComponent(url)), body);
  fs.writeFileSync(path.join(dir, 'bin', 'gh'), `#!/usr/bin/env node
const fs = require('fs'), path = require('path');
const dir = process.env.FAKE_GH_DIR, args = process.argv.slice(2);
fs.appendFileSync(path.join(dir, 'log.jsonl'), JSON.stringify({ args, cwd: path.basename(process.cwd()) }) + '\\n');
const body = (url) => path.join(dir, 'bodies', encodeURIComponent(url));
if (args[0] === 'pr' && args[1] === 'list') {
  const f = path.join(dir, 'list', path.basename(process.cwd()) + '.json');
  process.stdout.write(fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '[]');
} else if (args[0] === 'pr' && args[1] === 'view') {
  process.stdout.write(JSON.stringify({ body: fs.existsSync(body(args[2])) ? fs.readFileSync(body(args[2]), 'utf8') : '' }));
} else if (args[0] === 'pr' && args[1] === 'edit') {
  fs.writeFileSync(body(args[2]), fs.readFileSync(0, 'utf8'));
} else { process.stderr.write('unexpected gh call'); process.exit(1); }
`, { mode: 0o755 });
  const calls = () => (fs.existsSync(path.join(dir, 'log.jsonl')) ? fs.readFileSync(path.join(dir, 'log.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l)) : []);
  const bodyOf = (url) => fs.readFileSync(path.join(dir, 'bodies', encodeURIComponent(url)), 'utf8');
  return { bin: path.join(dir, 'bin'), dir, calls, bodyOf, edits: () => calls().filter((c) => c.args[1] === 'edit') };
}

/** Run with the fake gh first on PATH (and its state dir in the environment). */
function withGh(gh, fn) {
  const saved = { PATH: process.env.PATH, FAKE_GH_DIR: process.env.FAKE_GH_DIR };
  process.env.PATH = `${gh.bin}${path.delimiter}${saved.PATH}`;
  process.env.FAKE_GH_DIR = gh.dir;
  try { return fn(); } finally { process.env.PATH = saved.PATH; if (saved.FAKE_GH_DIR === undefined) delete process.env.FAKE_GH_DIR; else process.env.FAKE_GH_DIR = saved.FAKE_GH_DIR; }
}

const prLinks = (ws, opts) => run({ root: ws.root, docsRel: 'docs', opts: { branch: BRANCH, ...opts } });
const SCOPE = { paths: 'services/order,services/gateway' };
const ORDER = pr('tcx-order', 12);
const GATEWAY = pr('tcx-gateway', 7);

describe('pr-links-command', () => {
  it('lists the same-repo PRs of the members in scope', (t) => {
    const ws = memberGitWorkspace(t);
    const gh = fakeGh(t, { lists: { order: [ORDER], gateway: [GATEWAY] } });
    const outcome = withGh(gh, () => prLinks(ws, SCOPE));
    assert.equal(outcome.code, 0);
    assert.deepEqual(outcome.result.prs.map((p) => p.url), [GATEWAY.url, ORDER.url]);
    assert.match(outcome.text, /Related pull requests for feat\/login-fix:\n- gateway \(tcx-gateway\): https:\/\/github\.com\/acme\/tcx-gateway\/pull\/7\n- order \(tcx-order\): https:\/\/github\.com\/acme\/tcx-order\/pull\/12/);
    const list = gh.calls().find((c) => c.cwd === 'order');
    assert.deepEqual(list.args, ['pr', 'list', '--head', BRANCH, '--state', 'open', '--json', 'url,number,headRepository,headRepositoryOwner,isCrossRepository']);
    assert.equal(gh.edits().length, 0, 'without --write nothing is edited');
  });

  it('ignores a fork PR with the same branch name', (t) => {
    const ws = memberGitWorkspace(t);
    const fork = pr('tcx-order', 99, { url: 'https://github.com/stranger/tcx-order/pull/99', headRepositoryOwner: { login: 'stranger' }, isCrossRepository: true });
    const gh = fakeGh(t, { lists: { order: [fork, ORDER], gateway: [GATEWAY] } });
    const outcome = withGh(gh, () => prLinks(ws, { ...SCOPE, write: true }));
    assert.deepEqual(outcome.result.prs.map((p) => p.number), [7, 12]);
    assert.equal(outcome.code, 0, 'the fork does not count as a second match');
    assert.ok(!gh.edits().some((c) => c.args.includes(fork.url)));
  });

  it('ignores a same-named repo that is not the origin', (t) => {
    const ws = memberGitWorkspace(t);
    const elsewhere = pr('tcx-order', 5, { url: 'https://github.com/acme/other-repo/pull/5', headRepository: { name: 'other-repo' } });
    const gh = fakeGh(t, { lists: { order: [elsewhere] } });
    assert.deepEqual(withGh(gh, () => prLinks(ws, { paths: 'services/order' })).result.prs, []);
  });

  it('--write refuses when a member has two matching PRs, and edits nothing', (t) => {
    const ws = memberGitWorkspace(t);
    const gh = fakeGh(t, { lists: { order: [ORDER, pr('tcx-order', 13)], gateway: [GATEWAY] } });
    const outcome = withGh(gh, () => prLinks(ws, { ...SCOPE, write: true }));
    assert.equal(outcome.code, 1);
    assert.match(outcome.text, /more than one open PR for feat\/login-fix in a repo/);
    assert.match(outcome.text, /order: .*\/pull\/12, .*\/pull\/13/);
    assert.equal(gh.edits().length, 0);
  });

  it('--write puts the block in each PR once and a second run changes nothing', (t) => {
    const ws = memberGitWorkspace(t);
    const gh = fakeGh(t, { lists: { order: [ORDER], gateway: [GATEWAY] }, bodies: { [ORDER.url]: 'Fixes the login.\n', [GATEWAY.url]: 'Gateway side.\r\n' } });
    const first = withGh(gh, () => prLinks(ws, { ...SCOPE, write: true }));
    assert.equal(first.code, 0, first.text);
    assert.deepEqual(first.result.written.map((w) => w.status), ['updated', 'updated']);
    assert.equal(gh.edits().length, 2);
    assert.ok(gh.edits().every((c) => c.args.includes('--body-file') && c.args.at(-1) === '-'), 'bodies go in on stdin');
    const body = gh.bodyOf(ORDER.url);
    assert.ok(body.startsWith('Fixes the login.\n'), 'text outside the block is kept');
    assert.equal(body, `Fixes the login.\n\n${MARKERS.begin}\n**Related pull requests**\n- tcx-gateway: ${GATEWAY.url}\n- tcx-order: ${ORDER.url}\n${MARKERS.end}\n`);
    assert.ok(gh.bodyOf(GATEWAY.url).includes(`${MARKERS.begin}\r\n`), 'line endings follow the body');
    const before = [gh.bodyOf(ORDER.url), gh.bodyOf(GATEWAY.url)];

    const second = withGh(gh, () => prLinks(ws, { ...SCOPE, write: true }));
    assert.deepEqual(second.result.written.map((w) => w.status), ['unchanged', 'unchanged']);
    assert.equal(gh.edits().length, 2, 'no further edits');
    assert.deepEqual([gh.bodyOf(ORDER.url), gh.bodyOf(GATEWAY.url)], before);
  });

  it('with no scope asks only the repos that have the branch locally, the workspace included', (t) => {
    const ws = memberGitWorkspace(t);
    git(ws.members.order, 'branch', BRANCH);
    git(ws.root, 'branch', BRANCH);
    const gh = fakeGh(t, { lists: { order: [ORDER], 'tcx-workspace': [pr('tcx-workspace', 3)] } });
    const outcome = withGh(gh, () => prLinks(ws, {}));
    assert.deepEqual(gh.calls().map((c) => c.cwd), ['order', 'tcx-workspace']);
    assert.deepEqual(outcome.result.prs.map((p) => p.member), ['order', 'workspace']);
  });

  it('reports a repo gh cannot query as no PR found and keeps going', (t) => {
    const ws = memberGitWorkspace(t);
    const gh = fakeGh(t, { lists: { gateway: [GATEWAY] } });
    fs.writeFileSync(path.join(gh.bin, 'gh'), fs.readFileSync(path.join(gh.bin, 'gh'), 'utf8').replace("const f = path", "if (path.basename(process.cwd()) === 'order') { process.stderr.write('none of the git remotes point to a known GitHub host'); process.exit(1); }\n  const f = path"));
    const outcome = withGh(gh, () => prLinks(ws, SCOPE));
    assert.equal(outcome.code, 0);
    assert.match(outcome.text, /order: no PR found \(none of the git remotes/);
    assert.deepEqual(outcome.result.prs.map((p) => p.member), ['gateway']);
  });

  it('exits 1 with a message when gh is not installed', (t) => {
    const ws = memberGitWorkspace(t);
    const bin = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-only-git-')));
    t.after(() => fs.rmSync(bin, { recursive: true, force: true }));
    const gitPath = spawnSync(process.platform === 'win32' ? 'where' : 'which', ['git'], { encoding: 'utf8' }).stdout.trim().split('\n')[0];
    fs.symlinkSync(gitPath, path.join(bin, 'git'));
    const saved = process.env.PATH;
    process.env.PATH = bin;
    let outcome;
    try { outcome = prLinks(ws, SCOPE); } finally { process.env.PATH = saved; }
    assert.equal(outcome.code, 1);
    assert.match(outcome.text, /gh is not installed/);
  });

  it('needs a safe --branch and a workspace', (t) => {
    const ws = memberGitWorkspace(t);
    assert.equal(run({ root: ws.root, docsRel: 'docs', opts: {} }).code, 2);
    assert.equal(run({ root: ws.root, docsRel: 'docs', opts: { branch: '--delete' } }).code, 2);
    assert.equal(run({ root: ws.members.order, docsRel: 'docs', opts: { branch: BRANCH } }).code, 1);
  });
});
