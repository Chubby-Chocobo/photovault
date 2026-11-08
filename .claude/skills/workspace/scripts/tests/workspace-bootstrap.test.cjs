#!/usr/bin/env node
/**
 * Tests for `workspace bootstrap`
 * Run: node --test .claude/skills/workspace/scripts/tests/workspace-bootstrap.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { cli, cliJson, git, initializedWorkspace, editManifest, mirrorOf, outsideDir } = require('./workspace-test-helpers.cjs');

const SSH_ORDER = 'git@github.com:acme/tcx-order.git';
const HTTPS_ORDER = 'https://github.com/acme/tcx-order.git';

const member = (json, name) => json.members.find((m) => m.name === name);
const orderDir = (root) => path.join(root, 'services/order');

/** Workspace whose `order` member lives at a file:// mirror and is not on disk. */
function mirroredWorkspace(t) {
  const ws = initializedWorkspace(t);
  const mirror = mirrorOf(t, orderDir(ws.root), 'order');
  editManifest(ws.root, (m) => { m.members.find((x) => x.name === 'order').repo = mirror.url; });
  fs.rmSync(orderDir(ws.root), { recursive: true, force: true });
  return { ...ws, mirror };
}

describe('workspace bootstrap: protocol', () => {
  it('auto follows the workspace origin: ssh origin plans the ssh URL, https origin the manifest URL', (t) => {
    const { root } = initializedWorkspace(t);
    fs.rmSync(orderDir(root), { recursive: true, force: true });
    const https = cliJson(root, ['bootstrap', '--dry-run', '--protocol', 'auto']);
    assert.strictEqual(member(https.json, 'order').url, HTTPS_ORDER);
    assert.strictEqual(https.json.protocol, 'https');
    git(root, 'remote', 'set-url', 'origin', 'git@github.com:acme/tcx-workspace.git');
    const ssh = cliJson(root, ['bootstrap', '--dry-run']);
    assert.deepStrictEqual([member(ssh.json, 'order').status, member(ssh.json, 'order').url, ssh.json.protocol], ['would-clone', SSH_ORDER, 'ssh']);
    assert.ok(!fs.existsSync(orderDir(root)), 'a dry run clones nothing');
  });

  it('an explicit protocol wins over the origin', (t) => {
    const { root } = initializedWorkspace(t);
    fs.rmSync(orderDir(root), { recursive: true, force: true });
    git(root, 'remote', 'set-url', 'origin', 'git@github.com:acme/tcx-workspace.git');
    assert.strictEqual(member(cliJson(root, ['bootstrap', '--dry-run', '--protocol', 'https']).json, 'order').url, HTTPS_ORDER);
    git(root, 'remote', 'set-url', 'origin', 'https://github.com/acme/tcx-workspace.git');
    assert.strictEqual(member(cliJson(root, ['bootstrap', '--dry-run', '--protocol', 'ssh']).json, 'order').url, SSH_ORDER);
  });

  it('plans a file:// member as written under every protocol, and rejects an unknown protocol', (t) => {
    const { root, mirror } = mirroredWorkspace(t);
    for (const protocol of ['auto', 'ssh', 'https']) {
      const { json } = cliJson(root, ['bootstrap', '--dry-run', '--allow-local', '--protocol', protocol]);
      assert.strictEqual(member(json, 'order').url, mirror.url, protocol);
    }
    assert.strictEqual(cli(root, ['bootstrap', '--protocol', 'ftp']).code, 2);
  });
});

describe('workspace bootstrap: cloning', () => {
  it('refuses a local repo without --allow-local and clones it with the flag', (t) => {
    const { root, mirror } = mirroredWorkspace(t);
    const refused = cliJson(root, ['bootstrap']);
    assert.strictEqual(refused.code, 1);
    assert.strictEqual(member(refused.json, 'order').status, 'refused');
    assert.match(member(refused.json, 'order').reason, /--allow-local/);
    assert.ok(!fs.existsSync(orderDir(root)));
    const done = cliJson(root, ['bootstrap', '--allow-local']);
    assert.strictEqual(done.code, 0, JSON.stringify(done.json));
    assert.strictEqual(member(done.json, 'order').status, 'cloned');
    assert.strictEqual(git(orderDir(root), 'config', '--get', 'remote.origin.url'), mirror.url);
    assert.strictEqual(git(orderDir(root), 'symbolic-ref', '--short', 'HEAD'), 'main');
    assert.strictEqual(member(done.json, 'core').status, 'skipped');
  });

  it('clones a member under a custom role dir once the block ignores it', (t) => {
    const { root, mirror } = mirroredWorkspace(t);
    editManifest(root, (m) => {
      m.roleDirs.push('bots');
      m.members.push({ name: 'telegram', path: 'bots/telegram', repo: mirror.url, branch: 'main', git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } });
    });
    const open = cliJson(root, ['bootstrap', '--allow-local', '--only', 'telegram']);
    assert.strictEqual(open.code, 1);
    assert.match(member(open.json, 'telegram').reason, /not ignored/);
    assert.strictEqual(cliJson(root, ['init']).code, 0);
    const done = cliJson(root, ['bootstrap', '--allow-local', '--only', 'telegram']);
    assert.strictEqual(done.code, 0, JSON.stringify(done.json));
    assert.ok(fs.existsSync(path.join(root, 'bots/telegram/.git')));
    assert.deepStrictEqual(done.json.members.map((m) => m.name), ['telegram']);
  });

  it('refuses a member under a role dir that is a symlink', (t) => {
    const { root, mirror } = mirroredWorkspace(t);
    const outside = outsideDir(t);
    editManifest(root, (m) => {
      m.roleDirs.push('bots');
      m.members.push({ name: 'telegram', path: 'bots/telegram', repo: mirror.url, git: { flow: 'off', enforcement: 'ask', mainBranch: 'main' } });
    });
    cli(root, ['init']);
    fs.symlinkSync(outside, path.join(root, 'bots'));
    const { code, json } = cliJson(root, ['bootstrap', '--allow-local', '--only', 'telegram']);
    assert.strictEqual(code, 1);
    assert.match(member(json, 'telegram').reason, /symlink/);
    assert.deepStrictEqual(fs.readdirSync(outside), []);
  });

  it('refuses a path that the workspace repo does not ignore', (t) => {
    const { root } = mirroredWorkspace(t);
    fs.writeFileSync(path.join(root, '.gitignore'), '');
    const { code, json } = cliJson(root, ['bootstrap', '--allow-local', '--only', 'order']);
    assert.strictEqual(code, 1);
    assert.match(member(json, 'order').reason, /not ignored/);
    assert.ok(!fs.existsSync(orderDir(root)));
  });

  it('reports a clone that fails and leaves nothing behind', (t) => {
    const { root } = mirroredWorkspace(t);
    editManifest(root, (m) => { m.members.find((x) => x.name === 'order').repo = `file://${path.join(root, 'no-such-repo.git')}`; });
    const { code, json } = cliJson(root, ['bootstrap', '--allow-local', '--only', 'order']);
    assert.strictEqual(code, 1);
    assert.strictEqual(member(json, 'order').status, 'failed');
    assert.ok(!fs.existsSync(orderDir(root)));
  });

  it('rejects a repo that starts with "-" at validation', (t) => {
    const { root } = mirroredWorkspace(t);
    editManifest(root, (m) => { m.members.find((x) => x.name === 'order').repo = '--upload-pack=touch-pwned'; });
    const { code, json } = cliJson(root, ['bootstrap', '--allow-local']);
    assert.strictEqual(code, 1);
    assert.ok(json.errors.some((e) => e.includes('.repo must not start with "-"')), json.errors.join('\n'));
  });

  it('--only limits the members and rejects unknown names', (t) => {
    const { root } = mirroredWorkspace(t);
    assert.strictEqual(cliJson(root, ['bootstrap', '--only', 'ghost']).code, 1);
    const { json } = cliJson(root, ['bootstrap', '--dry-run', '--allow-local', '--only', 'order,core']);
    assert.deepStrictEqual(json.members.map((m) => [m.name, m.status]), [['core', 'skipped'], ['order', 'would-clone']]);
  });
});

describe('workspace bootstrap: existing paths', () => {
  it('skips a clone made over ssh when the manifest holds the https URL', (t) => {
    const { root } = initializedWorkspace(t);
    git(orderDir(root), 'remote', 'set-url', 'origin', SSH_ORDER);
    const { code, json } = cliJson(root, ['bootstrap']);
    assert.strictEqual(code, 0);
    assert.deepStrictEqual([member(json, 'order').status, member(json, 'order').reason], ['skipped', 'already cloned']);
  });

  it('reports a path with another remote and leaves it untouched', (t) => {
    const { root } = initializedWorkspace(t);
    git(orderDir(root), 'remote', 'set-url', 'origin', 'https://github.com/other/elsewhere.git');
    const { code, json } = cliJson(root, ['bootstrap']);
    assert.strictEqual(code, 1);
    assert.strictEqual(member(json, 'order').status, 'conflict');
    assert.strictEqual(git(orderDir(root), 'config', '--get', 'remote.origin.url'), 'https://github.com/other/elsewhere.git');
  });

  it('reports a directory that is not a repo and refuses a symlink', (t) => {
    const { root } = initializedWorkspace(t);
    fs.rmSync(path.join(orderDir(root), '.git'), { recursive: true });
    assert.strictEqual(member(cliJson(root, ['bootstrap']).json, 'order').status, 'conflict');
    const outside = outsideDir(t);
    fs.rmSync(orderDir(root), { recursive: true, force: true });
    fs.symlinkSync(outside, orderDir(root));
    const { code, json } = cliJson(root, ['bootstrap']);
    assert.strictEqual(code, 1);
    assert.strictEqual(member(json, 'order').status, 'refused');
    assert.deepStrictEqual(fs.readdirSync(outside), []);
  });

  it('--pull fast-forwards a cloned member', (t) => {
    const { root, mirror } = mirroredWorkspace(t);
    assert.strictEqual(cliJson(root, ['bootstrap', '--allow-local']).code, 0);
    const work = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-work-'));
    t.after(() => fs.rmSync(work, { recursive: true, force: true }));
    git(work, 'clone', '--quiet', mirror.url, 'w');
    git(path.join(work, 'w'), 'commit', '--quiet', '--allow-empty', '-m', 'feat: next');
    git(path.join(work, 'w'), 'push', '--quiet', 'origin', 'main');
    assert.strictEqual(member(cliJson(root, ['bootstrap', '--only', 'order']).json, 'order').status, 'skipped');
    const { json } = cliJson(root, ['bootstrap', '--pull', '--only', 'order']);
    assert.strictEqual(member(json, 'order').status, 'pulled');
    assert.strictEqual(git(orderDir(root), 'rev-parse', 'HEAD'), git(mirror.bare, 'rev-parse', 'HEAD'));
  });

  it('--fix-remotes writes the credential-free URL in the chosen protocol', (t) => {
    const { root, token } = initializedWorkspace(t, { credentialUrl: true });
    const market = path.join(root, 'services/market');
    const hint = cli(root, ['bootstrap']);
    assert.ok(!hint.out.includes(token));
    assert.match(hint.out, /git -C services\/market remote set-url origin https:\/\/github\.com\/acme\/tcx-market\.git/);
    assert.ok(git(market, 'config', '--get', 'remote.origin.url').includes(token), 'not rewritten without the flag');
    assert.strictEqual(cli(root, ['bootstrap', '--fix-remotes', '--protocol', 'ssh']).code, 0);
    assert.strictEqual(git(market, 'config', '--get', 'remote.origin.url'), 'git@github.com:acme/tcx-market.git');
  });
});
