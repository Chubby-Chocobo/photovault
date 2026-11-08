#!/usr/bin/env node
/**
 * Tests for repo-shape-detector.cjs
 * Run: node --test .claude/hooks/lib/__tests__/repo-shape-detector.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { makePolyglotMonorepo, makeSuperproject, makeTcxWorkspace } = require('../../__tests__/fixtures/workspace-fixtures.cjs');
const {
  BUILD_FILES,
  DEFAULT_ROLE_DIRS,
  COMPONENT_ROLE_DIRS,
  VENDORED_PREFIXES,
  monorepoSignals,
  roleDirComponents,
  nestedRepos,
  parseGitmodules,
  classifySubmodule,
  detectRepoShape,
} = require('../repo-shape-detector.cjs');

const FILE_SIGNALS = ['go.work', 'Cargo.toml [workspace]', 'pyproject.toml [tool.uv.workspace]', 'nx.json', 'turbo.json', 'MODULE.bazel'];
const ROLE_DIRS = 'services/+apps/';
const SIGNAL_NAMES = [...FILE_SIGNALS, ROLE_DIRS];

function plainDir(t, files = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-shape-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
  return dir;
}

const ACME = 'https://github.com/acme';

describe('repo-shape-detector', () => {
  describe('constants', () => {
    it('keeps the component role dirs a subset of the default role dirs', () => {
      assert.deepStrictEqual(DEFAULT_ROLE_DIRS, ['services', 'apps', 'contracts', 'infra']);
      for (const dir of COMPONENT_ROLE_DIRS) assert.ok(DEFAULT_ROLE_DIRS.includes(dir), dir);
      assert.ok(BUILD_FILES.includes('foundry.toml'));
      assert.deepStrictEqual(VENDORED_PREFIXES, ['lib/', 'vendor/', 'external/']);
    });
  });

  describe('monorepo signals', () => {
    for (const signal of SIGNAL_NAMES) {
      it(`reports ${signal} alone as a monorepo`, (t) => {
        const { root } = makePolyglotMonorepo(t, { omit: SIGNAL_NAMES.filter(s => s !== signal) });
        assert.deepStrictEqual(monorepoSignals(root), [signal]);
        const shape = detectRepoShape(root);
        assert.strictEqual(shape.type, 'monorepo');
        assert.deepStrictEqual(shape.signals, [signal]);
      });
    }

    it('reports every signal on the full fixture', (t) => {
      const { root } = makePolyglotMonorepo(t);
      assert.deepStrictEqual(monorepoSignals(root).sort(), [...SIGNAL_NAMES].sort());
    });

    it('reports none when all are omitted', (t) => {
      const { root } = makePolyglotMonorepo(t, { omit: SIGNAL_NAMES });
      assert.deepStrictEqual(detectRepoShape(root).signals, []);
      assert.strictEqual(detectRepoShape(root).type, 'single-repo');
    });

    const plain = {
      'pnpm-workspace.yaml': { 'pnpm-workspace.yaml': 'packages:\n  - packages/*\n' },
      'lerna.json': { 'lerna.json': '{}' },
      'package.json workspaces': { 'package.json': JSON.stringify({ workspaces: ['packages/*'] }) },
      WORKSPACE: { WORKSPACE: '' },
      'WORKSPACE.bazel': { 'WORKSPACE.bazel': '' },
    };
    for (const [signal, files] of Object.entries(plain)) {
      it(`reports ${signal}`, (t) => {
        const root = plainDir(t, files);
        assert.deepStrictEqual(monorepoSignals(root), [signal]);
        assert.strictEqual(detectRepoShape(root).type, 'monorepo');
      });
    }

    it('matches [workspace] and [tool.uv.workspace] only as whole table headers', (t) => {
      const root = plainDir(t, {
        'Cargo.toml': '# [workspace]\n[package]\nname = "x"\n\n[workspace.dependencies]\nserde = "1"\n',
        'pyproject.toml': '[tool.uv.workspace.extra]\nmembers = []\n',
      });
      assert.deepStrictEqual(monorepoSignals(root), []);
      fs.writeFileSync(path.join(root, 'Cargo.toml'), '[package]\nname = "x"\n\n  [workspace]  \nmembers = ["a"]\n');
      assert.deepStrictEqual(monorepoSignals(root), ['Cargo.toml [workspace]']);
    });

    it('ignores a broken package.json', (t) => {
      const root = plainDir(t, { 'package.json': '{not json' });
      assert.strictEqual(detectRepoShape(root).type, 'single-repo');
    });
  });

  describe('role dirs', () => {
    it('does not call a single app with infra/ or contracts/ build files a monorepo', (t) => {
      const root = plainDir(t, {
        'package.json': JSON.stringify({ name: 'app' }),
        'infra/terraform/requirements.txt': '',
        'infra/ansible/pyproject.toml': '',
        'contracts/token/foundry.toml': '',
        'contracts/vault/foundry.toml': '',
      });
      assert.deepStrictEqual(roleDirComponents(root), []);
      assert.strictEqual(detectRepoShape(root).type, 'single-repo');
    });

    it('needs two components under services/ and apps/', (t) => {
      const one = plainDir(t, { 'services/api/package.json': '{}' });
      assert.deepStrictEqual(roleDirComponents(one), ['services/api']);
      assert.strictEqual(detectRepoShape(one).type, 'single-repo');

      const two = plainDir(t, { 'services/api/go.mod': '', 'apps/web/package.json': '{}' });
      assert.deepStrictEqual(roleDirComponents(two).sort(), ['apps/web', 'services/api']);
      assert.strictEqual(detectRepoShape(two).type, 'monorepo');
    });

    it('ignores subdirectories without a build file, files and dot directories', (t) => {
      const root = plainDir(t, { 'services/notes/README.md': '', 'services/.cache/go.mod': '', 'services/loose.txt': '', 'services/api/go.mod': '' });
      assert.deepStrictEqual(roleDirComponents(root), ['services/api']);
    });

    it('finds repos under custom role dirs only when the caller lists them', (t) => {
      const root = plainDir(t, { 'bots/trader/README.md': '', 'services/api/go.mod': '' });
      fs.mkdirSync(path.join(root, 'bots', 'trader', '.git'));
      assert.deepStrictEqual(nestedRepos(root, ['bots']), ['bots/trader']);
      assert.deepStrictEqual(nestedRepos(root), []);
    });

    it('treats a .git file (worktree or submodule) as a nested repo', (t) => {
      const root = plainDir(t, { 'services/api/.git': 'gitdir: ../../.git/modules/api\n', 'services/api/go.mod': '' });
      assert.deepStrictEqual(nestedRepos(root), ['services/api']);
      assert.deepStrictEqual(roleDirComponents(root), []);
    });

    it('ignores unsafe role dir entries', (t) => {
      const root = plainDir(t, { 'x/y/README.md': '' });
      fs.mkdirSync(path.join(root, 'x', 'y', '.git'));
      assert.deepStrictEqual(nestedRepos(path.join(root, 'x'), ['..', '../x', path.join(root, 'x'), '', 7, null]), []);
      assert.deepStrictEqual(nestedRepos(root, ['x']), ['x/y']);
    });
  });

  describe('workspace shape', () => {
    it('excludes nested repos from the component count and hints at a workspace without a manifest', (t) => {
      const { root, members } = makeTcxWorkspace(t);
      assert.deepStrictEqual(roleDirComponents(root), []);
      const shape = detectRepoShape(root);
      assert.strictEqual(shape.type, 'single-repo');
      assert.strictEqual(shape.hint, 'workspace-candidate');
      assert.deepStrictEqual(shape.nestedRepos.sort(), Object.values(members).map(dir => path.relative(root, dir)).sort());
    });

    it('returns workspace when adf-workspace.json exists', (t) => {
      const { root } = makeTcxWorkspace(t, { manifest: { version: 1, members: [] } });
      const shape = detectRepoShape(root);
      assert.strictEqual(shape.type, 'workspace');
      assert.strictEqual(shape.hint, null);
      assert.strictEqual(shape.nestedRepos.length, 8);
    });

    it('does not hint at a workspace for one nested repo', (t) => {
      const root = plainDir(t, { 'services/api/go.mod': '' });
      fs.mkdirSync(path.join(root, 'services', 'api', '.git'));
      assert.strictEqual(detectRepoShape(root).hint, null);
    });
  });

  describe('submodules', () => {
    it('parses name, path and url per section', () => {
      const text = [
        '[submodule "src/protos"]', '\tpath = src/protos', `\turl = ${ACME}/tcx-proto.git`,
        '# comment', '[submodule "lib/forge-std"]', '  path = lib/forge-std', '  url = "https://github.com/foundry-rs/forge-std"', '\tbranch = v1',
        '[submodule "broken"]', '\tpath = only/path',
      ].join('\r\n');
      assert.deepStrictEqual(parseGitmodules(text), [
        { name: 'src/protos', path: 'src/protos', url: `${ACME}/tcx-proto.git` },
        { name: 'lib/forge-std', path: 'lib/forge-std', url: 'https://github.com/foundry-rs/forge-std' },
      ]);
      assert.deepStrictEqual(parseGitmodules(''), []);
      assert.deepStrictEqual(parseGitmodules(undefined), []);
    });

    it('reads keys case-insensitively and drops inline comments', () => {
      const text = ['[submodule "x"]', '  Path = vendor/x', '  URL = https://github.com/o/x ; mirror', '[submodule "y"]', '  path = lib/y', '  url = "https://github.com/o/y # not a comment"'].join('\n');
      assert.deepStrictEqual(parseGitmodules(text), [
        { name: 'x', path: 'vendor/x', url: 'https://github.com/o/x' },
        { name: 'y', path: 'lib/y', url: 'https://github.com/o/y # not a comment' },
      ]);
    });

    it('fails open on a missing root', () => {
      assert.strictEqual(detectRepoShape(undefined).type, detectRepoShape(process.cwd()).type);
    });

    it('classifies against several owners', () => {
      const orgs = ['acme', 'client-co'];
      assert.strictEqual(classifySubmodule({ path: 'src/a', url: 'https://github.com/client-co/x.git' }, orgs), 'sibling');
      assert.strictEqual(classifySubmodule({ path: 'src/a', url: 'git@github.com:Acme/x.git' }, orgs), 'sibling');
      assert.strictEqual(classifySubmodule({ path: 'src/b', url: 'https://github.com/other/x.git' }, orgs), 'vendored');
    });

    it('treats vendored prefixes as vendored even for an owner in the list', () => {
      for (const p of ['lib/x', 'vendor/x', 'external/x', './lib/x']) {
        assert.strictEqual(classifySubmodule({ path: p, url: `${ACME}/x.git` }, ['acme']), 'vendored', p);
      }
      assert.strictEqual(classifySubmodule({ path: 'library/x', url: `${ACME}/x.git` }, ['acme']), 'sibling');
    });

    it('treats a relative url as a sibling and an unparseable one as vendored when owners are known', () => {
      assert.strictEqual(classifySubmodule({ path: 'src/a', url: '../tcx-proto.git' }, ['acme']), 'sibling');
      assert.strictEqual(classifySubmodule({ path: 'src/a', url: './tcx-proto' }, null), 'sibling');
      assert.strictEqual(classifySubmodule({ path: 'src/a', url: '/srv/git/x.git' }, ['acme']), 'vendored');
    });

    it('falls back to the path rule only when owners are unknown', () => {
      assert.strictEqual(classifySubmodule({ path: 'src/a', url: 'https://github.com/other/x.git' }, null), 'sibling');
      assert.strictEqual(classifySubmodule({ path: 'src/a', url: 'https://github.com/other/x.git' }, []), 'sibling');
      assert.strictEqual(classifySubmodule({ path: 'lib/a', url: 'https://github.com/other/x.git' }, null), 'vendored');
    });

    it('returns superproject for an in-org src/protos submodule, owner taken from origin', (t) => {
      const { root } = makeSuperproject(t, { originUrl: `${ACME}/app.git`, submodules: [{ path: 'src/protos', url: `${ACME}/tcx-proto.git` }] });
      const shape = detectRepoShape(root);
      assert.strictEqual(shape.type, 'superproject');
      assert.deepStrictEqual(shape.submodules, [{ name: 'src/protos', path: 'src/protos', url: `${ACME}/tcx-proto.git`, kind: 'sibling' }]);
      assert.strictEqual(shape.orgUnknown, false);
    });

    it('uses the origin owner as the only entry when no owners are passed', (t) => {
      const { root } = makeSuperproject(t, {
        originUrl: `${ACME}/app.git`,
        submodules: [{ path: 'src/a', url: 'https://github.com/client-co/a.git' }, { path: 'src/b', url: `${ACME}/b.git` }],
      });
      const kinds = Object.fromEntries(detectRepoShape(root).submodules.map(s => [s.path, s.kind]));
      assert.deepStrictEqual(kinds, { 'src/a': 'vendored', 'src/b': 'sibling' });
    });

    it('lets passed owners replace the origin owner', (t) => {
      const { root } = makeSuperproject(t, {
        originUrl: `${ACME}/app.git`,
        submodules: [{ path: 'src/a', url: 'https://github.com/client-co/a.git' }, { path: 'src/c', url: 'https://github.com/other/c.git' }],
      });
      const kinds = Object.fromEntries(detectRepoShape(root, { orgs: ['acme', 'client-co'] }).submodules.map(s => [s.path, s.kind]));
      assert.deepStrictEqual(kinds, { 'src/a': 'sibling', 'src/c': 'vendored' });
    });

    it('leaves a repo with only lib/forge-std single-repo and lists it as vendored', (t) => {
      const { root } = makeSuperproject(t, { originUrl: `${ACME}/contracts.git`, submodules: [{ path: 'lib/forge-std', url: 'https://github.com/foundry-rs/forge-std' }] });
      const shape = detectRepoShape(root);
      assert.strictEqual(shape.type, 'single-repo');
      assert.deepStrictEqual(shape.submodules.map(s => [s.path, s.kind]), [['lib/forge-std', 'vendored']]);
    });

    it('calls lib/x vendored even when it is owned by the org', (t) => {
      const { root } = makeSuperproject(t, { originUrl: `${ACME}/app.git`, submodules: [{ path: 'lib/x', url: `${ACME}/x.git` }] });
      const shape = detectRepoShape(root);
      assert.strictEqual(shape.submodules[0].kind, 'vendored');
      assert.strictEqual(shape.type, 'single-repo');
    });

    it('calls a relative url a sibling', (t) => {
      const { root } = makeSuperproject(t, { originUrl: `${ACME}/app.git`, submodules: [{ path: 'src/protos', url: '../tcx-proto.git' }] });
      const shape = detectRepoShape(root);
      assert.strictEqual(shape.submodules[0].kind, 'sibling');
      assert.strictEqual(shape.type, 'superproject');
    });

    it('classifies by path only and flags orgUnknown without owners or an origin', (t) => {
      const { root } = makeSuperproject(t, {
        submodules: [{ path: 'src/a', url: 'https://github.com/other/a.git' }, { path: 'lib/b', url: 'https://github.com/other/b.git' }],
      });
      const shape = detectRepoShape(root);
      assert.strictEqual(shape.orgUnknown, true);
      assert.deepStrictEqual(shape.submodules.map(s => s.kind), ['sibling', 'vendored']);
      assert.strictEqual(shape.type, 'superproject');
    });

    it('never returns credentials from a submodule url', (t) => {
      const { root } = makeSuperproject(t, { originUrl: `${ACME}/app.git`, submodules: [{ path: 'src/a', url: 'https://user:secret@github.com/acme/a.git' }] }); // adf-allow-secret
      const shape = detectRepoShape(root);
      assert.strictEqual(shape.submodules[0].url, `${ACME}/a.git`);
      assert.ok(!JSON.stringify(shape).includes('secret'));
    });

    it('does not set orgUnknown without submodules', (t) => {
      assert.strictEqual(detectRepoShape(plainDir(t)).orgUnknown, false);
    });
  });

  describe('type precedence and fallbacks', () => {
    it('returns library for a package.json main or exports', (t) => {
      assert.strictEqual(detectRepoShape(plainDir(t, { 'package.json': JSON.stringify({ main: 'index.js' }) })).type, 'library');
      assert.strictEqual(detectRepoShape(plainDir(t, { 'package.json': JSON.stringify({ exports: './index.js' }) })).type, 'library');
    });

    it('ranks monorepo over superproject and library', (t) => {
      const root = plainDir(t, { 'turbo.json': '{}', 'package.json': JSON.stringify({ main: 'index.js' }), '.gitmodules': `[submodule "a"]\n\tpath = src/a\n\turl = ../a.git\n` });
      assert.strictEqual(detectRepoShape(root).type, 'monorepo');
    });

    it('ranks a manifest over everything', (t) => {
      const root = plainDir(t, { 'adf-workspace.json': '{}', 'turbo.json': '{}' });
      assert.strictEqual(detectRepoShape(root).type, 'workspace');
    });

    it('returns single-repo for an empty directory', (t) => {
      assert.deepStrictEqual(detectRepoShape(plainDir(t)), { type: 'single-repo', signals: [], submodules: [], nestedRepos: [], hint: null, orgUnknown: false });
    });

    it('fails open on a missing root', () => {
      const shape = detectRepoShape(path.join(os.tmpdir(), 'adf-shape-does-not-exist-xyz'));
      assert.strictEqual(shape.type, 'single-repo');
      assert.deepStrictEqual(shape.signals, []);
    });

    it('does not walk into component directories', (t) => {
      const root = plainDir(t, { 'services/api/go.mod': '', 'services/web/package.json': '{}', 'services/api/deep/er/go.work': '' });
      assert.deepStrictEqual(monorepoSignals(root), [ROLE_DIRS]);
    });
  });
});
