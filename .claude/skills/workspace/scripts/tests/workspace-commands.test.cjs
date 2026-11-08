#!/usr/bin/env node
/**
 * Tests for the workspace dispatcher and the end-to-end flow
 * Run: node --test .claude/skills/workspace/scripts/tests/workspace-commands.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { makeTcxWorkspace, makePolyglotMonorepo } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { COMMANDS, parseArgs, main } = require('../workspace.cjs');
const { cli, cliJson, editManifest, git, mirrorOf } = require('./workspace-test-helpers.cjs');
const { writePlan, scopeWorkspace } = require('../../../../hooks/lib/__tests__/scope-test-fixtures.cjs');

const SKILL_DIR = path.join(__dirname, '..', '..');
const SCRIPT = path.join(SKILL_DIR, 'scripts', 'workspace.cjs');

describe('dispatcher', () => {
  it('keeps SKILL.md argument-hint in step with COMMANDS', () => {
    const skill = fs.readFileSync(path.join(SKILL_DIR, 'SKILL.md'), 'utf8');
    const hint = /^argument-hint:\s*"([^"]*)"\s*$/m.exec(skill);
    assert.ok(hint, 'argument-hint is present');
    assert.strictEqual(hint[1], COMMANDS.map((c) => c.name).join('|'));
    assert.deepStrictEqual(COMMANDS.slice(0, 11).map((c) => c.name), ['init', 'check', 'bootstrap', 'seed-map', 'scope', 'scaffold', 'drift', 'repos', 'pr-links', 'sync', 'attach']);
    assert.ok(COMMANDS.every((c) => typeof c.run === 'function'));
  });

  it('prints usage and exits 2 for an unknown or missing command', (t) => {
    const { root } = makeTcxWorkspace(t);
    for (const argv of [['frobnicate'], []]) {
      const r = cli(root, argv);
      assert.strictEqual(r.code, 2);
      assert.match(r.err, /Usage: workspace\.cjs <command>/);
    }
  });

  it('rejects a value flag without a value, a value that starts with "-", and a bad --cwd', () => {
    assert.throws(() => parseArgs(['init', '--org']), /--org needs a value/);
    assert.throws(() => parseArgs(['bootstrap', '--only', '--pull']), /--only needs a value/);
    assert.throws(() => parseArgs(['drift', '--fail-on']), /--fail-on needs a value/);
    assert.throws(() => parseArgs(['pr-links', '--branch']), /--branch needs a value/);
    assert.strictEqual(parseArgs(['pr-links', '--branch', 'feat/x', '--write']).branch, 'feat/x');
    const r = spawnSync(process.execPath, [SCRIPT, 'check', '--cwd', '/no/such/dir'], { encoding: 'utf8' });
    assert.strictEqual(r.status, 2);
    assert.match(r.stderr, /--cwd is not a directory/);
  });

  it('--json prints exactly one JSON object and never a credential', (t) => {
    const { root, token } = makeTcxWorkspace(t, { credentialUrl: true });
    for (const argv of [['init', '--dry-run'], ['init', '--yes'], ['check'], ['bootstrap', '--dry-run'], ['seed-map', '--merge', '--dry-run'], ['scaffold', '--dry-run'], ['drift'], ['repos'], ['repos', '--changed'], ['pr-links', '--branch', 'feat/x']]) {
      const r = spawnSync(process.execPath, [SCRIPT, ...argv, '--json', '--cwd', root], { encoding: 'utf8' });
      const lines = r.stdout.trim().split('\n');
      assert.strictEqual(lines.length, 1, `${argv.join(' ')}: ${r.stdout}`);
      assert.ok(!r.stdout.includes(token) && !r.stderr.includes(token), `${argv.join(' ')} leaked the token`);
      const parsed = JSON.parse(lines[0]);
      assert.strictEqual(typeof parsed, 'object');
      assert.ok(!Array.isArray(parsed));
    }
  });

  it('a bootstrap.sh written by init runs the CLI', (t) => {
    if (process.platform === 'win32') return t.skip('sh entry is not used on Windows');
    const { root } = makeTcxWorkspace(t);
    // The script lives in the workspace's own .claude, which the fixture does not have: link ADF's
    fs.mkdirSync(path.join(root, '.claude/skills'), { recursive: true });
    fs.symlinkSync(SKILL_DIR, path.join(root, '.claude/skills/workspace'));
    assert.strictEqual(cli(root, ['init']).code, 0);
    const r = spawnSync(path.join(root, 'bootstrap.sh'), ['--dry-run', '--cwd', root], { encoding: 'utf8' });
    assert.strictEqual(r.status, 0, r.stderr);
    assert.match(r.stdout, /workspace bootstrap/);
  });
});

describe('confirmation gate', () => {
  it('init and bootstrap only plan without --yes or --dry-run', (t) => {
    const { root } = makeTcxWorkspace(t);
    const init = cliJson(root, ['init'], { raw: true });
    assert.strictEqual(init.code, 2);
    assert.strictEqual(init.json.needsYes, true);
    assert.strictEqual(init.json.ok, false);
    assert.ok(init.json.planned.outputs.some((o) => o.path === 'adf-workspace.json'));
    assert.ok(!fs.existsSync(path.join(root, 'adf-workspace.json')), 'nothing written');
    assert.match(cli(root, ['init'], { raw: true }).out, /nothing written: re-run with --yes after confirming the dry-run output/);

    assert.strictEqual(cli(root, ['init']).code, 0);
    fs.rmSync(path.join(root, 'services/order'), { recursive: true, force: true });
    const boot = cliJson(root, ['bootstrap'], { raw: true });
    assert.strictEqual(boot.code, 2);
    assert.strictEqual(boot.json.needsYes, true);
    assert.deepStrictEqual(boot.json.planned.members.filter((m) => m.status === 'would-clone').map((m) => m.name), ['order']);
    assert.ok(!fs.existsSync(path.join(root, 'services/order')));
  });

  it('check and seed-map do not need --yes, and a failing plan keeps its own exit code', (t) => {
    const { root } = makePolyglotMonorepo(t);
    assert.strictEqual(cliJson(root, ['seed-map'], { raw: true }).code, 0);
    assert.strictEqual(cliJson(root, ['check'], { raw: true }).code, 0);
    fs.writeFileSync(path.join(root, 'adf-workspace.json'), '{ "version": 2 }');
    const init = cliJson(root, ['init'], { raw: true });
    assert.strictEqual(init.code, 1);
    assert.strictEqual(init.json.needsYes, undefined);
  });
});

describe('scope through the dispatcher', () => {
  it('reads --plan and --paths as values and prints one JSON object', (t) => {
    const { root } = scopeWorkspace(t);
    writePlan(root, 'p1', ['scope: [services/order]']);
    const byPlan = cliJson(root, ['scope', '--plan', 'plans/p1']);
    assert.strictEqual(byPlan.code, 0);
    assert.deepStrictEqual(byPlan.json.paths, ['services/order']);
    const byPaths = cliJson(root, ['scope', '--paths', 'order,gateway']);
    assert.deepStrictEqual(byPaths.json.paths, ['services/order', 'services/gateway']);
    assert.strictEqual(cliJson(root, ['scope', '--plan']).code, 2);
  });

  it('--write-settings and --clear-settings print the diff and write nothing without --yes', (t) => {
    const { root } = scopeWorkspace(t);
    const file = path.join(root, '.claude/settings.local.json');
    const dry = cliJson(root, ['scope', '--paths', 'order', '--write-settings']);
    assert.strictEqual(dry.code, 0);
    assert.strictEqual(dry.json.settings.written, false);
    assert.ok(dry.json.settings.diff.length > 0);
    assert.strictEqual(fs.existsSync(file), false);
    assert.strictEqual(cliJson(root, ['scope', '--paths', 'order', '--write-settings', '--yes']).json.settings.written, true);
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(file, 'utf8')).adfScope.paths, ['services/order']);
    assert.strictEqual(cliJson(root, ['scope', '--clear-settings']).json.settings.written, false);
    assert.ok(JSON.parse(fs.readFileSync(file, 'utf8')).adfScope);
    assert.strictEqual(cliJson(root, ['scope', '--clear-settings', '--yes']).json.settings.written, true);
    assert.strictEqual(JSON.parse(fs.readFileSync(file, 'utf8')).adfScope, undefined);
  });
});

describe('flag validation', () => {
  it('rejects bad --org, --client and --product without echoing them', (t) => {
    const { root } = makePolyglotMonorepo(t);
    for (const argv of [['seed-map', '--client', 'bad--x'], ['seed-map', '--org', 'a<b>'], ['init', '--product', 'x<y>'], ['init', '--org', 'a,a']]) {
      const r = cli(root, argv);
      assert.strictEqual(r.code, 2, argv.join(' '));
      assert.ok(!/bad--x|a<b>|x<y>/.test(r.out + r.err), `${argv.join(' ')} echoed its value`);
    }
    assert.ok(!fs.existsSync(path.join(root, 'docs/architecture/system-map.json')));
    assert.strictEqual(cli(root, ['seed-map', '--client', 'tcx', '--org', 'acme,client-org']).code, 0);
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(path.join(root, 'docs/architecture/system-map.json'), 'utf8')).org, ['acme', 'client-org']);
    assert.strictEqual(cli(root, ['check']).code, 0);
  });
});

describe('internal failures', () => {
  it('print exactly one JSON object with --json, without leaking a credential', () => {
    const boom = { name: 'boom', run: () => { throw new Error('kaboom https://user:s3cret@example.com/x.git'); } }; // adf-allow-secret
    COMMANDS.push(boom);
    try {
      const out = [];
      const err = [];
      assert.strictEqual(main(['boom', '--json'], { out: (s) => out.push(s), err: (s) => err.push(s) }), 1);
      assert.strictEqual(out.length, 1);
      assert.deepStrictEqual(err, []);
      const parsed = JSON.parse(out[0]);
      assert.strictEqual(parsed.ok, false);
      assert.match(parsed.errors[0], /kaboom/);
      assert.ok(!out[0].includes('s3cret'));
      const plain = [];
      assert.strictEqual(main(['boom'], { out: () => {}, err: (s) => plain.push(s) }), 1);
      assert.match(plain.join(''), /workspace boom failed: kaboom/);
    } finally {
      COMMANDS.splice(COMMANDS.indexOf(boom), 1);
    }
  });

  it('print JSON for usage errors too', () => {
    for (const argv of [['nope', '--json'], ['init', '--org', '--json'], ['check', '--cwd', '/no/such/dir', '--json']]) {
      const out = [];
      assert.strictEqual(main(argv, { out: (s) => out.push(s), err: () => assert.fail('stderr used') }), 2, argv.join(' '));
      assert.strictEqual(out.length, 1);
      assert.strictEqual(JSON.parse(out[0]).ok, false);
    }
  });
});

describe('success criteria on the TCX fixture', () => {
  it('init, check, remove a member, plan it, restore it from a mirror', (t) => {
    const { root } = makeTcxWorkspace(t);
    fs.mkdirSync(path.join(root, 'services/order/src'), { recursive: true });
    fs.writeFileSync(path.join(root, 'services/order/src/order.service.ts'), 'export class OrderService {}\n');

    assert.strictEqual(cli(root, ['init']).code, 0);
    const checked = cliJson(root, ['check']);
    assert.strictEqual(checked.code, 0, JSON.stringify(checked.json));

    const mirror = mirrorOf(t, path.join(root, 'services/order'), 'order');
    editManifest(root, (m) => { m.members.find((x) => x.name === 'order').repo = mirror.url; });
    fs.rmSync(path.join(root, 'services/order'), { recursive: true, force: true });

    const planned = cliJson(root, ['bootstrap', '--dry-run', '--allow-local']);
    assert.strictEqual(planned.code, 0);
    assert.deepStrictEqual(planned.json.members.filter((m) => m.status === 'would-clone').map((m) => m.name), ['order']);
    assert.ok(!fs.existsSync(path.join(root, 'services/order')));

    const restored = cliJson(root, ['bootstrap', '--allow-local']);
    assert.strictEqual(restored.code, 0, JSON.stringify(restored.json));
    assert.ok(fs.existsSync(path.join(root, 'services/order/.git')));
    assert.strictEqual(git(path.join(root, 'services/order'), 'config', '--get', 'remote.origin.url'), mirror.url);
    assert.strictEqual(cliJson(root, ['check']).code, 0);
  });

  it('a root search without a path finds code in an ignored member', (t) => {
    const rg = spawnSync('rg', ['--version'], { encoding: 'utf8' });
    if (rg.error || rg.status !== 0) return t.skip('ripgrep is not installed');
    const { root } = makeTcxWorkspace(t);
    fs.mkdirSync(path.join(root, 'services/order/src'), { recursive: true });
    fs.writeFileSync(path.join(root, 'services/order/src/order.service.ts'), 'export class OrderService {}\n');
    assert.strictEqual(spawnSync('rg', ['-l', 'OrderService'], { cwd: root, encoding: 'utf8' }).stdout.trim(), '', 'hidden before init');
    cli(root, ['init']);
    assert.strictEqual(spawnSync('rg', ['-l', 'OrderService'], { cwd: root, encoding: 'utf8' }).stdout.trim(), 'services/order/src/order.service.ts');
  });
});
