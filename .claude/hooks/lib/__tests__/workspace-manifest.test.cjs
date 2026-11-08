#!/usr/bin/env node
/**
 * Tests for workspace-manifest.cjs and workspace-manifest-validate.cjs
 * Run: node --test .claude/hooks/lib/__tests__/workspace-manifest.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { makeTcxWorkspace } = require('../../__tests__/fixtures/workspace-fixtures.cjs');
const { DEFAULT_ROLE_DIRS } = require('../repo-shape-detector.cjs');
const {
  MANIFEST_FILE, roleDirsOf, findWorkspaceRoot, loadManifest, validateManifest, memberForPath, memberState, memberPath,
} = require('../workspace-manifest.cjs');

const GIT = { flow: 'off', enforcement: 'ask', mainBranch: 'develop' };
const member = (extra = {}) => ({ name: 'order', path: 'services/order', repo: 'https://github.com/acme/tcx-order.git', branch: 'develop', git: { ...GIT }, ...extra });
const manifest = (extra = {}) => ({ version: 1, client: 'tcx', product: 'tcx', org: ['acme'], repo: 'https://github.com/acme/tcx-workspace', members: [member()], ...extra });

function tmp(t, files = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-manifest-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
  return dir;
}

describe('validateManifest', () => {
  it('accepts the documented example', () => {
    const { errors } = validateManifest(manifest({ roleDirs: ['services', 'apps', 'contracts', 'infra'] }));
    assert.deepStrictEqual(errors, []);
  });

  const rejects = [
    ['a non-object', null, 'JSON object'],
    ['version 2', manifest({ version: 2 }), 'version must be 1'],
    ['an uppercase client', manifest({ client: 'TCX' }), 'client must match'],
    ['a product with a slash', manifest({ product: 'a/b' }), 'product must match'],
    ['org as a string', manifest({ org: 'acme' }), 'org must be a non-empty array'],
    ['an empty org', manifest({ org: [] }), 'org must be a non-empty array'],
    ['a missing org', (() => { const m = manifest(); delete m.org; return m; })(), 'org must be a non-empty array'],
    ['an invalid owner', manifest({ org: ['acme', 'a b'] }), 'org[1] must be an owner name'],
    ['a duplicate owner', manifest({ org: ['acme', 'ACME'] }), 'org[1] duplicates'],
    ['a non-canonical top-level repo', manifest({ repo: 'git@github.com:acme/tcx-workspace.git' }), 'repo must be a canonical https URL'],
    ['members as an object', manifest({ members: {} }), 'members must be an array'],
    ['a bad member name', manifest({ members: [member({ name: 'Order' })] }), 'members[0].name must match'],
    ['a duplicate member name', manifest({ members: [member(), member({ path: 'services/other' })] }), 'duplicates an earlier member'],
    ['a duplicate member path', manifest({ members: [member(), member({ name: 'other' })] }), 'path duplicates'],
    ['a path with ..', manifest({ members: [member({ path: 'services/..' })] }), '".." segments'],
    ['a path with a leading slash', manifest({ members: [member({ path: '/services/order' })] }), 'relative posix path'],
    ['a path with backslashes', manifest({ members: [member({ path: 'services\\order' })] }), 'relative posix path'],
    ['a nested path', manifest({ members: [member({ path: 'services/a/b' })] }), 'exactly <roleDir>/<dir>'],
    ['a path outside the role dirs', manifest({ members: [member({ path: 'lib/x' })] }), 'one of roleDirs'],
    ['a repo starting with a dash', manifest({ members: [member({ repo: '--upload-pack=x' })] }), 'must not start with "-"'],
    ['a repo that is not a URL', manifest({ members: [member({ repo: 'order' })] }), 'remote git URL'],
    ['a branch starting with a dash', manifest({ members: [member({ branch: '-x' })] }), 'branch must be a branch name'],
    ['a branch with ..', manifest({ members: [member({ branch: 'a..b' })] }), 'branch must be a branch name'],
    ['a missing git object', manifest({ members: [member({ git: undefined })] }), 'git is required'],
    ['a bad git flow', manifest({ members: [member({ git: { ...GIT, flow: 'gitflow' } })] }), 'git.flow must be one of release-train|trunk|off'],
    ['a bad git enforcement', manifest({ members: [member({ git: { ...GIT, enforcement: 'block' } })] }), 'git.enforcement must be one of off|ask|deny'],
    ['a bad mainBranch', manifest({ members: [member({ git: { ...GIT, mainBranch: '-main' } })] }), 'git.mainBranch must be a branch name'],
  ];
  for (const [label, input, message] of rejects) {
    it(`rejects ${label}`, () => {
      const { errors } = validateManifest(input);
      assert.ok(errors.some((e) => e.includes(message)), `expected "${message}" in ${JSON.stringify(errors)}`);
    });
  }

  it('rejects credentials in a member repo without echoing them', () => {
    const token = `${'ghp_'}${'B'.repeat(36)}`;
    for (const repo of [`https://${token}@github.com/acme/x.git`, `https://user:${token}@github.com/acme/x.git`, `ssh://git:${token}@github.com/acme/x.git`, `user:${token}@github.com:acme/x.git`]) {
      const { errors, warnings } = validateManifest(manifest({ members: [member({ repo })] }));
      assert.ok(errors.some((e) => e.includes('credentials')), repo.replace(token, '***'));
      assert.ok(![...errors, ...warnings].join('\n').includes(token));
    }
  });

  it('accepts ssh, scp, file:// and absolute-path repos (local ones warn)', () => {
    for (const repo of ['git@github.com:acme/tcx-order.git', 'ssh://git@github.com/acme/tcx-order.git', 'file:///tmp/mirror/order', '/tmp/mirror/order']) {
      const { errors, warnings } = validateManifest(manifest({ members: [member({ repo })] }));
      assert.deepStrictEqual(errors, [], repo);
      assert.strictEqual(warnings.some((w) => w.includes('is local')), !/github/.test(repo), repo);
    }
  });

  it('warns about a member without a repo', () => {
    const { errors, warnings } = validateManifest(manifest({ members: [member({ repo: undefined })] }));
    assert.deepStrictEqual(errors, []);
    assert.ok(warnings.some((w) => w.includes('no repo')));
  });

  it('warns, not errors, on unknown keys', () => {
    const input = manifest({ extra: 1, members: [member({ owner: 'x', git: { ...GIT, hooks: true } })] });
    const { errors, warnings } = validateManifest(input);
    assert.deepStrictEqual(errors, []);
    assert.strictEqual(warnings.length, 3);
  });

  describe('roleDirs', () => {
    it('accepts a custom list and a member under it', () => {
      const input = manifest({ roleDirs: ['services', 'bots'], members: [member({ name: 'telegram', path: 'bots/telegram' })] });
      assert.deepStrictEqual(validateManifest(input).errors, []);
    });

    it('rejects a path whose role dir is not listed', () => {
      const input = manifest({ roleDirs: ['services'], members: [member({ name: 'web', path: 'apps/web' })] });
      assert.ok(validateManifest(input).errors.some((e) => e.includes('one of roleDirs')));
    });

    it('rejects invalid role dir names', () => {
      for (const bad of ['Bots', '../x', 'a/b', '', '1x', 'docs', 'worktrees']) {
        const { errors } = validateManifest(manifest({ roleDirs: ['services', bad], members: [] }));
        assert.ok(errors.some((e) => e.startsWith('roleDirs[1]')), `"${bad}" should be rejected`);
      }
    });

    it('never echoes an invalid role dir or an unsafe key name in a message', () => {
      const evil = '../evil<script>';
      const { errors, warnings } = validateManifest(manifest({ roleDirs: ['services', evil], members: [member({ path: 'apps/x' })], [evil]: 1, 'tok-ghp_ABC<>': 1 }));
      const text = [...errors, ...warnings].join('\n');
      assert.ok(errors.some((e) => e.includes('one of roleDirs (services)')), text);
      assert.ok(!text.includes('evil') && !text.includes('<'), text);
      assert.ok(warnings.some((w) => w.includes('unknown key (name not shown)')));
      assert.ok(validateManifest(manifest({ extra: 1 })).warnings.some((w) => w.includes('"extra"')));
    });

    it('rejects duplicates, an empty list and a non-array', () => {
      assert.ok(validateManifest(manifest({ roleDirs: ['services', 'services'] })).errors.some((e) => e.includes('duplicates')));
      assert.ok(validateManifest(manifest({ roleDirs: [] })).errors.some((e) => e.includes('non-empty array')));
      assert.ok(validateManifest(manifest({ roleDirs: 'services' })).errors.some((e) => e.includes('non-empty array')));
    });

    it('defaults to the four detector role dirs when absent', () => {
      assert.deepStrictEqual(roleDirsOf(manifest()), DEFAULT_ROLE_DIRS);
      assert.deepStrictEqual(roleDirsOf(null), DEFAULT_ROLE_DIRS);
      assert.deepStrictEqual(roleDirsOf({ roleDirs: ['bots'] }), ['bots']);
    });
  });
});

describe('findWorkspaceRoot', () => {
  it('walks up from a member subdirectory that has no .claude', (t) => {
    const { root } = makeTcxWorkspace(t, { manifest: manifest() });
    const deep = path.join(root, 'services', 'order', 'src', 'deep');
    fs.mkdirSync(deep, { recursive: true });
    assert.strictEqual(findWorkspaceRoot(deep), root);
    assert.strictEqual(findWorkspaceRoot(root), root);
  });

  it('returns null without a manifest', (t) => {
    assert.strictEqual(findWorkspaceRoot(tmp(t, { 'a/b/file.txt': '' }) + '/a/b'), null);
  });

  it('stops before $HOME', (t) => {
    const home = tmp(t, { [MANIFEST_FILE]: '{}', 'proj/src/x.txt': '' });
    const saved = { HOME: process.env.HOME, USERPROFILE: process.env.USERPROFILE };
    t.after(() => Object.entries(saved).forEach(([k, v]) => (v === undefined ? delete process.env[k] : (process.env[k] = v))));
    process.env.HOME = home;
    process.env.USERPROFILE = home;
    assert.strictEqual(findWorkspaceRoot(path.join(home, 'proj', 'src')), null);
  });
});

describe('loadManifest', () => {
  it('returns no manifest and no error when the file is absent', (t) => {
    assert.deepStrictEqual(loadManifest(tmp(t)), { manifest: null, errors: [], warnings: [] });
  });

  it('reports invalid JSON as an error instead of throwing', (t) => {
    const { manifest: m, errors } = loadManifest(tmp(t, { [MANIFEST_FILE]: '{ nope' }));
    assert.strictEqual(m, null);
    assert.ok(errors[0].includes('not valid JSON'));
  });

  it('does not quote file content in the invalid JSON error', (t) => {
    const token = `${'ghp_'}${'D'.repeat(36)}`;
    const { errors } = loadManifest(tmp(t, { [MANIFEST_FILE]: `{\n  "repo": "https://${token}@github.com/acme/x" oops }` }));
    assert.ok(errors[0].includes('not valid JSON (line 2)'), errors[0]);
    assert.ok(!errors.join('\n').includes(token));
  });

  it('returns null manifest with the validation errors when invalid', (t) => {
    const { manifest: m, errors } = loadManifest(tmp(t, { [MANIFEST_FILE]: JSON.stringify(manifest({ org: [] })) }));
    assert.strictEqual(m, null);
    assert.ok(errors.some((e) => e.includes('org')));
  });

  it('returns a valid manifest with warnings', (t) => {
    const loaded = loadManifest(tmp(t, { [MANIFEST_FILE]: JSON.stringify(manifest({ extra: true })) }));
    assert.strictEqual(loaded.manifest.product, 'tcx');
    assert.deepStrictEqual(loaded.errors, []);
    assert.strictEqual(loaded.warnings.length, 1);
  });
});

describe('memberForPath', () => {
  const m = { members: [{ path: 'services/a' }, { path: 'services/a/b' }, { path: 'apps/web' }] };

  it('picks the longest matching member path', (t) => {
    const root = tmp(t);
    assert.strictEqual(memberForPath(root, m, path.join(root, 'services/a/b/src/x.ts')).path, 'services/a/b');
    assert.strictEqual(memberForPath(root, m, path.join(root, 'services/a/src/x.ts')).path, 'services/a');
    assert.strictEqual(memberForPath(root, m, path.join(root, 'apps/web')).path, 'apps/web');
  });

  it('does not match a sibling that shares a prefix, or paths outside the root', (t) => {
    const root = tmp(t);
    assert.strictEqual(memberForPath(root, m, path.join(root, 'services/ab/x.ts')), null);
    assert.strictEqual(memberForPath(root, m, path.join(root, 'README.md')), null);
    assert.strictEqual(memberForPath(root, m, path.join(root, '..', 'elsewhere', 'services/a/x')), null);
    assert.strictEqual(memberForPath(root, m, root), null);
  });

  it('matches through a symlinked root and for files that do not exist yet', (t) => {
    const real = tmp(t, { 'services/a/src/x.ts': '' });
    const linkParent = tmp(t);
    const link = path.join(linkParent, 'link');
    fs.symlinkSync(real, link);
    assert.strictEqual(memberForPath(link, m, path.join(real, 'services/a/src/x.ts')).path, 'services/a');
    assert.strictEqual(memberForPath(real, m, path.join(link, 'services/a/src/x.ts')).path, 'services/a');
    assert.strictEqual(memberForPath(link, m, path.join(link, 'services/a/new/file.ts')).path, 'services/a');
  });

  it('returns null for a missing manifest', (t) => {
    assert.strictEqual(memberForPath(tmp(t), null, '/x'), null);
  });
});

describe('memberState', () => {
  const fixture = (t) => makeTcxWorkspace(t, { manifest: manifest() });

  it('cloned: origin matches the manifest repo, in either protocol', (t) => {
    const { root } = fixture(t);
    assert.strictEqual(memberState(root, member()), 'cloned');
    assert.strictEqual(memberState(root, member({ repo: 'git@github.com:acme/tcx-order.git' })), 'cloned');
    assert.strictEqual(memberState(root, member({ repo: undefined })), 'cloned');
  });

  it('missing: the path does not exist', (t) => {
    const { root } = fixture(t);
    assert.strictEqual(memberState(root, member({ name: 'ghost', path: 'services/ghost' })), 'missing');
  });

  it('not-a-repo: a directory without its own .git', (t) => {
    const { root } = fixture(t);
    fs.mkdirSync(path.join(root, 'services', 'plain'));
    assert.strictEqual(memberState(root, member({ name: 'plain', path: 'services/plain' })), 'not-a-repo');
    fs.writeFileSync(path.join(root, 'services', 'afile'), 'x');
    assert.strictEqual(memberState(root, member({ name: 'afile', path: 'services/afile' })), 'not-a-repo');
  });

  it('remote-mismatch: origin is another repo, or absent', (t) => {
    const { root } = fixture(t);
    assert.strictEqual(memberState(root, member({ repo: 'https://github.com/acme/other.git' })), 'remote-mismatch');
    fs.mkdirSync(path.join(root, 'services', 'bare'));
    require('node:child_process').execFileSync('git', ['init', '--quiet', path.join(root, 'services', 'bare')]);
    assert.strictEqual(memberState(root, member({ name: 'bare', path: 'services/bare' })), 'remote-mismatch');
  });

  it('symlink: a symlinked member directory, even to a real repo', (t) => {
    const { root, members } = fixture(t);
    fs.symlinkSync(members.order, path.join(root, 'services', 'linked'));
    assert.strictEqual(memberState(root, member({ name: 'linked', path: 'services/linked' })), 'symlink');
  });

  it('symlink: a role dir that links outside the root', (t) => {
    const { root } = fixture(t);
    const outside = tmp(t, { 'x/.git/HEAD': 'ref: refs/heads/main\n' });
    fs.symlinkSync(outside, path.join(root, 'bots'));
    assert.strictEqual(memberState(root, member({ name: 'x', path: 'bots/x' })), 'symlink');
  });

  it('memberPath joins posix member paths onto the root', (t) => {
    const root = tmp(t);
    assert.strictEqual(memberPath(root, member()), path.join(root, 'services', 'order'));
  });
});
