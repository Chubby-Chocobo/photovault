#!/usr/bin/env node
/**
 * Tests for contract-pin-readers.cjs
 * Run: node --test .claude/hooks/lib/__tests__/contract-pin-readers.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { makeTcxWorkspace, makeSuperproject } = require('../../__tests__/fixtures/workspace-fixtures.cjs');
const { classifyNpmRef, parseCargoGitDeps, readPins, readCargoPins, readNpmPins, readSubmodulePins } = require('../contract-pin-readers.cjs');

const SHA = 'a'.repeat(40);
const dirWith = (t, files) => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'adf-pins-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const [name, content] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), content);
  return dir;
};

describe('submodule pins', () => {
  it('reads the gitlink sha of each consumer from the index', (t) => {
    const ws = makeTcxWorkspace(t);
    const pinOf = (name) => readSubmodulePins(ws.members[name]).pins[0];
    assert.strictEqual(pinOf('order').ref, ws.protoCommits[1]);
    assert.strictEqual(pinOf('gateway').ref, ws.protoCommits[2]);
    assert.strictEqual(pinOf('core').ref, ws.protoCommits[0]);
    assert.deepStrictEqual(
      { source: pinOf('core').source, path: pinOf('core').path, pinned: pinOf('core').pinned, refKind: pinOf('core').refKind, url: pinOf('core').url },
      { source: 'submodule', path: 'src/protos', pinned: true, refKind: 'commit', url: 'https://github.com/acme/tcx-proto.git' },
    );
  });

  it('flags and strips a credential in a .gitmodules URL', (t) => {
    const token = `${'ghp_'}${'B'.repeat(36)}`;
    const { root } = makeSuperproject(t, { submodules: [{ path: 'lib/proto', url: `https://${token}@github.com/acme/proto.git` }] });
    const [pin] = readSubmodulePins(root).pins;
    assert.strictEqual(pin.credentialInUrl, true);
    assert.ok(!JSON.stringify(pin).includes(token));
    assert.strictEqual(pin.url, 'https://github.com/acme/proto.git');
  });

  it('reports a declared submodule without a gitlink as unpinned and a missing HEAD as unreadable', (t) => {
    const noLink = dirWith(t, { '.gitmodules': '[submodule "x"]\n\tpath = x\n\turl = https://github.com/acme/x.git\n' });
    require('node:child_process').spawnSync('git', ['init', '--quiet'], { cwd: noLink });
    assert.deepStrictEqual(readSubmodulePins(noLink), { pins: [], unreadable: [{ file: '.gitmodules' }] }); // no commits yet
    const { root } = makeSuperproject(t, { submodules: [{ path: 'a', url: 'https://github.com/acme/a.git' }] });
    fs.appendFileSync(path.join(root, '.gitmodules'), '[submodule "b"]\n\tpath = b\n\turl = https://github.com/acme/b.git\n');
    const byPath = Object.fromEntries(readSubmodulePins(root).pins.map((p) => [p.path, p]));
    assert.strictEqual(byPath.a.pinned, true);
    assert.deepStrictEqual([byPath.b.pinned, byPath.b.reason], [false, 'none']);
  });
});

describe('cargo pins', () => {
  it('reads inline tables and [dependencies.<name>] tables with tag, rev and branch', () => {
    const { pins, badLines } = parseCargoGitDeps([
      '[package]', 'name = "x"', '',
      '[dependencies]',
      'serde = "1"',
      'a = { git = "https://github.com/acme/a", tag = "v1.0.0" }',
      'b = { git = "https://github.com/acme/b.git", rev = "abc1234" } # pinned',
      'c = { git = "https://github.com/acme/c", branch = "main" }',
      'd = { git = "https://github.com/acme/d" }',
      '[dependencies.e]', 'git = "https://github.com/acme/e"', 'tag = "v2.0.0"', 'features = ["x"]',
      '[dev-dependencies]', 'f = { git = "https://github.com/acme/f", tag = "v3" }',
      '[workspace.dependencies]', 'g = { git = "ssh://git@github.com/acme/g.git", rev = "deadbeef" }',
      "[target.'cfg(unix)'.dependencies]", 'h = { git = "https://github.com/acme/h", tag = "v4" }',
      '[features]', 'z = { git = "https://github.com/acme/never", tag = "v9" }',
    ].join('\n'));
    assert.deepStrictEqual(badLines, []);
    const byName = Object.fromEntries(pins.map((p) => [p.name, p]));
    assert.deepStrictEqual(Object.keys(byName), ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']);
    assert.deepStrictEqual([byName.a.ref, byName.a.pinned], ['v1.0.0', true]);
    assert.deepStrictEqual([byName.b.ref, byName.b.refKind, byName.b.pinned], ['abc1234', 'commit', true]);
    assert.deepStrictEqual([byName.c.pinned, byName.c.reason], [false, 'branch']);
    assert.deepStrictEqual([byName.d.pinned, byName.d.reason], [false, 'none']);
    assert.deepStrictEqual([byName.e.ref, byName.e.pinned], ['v2.0.0', true]);
    assert.strictEqual(byName.g.url, 'ssh://git@github.com/acme/g.git');
  });

  it('strips a credential from a Cargo git URL and flags it', (t) => {
    const ws = makeTcxWorkspace(t, { credentialUrl: true });
    const { pins } = readCargoPins(ws.members.market);
    assert.strictEqual(pins[0].credentialInUrl, true);
    assert.strictEqual(pins[0].url, 'https://github.com/acme/vdax-libs');
    assert.ok(!JSON.stringify(pins).includes(ws.token));
    const trading = readCargoPins(ws.members.trading).pins[0];
    assert.deepStrictEqual([trading.ref, trading.credentialInUrl], ['v1.0.109.1', false]);
  });

  it('marks malformed lines unreadable without throwing or echoing content', (t) => {
    const dir = dirWith(t, { 'Cargo.toml': '[dependencies\nfoo = { git = "https://x:ghp_SECRET@github.com/acme/f", tag = "v1"\n[dependencies]\nbar = { git = "https://github.com/acme/bar",\n' }); // adf-allow-secret
    const result = readCargoPins(dir);
    assert.ok(result.unreadable.length >= 2);
    assert.ok(result.unreadable.every((u) => u.file === 'Cargo.toml' && Number.isInteger(u.line)));
    assert.ok(!JSON.stringify(result).includes('SECRET'));
    assert.deepStrictEqual(readCargoPins(dirWith(t, {})), { pins: [], unreadable: [] });
  });
});

describe('npm pins', () => {
  it('classifies git forms by their ref', () => {
    const cases = [
      ['git+https://github.com/acme/wormhole-sdk.git#master', 'branch', false],
      ['github:acme/ui-kit', 'none', false],
      ['acme/ui-kit#main', 'branch', false],
      ['git+https://github.com/acme/charts.git#v1.2.0', null, true],
      [`git://github.com/acme/x.git#${SHA}`, null, true],
      ['git+ssh://git@github.com/acme/x.git#1.4.0', null, true],
      ['https://gitlab.com/group/sub/x.git#develop', 'branch', false],
      ['bitbucket:acme/x#HEAD', 'branch', false],
      ['github:acme/x#semver:^1.2', 'range', false],
    ];
    for (const [spec, reason, pinned] of cases) {
      const found = classifyNpmRef(spec);
      assert.ok(found, spec);
      assert.deepStrictEqual([found.pinned, found.reason || null], [pinned, reason], spec);
    }
    assert.strictEqual(classifyNpmRef(`git://github.com/acme/x.git#${SHA}`).refKind, 'commit');
  });

  it('ignores registry ranges, aliases, local paths, tarballs and non-strings', () => {
    for (const spec of ['^3.4.0', '~1.2', '*', 'latest', '1.x', '>=1 <2', 'npm:other@^1', 'workspace:*', 'file:../x', 'link:../x', './x', '../x',
      'https://example.com/pkg.tgz', 'https://registry.example.com/x-1.0.0.tar.gz', 'https://example.com/pkg.tgz?token=1', 'https://github.com/acme/x/tarball/main', 'https://codeload.github.com/acme/x/zipball/v1.0.0', '', 7, null, {}]) {
      assert.strictEqual(classifyNpmRef(spec), null, String(spec));
    }
  });

  it('strips a credential from an npm git URL', () => {
    const found = classifyNpmRef('git+https://x-access-token:ghp_SECRETSECRET@github.com/acme/x.git#v1.0.0'); // adf-allow-secret
    assert.deepStrictEqual([found.credentialInUrl, found.url], [true, 'git+https://github.com/acme/x.git']);
  });

  it('reads all four dependency sections of the admin-web fixture', (t) => {
    const ws = makeTcxWorkspace(t);
    const byName = Object.fromEntries(readNpmPins(ws.members['admin-web']).pins.map((p) => [p.name, p]));
    assert.deepStrictEqual(Object.keys(byName).sort(), ['charts', 'ui-kit', 'wormhole-sdk']);
    assert.deepStrictEqual([byName['wormhole-sdk'].reason, byName['ui-kit'].reason, byName.charts.pinned], ['branch', 'none', true]);
    const dir = dirWith(t, { 'package.json': JSON.stringify({ devDependencies: { a: 'github:acme/a#v1.0.0' }, optionalDependencies: { b: 'github:acme/b' }, peerDependencies: { c: 'github:acme/c#main' } }) });
    assert.deepStrictEqual(readNpmPins(dir).pins.map((p) => p.name), ['a', 'b', 'c']);
  });

  it('marks malformed package.json unreadable without echoing content', (t) => {
    for (const text of ['{ "dependencies": { "x": "git+https://ghp_SECRET@github.com/a/b" ', '[]', 'null']) { // adf-allow-secret
      const result = readNpmPins(dirWith(t, { 'package.json': text }));
      assert.deepStrictEqual(result, { pins: [], unreadable: [{ file: 'package.json' }] });
    }
  });
});

describe('readPins', () => {
  it('combines the three sources and tolerates a directory with none', (t) => {
    const ws = makeTcxWorkspace(t);
    assert.deepStrictEqual(readPins(ws.members.core).pins.map((p) => p.source), ['submodule']);
    assert.deepStrictEqual(readPins(ws.members['matching-engine']), { pins: [], unreadable: [] });
    assert.deepStrictEqual(readPins(path.join(ws.root, 'does-not-exist')), { pins: [], unreadable: [] });
  });
});

describe('hostile input', () => {
  const timed = (fn) => { const start = process.hrtime.bigint(); const result = fn(); return { result, ms: Number(process.hrtime.bigint() - start) / 1e6 }; };
  const MIB = 1 << 20;

  it('parses a 1 MiB single-token Cargo.toml line in linear time and marks the line unreadable', () => {
    for (const body of ['[dependencies]\n', '[dependencies.x]\n']) {
      const { result, ms } = timed(() => parseCargoGitDeps(`${body}${'a'.repeat(MIB)} = {\n${'b'.repeat(MIB)}\ngit = "https://github.com/acme/ok", tag = "v1"\n`));
      assert.ok(ms < 200, `${ms} ms`);
      assert.deepStrictEqual(result.badLines.slice(0, 2), [2, 3]);
    }
    const { result, ms } = timed(() => parseCargoGitDeps(`[dependencies]\nx = { ${'git '.repeat(MIB / 4)} }\n`));
    assert.ok(ms < 200, `${ms} ms`);
    assert.strictEqual(result.pins.length, 0);
  });

  it('reads a file whose only long line is skipped, keeping the good dependencies', (t) => {
    const dir = dirWith(t, { 'Cargo.toml': `[dependencies]\na = { git = "https://github.com/acme/a", tag = "v1" }\n${'z'.repeat(1000000)}\n` });
    const { result, ms } = timed(() => readCargoPins(dir));
    assert.ok(ms < 200, `${ms} ms`);
    assert.deepStrictEqual(result.pins.map((p) => p.name), ['a']);
    assert.deepStrictEqual(result.unreadable, [{ file: 'Cargo.toml', line: 3 }]);
  });

  it('classifies 1 MiB npm specs quickly and as not git', () => {
    for (const spec of ['a'.repeat(MIB), `github:${'a/'.repeat(MIB / 2)}`, '.'.repeat(MIB), `${'?'.repeat(MIB)}`, `https://${'a.'.repeat(MIB / 2)}/x/y`, `${'a'.repeat(MIB)}#v1`]) {
      const { result, ms } = timed(() => classifyNpmRef(spec));
      assert.strictEqual(result, null);
      assert.ok(ms < 200, `${ms} ms`);
    }
  });

  it('reads package.json and .gitmodules with 1 MiB-class lines quickly', (t) => {
    const dir = dirWith(t, {
      'package.json': JSON.stringify({ dependencies: { a: 'x'.repeat(1000000), b: 'github:acme/b#v1.0.0' } }),
      '.gitmodules': `[submodule "x"]\n\tpath = x\n\turl = a${' '.repeat(1000000)}b\n`,
    });
    const npm = timed(() => readNpmPins(dir));
    assert.ok(npm.ms < 200, `${npm.ms} ms`);
    assert.deepStrictEqual(npm.result.pins.map((p) => p.name), ['b']);
    const sub = timed(() => readSubmodulePins(dir));
    assert.ok(sub.ms < 200, `${sub.ms} ms`);
    assert.deepStrictEqual(sub.result, { pins: [], unreadable: [{ file: '.gitmodules', line: 3 }] });
  });
});
