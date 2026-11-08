#!/usr/bin/env node
/**
 * Sanity checks for the workspace fixture builder.
 * Run: node --test .claude/hooks/__tests__/workspace-fixtures.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { makePolyglotMonorepo, makeSuperproject, makeTcxWorkspace } = require('./fixtures/workspace-fixtures.cjs');

const BUILDER = path.join(__dirname, 'fixtures', 'workspace-fixtures.cjs');

function git(cwd, ...args) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.strictEqual(r.status, 0, r.stderr);
  return r.stdout.trim();
}

describe('workspace fixtures', () => {
  describe('makeTcxWorkspace', () => {
    it('makes every member its own git root and returns realpath-ed paths', (t) => {
      const { root, members } = makeTcxWorkspace(t);
      assert.strictEqual(root, fs.realpathSync(root));
      assert.strictEqual(git(root, 'rev-parse', '--show-toplevel'), root);
      assert.deepStrictEqual(Object.keys(members).sort(), ['admin-web', 'core', 'gateway', 'market', 'matching-engine', 'order', 'tcx-proto', 'trading']);
      for (const dir of Object.values(members)) {
        assert.strictEqual(dir, fs.realpathSync(dir));
        assert.strictEqual(git(dir, 'rev-parse', '--show-toplevel'), dir);
      }
    });

    it('pins three consumers to three different proto commits', (t) => {
      const { members, protoCommits } = makeTcxWorkspace(t);
      assert.strictEqual(protoCommits.length, 4);
      assert.strictEqual(new Set(protoCommits).size, 4);
      const pin = (name) => git(members[name], 'ls-tree', 'HEAD', 'src/protos').split(/\s+/)[2];
      const pins = [pin('order'), pin('gateway'), pin('core')];
      assert.deepStrictEqual(pins, [protoCommits[1], protoCommits[2], protoCommits[0]]);
      assert.strictEqual(new Set(pins).size, 3);
    });

    it('keeps members out of the umbrella status', (t) => {
      const { root, members } = makeTcxWorkspace(t);
      const status = git(root, 'status', '--porcelain');
      for (const dir of Object.values(members)) {
        assert.ok(!status.includes(path.relative(root, dir)), `${dir} should be ignored`);
      }
      assert.strictEqual(status, '');
    });

    it('gives services/core its own agent files and the others none', (t) => {
      const { members } = makeTcxWorkspace(t);
      for (const rel of ['CLAUDE.md', '.claude/settings.json', '.cursor/rules.md', 'plans/README.md']) {
        assert.ok(fs.existsSync(path.join(members.core, rel)), rel);
        assert.ok(!fs.existsSync(path.join(members.order, rel)), rel);
      }
    });

    it('sets origins and writes the manifest and map only when passed', (t) => {
      const without = makeTcxWorkspace(t);
      assert.strictEqual(git(without.root, 'config', '--get', 'remote.origin.url'), 'https://github.com/acme/tcx-workspace.git');
      assert.strictEqual(git(without.members.order, 'config', '--get', 'remote.origin.url'), 'https://github.com/acme/tcx-order.git');
      assert.strictEqual(git(without.members['tcx-proto'], 'config', '--get', 'remote.origin.url'), 'https://github.com/acme/tcx-proto.git');
      assert.ok(!fs.existsSync(path.join(without.root, 'adf-workspace.json')));
      assert.ok(!fs.existsSync(path.join(without.root, 'docs/architecture/system-map.json')));

      const withBoth = makeTcxWorkspace(t, { manifest: { version: 1 }, map: { components: [] } });
      assert.deepStrictEqual(JSON.parse(fs.readFileSync(path.join(withBoth.root, 'adf-workspace.json'), 'utf8')), { version: 1 });
      assert.deepStrictEqual(JSON.parse(fs.readFileSync(path.join(withBoth.root, 'docs/architecture/system-map.json'), 'utf8')), { components: [] });
      assert.ok(!fs.existsSync(path.join(withBoth.members.order, 'adf-workspace.json')));
    });

    it('writes the Cargo and npm git dependencies', (t) => {
      const { members } = makeTcxWorkspace(t);
      assert.match(fs.readFileSync(path.join(members.trading, 'Cargo.toml'), 'utf8'), /vdax_libs = \{ git = "[^"]+vdax-libs", tag = "v1\.0\.109\.1" \}/);
      assert.match(fs.readFileSync(path.join(members.market, 'Cargo.toml'), 'utf8'), /\[dependencies\.vdax_libs\][^]*tag = "v1\.0\.110\.2"/);
      const deps = JSON.parse(fs.readFileSync(path.join(members['admin-web'], 'package.json'), 'utf8')).dependencies;
      assert.strictEqual(deps['wormhole-sdk'], 'git+https://github.com/acme/wormhole-sdk.git#master');
      assert.strictEqual(deps['ui-kit'], 'github:acme/ui-kit');
      assert.strictEqual(deps.charts, 'git+https://github.com/acme/charts.git#v1.2.0');
    });

    it('embeds the token in the market manifest and origin only with credentialUrl', (t) => {
      const plain = makeTcxWorkspace(t);
      assert.ok(!fs.readFileSync(path.join(plain.members.market, 'Cargo.toml'), 'utf8').includes(plain.token));
      assert.ok(!fs.readFileSync(path.join(plain.members.market, '.git', 'config'), 'utf8').includes(plain.token));

      const leaky = makeTcxWorkspace(t, { credentialUrl: true });
      assert.ok(fs.readFileSync(path.join(leaky.members.market, 'Cargo.toml'), 'utf8').includes(`https://${leaky.token}@github.com/acme/vdax-libs`));
      assert.ok(fs.readFileSync(path.join(leaky.members.market, '.git', 'config'), 'utf8').includes(`https://${leaky.token}@github.com`));
      assert.ok(!fs.readFileSync(path.join(leaky.members.trading, 'Cargo.toml'), 'utf8').includes(leaky.token));
    });

    it('never holds the token as a literal in the builder source', (t) => {
      const { token } = makeTcxWorkspace(t);
      assert.match(token, /^ghp_A{36}$/);
      assert.ok(!fs.readFileSync(BUILDER, 'utf8').includes(token));
      assert.ok(!fs.readFileSync(__filename, 'utf8').includes(token));
    });
  });

  describe('makePolyglotMonorepo', () => {
    it('writes every signal and contract file', (t) => {
      const { root } = makePolyglotMonorepo(t);
      assert.strictEqual(root, fs.realpathSync(root));
      assert.strictEqual(git(root, 'rev-parse', '--show-toplevel'), root);
      for (const rel of ['go.work', 'Cargo.toml', 'pyproject.toml', 'nx.json', 'turbo.json', 'MODULE.bazel', 'services/billing/go.mod',
        'services/ranker/pyproject.toml', 'services/gateway/package.json', 'apps/admin-web/package.json', 'contracts/proto/order.proto',
        'contracts/openapi/gateway.yaml', 'contracts/events/order-filled.schema.json', 'contracts/async/orders.yaml', 'libs/ts/package.json']) {
        assert.ok(fs.existsSync(path.join(root, rel)), rel);
      }
      assert.match(fs.readFileSync(path.join(root, 'contracts/openapi/gateway.yaml'), 'utf8'), /^openapi: 3\.0\.0$/m);
      assert.match(fs.readFileSync(path.join(root, 'contracts/async/orders.yaml'), 'utf8'), /^asyncapi: 2\.6\.0$/m);
      assert.strictEqual(git(root, 'status', '--porcelain'), '');
    });

    it('omit removes the named signals only', (t) => {
      const { root } = makePolyglotMonorepo(t, { omit: ['go.work', 'turbo.json', 'services/+apps/'] });
      assert.ok(!fs.existsSync(path.join(root, 'go.work')));
      assert.ok(!fs.existsSync(path.join(root, 'turbo.json')));
      assert.ok(!fs.existsSync(path.join(root, 'services')));
      assert.ok(!fs.existsSync(path.join(root, 'apps')));
      assert.ok(fs.existsSync(path.join(root, 'nx.json')));
      assert.ok(fs.existsSync(path.join(root, 'contracts/proto/order.proto')));
    });
  });

  describe('makeSuperproject', () => {
    it('records .gitmodules and one gitlink per submodule without a clone', (t) => {
      const { root } = makeSuperproject(t, {
        originUrl: 'https://github.com/acme/app.git',
        submodules: [{ path: 'src/protos', url: 'https://github.com/acme/tcx-proto.git' }, { path: 'lib/forge-std', url: 'https://github.com/foundry-rs/forge-std' }],
      });
      assert.match(fs.readFileSync(path.join(root, '.gitmodules'), 'utf8'), /path = src\/protos\n\turl = https:\/\/github\.com\/acme\/tcx-proto\.git/);
      const links = git(root, 'ls-tree', '-r', 'HEAD').split('\n').filter(l => l.startsWith('160000'));
      assert.strictEqual(links.length, 2);
      assert.strictEqual(git(root, 'config', '--get', 'remote.origin.url'), 'https://github.com/acme/app.git');
      assert.ok(!fs.existsSync(path.join(root, 'src/protos')));
    });

    it('works with no submodules and no origin', (t) => {
      const { root } = makeSuperproject(t);
      assert.ok(!fs.existsSync(path.join(root, '.gitmodules')));
      assert.strictEqual(spawnSync('git', ['config', '--get', 'remote.origin.url'], { cwd: root }).status, 1);
    });
  });
});
