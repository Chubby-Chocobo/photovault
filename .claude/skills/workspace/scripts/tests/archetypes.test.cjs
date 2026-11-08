#!/usr/bin/env node
/**
 * Tests for the archetype templates (`init|seed-map --archetype`, `check` info lines)
 * Run: node --test .claude/skills/workspace/scripts/tests/archetypes.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { makePolyglotMonorepo, makeTcxWorkspace } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { validateSystemMap } = require('../../../../hooks/lib/system-map.cjs');
const archetypes = require('../lib/archetypes.cjs');
const init = require('../lib/workspace-init.cjs');
const seedMapCommand = require('../lib/seed-map-command.cjs');
const check = require('../lib/workspace-check.cjs');
const { cli, cliJson, readJson, writeJson, MAP } = require('./workspace-test-helpers.cjs');

const ctx = (root, opts) => ({ root, docsRel: 'docs', opts: { yes: true, ...opts } });

describe('archetype files', () => {
  it('ships exchange and nest-service-monorepo, and both load and validate', () => {
    assert.deepStrictEqual(archetypes.listArchetypes(), ['exchange', 'nest-service-monorepo']);
    for (const id of archetypes.listArchetypes()) {
      const { archetype, error } = archetypes.loadArchetype(id);
      assert.strictEqual(error, null);
      assert.strictEqual(archetype.id, id);
    }
    const exchange = archetypes.loadArchetype('exchange').archetype;
    assert.deepStrictEqual(exchange.expectedRoles, ['gateway', 'auth', 'backend', 'engine', 'frontend', 'admin', 'mobile', 'infra']);
    assert.deepStrictEqual(exchange.expectedContractKinds, ['proto', 'json-schema']);
    const nest = archetypes.loadArchetype('nest-service-monorepo').archetype;
    assert.deepStrictEqual(nest.roles, { backend: ['service', 'worker'], gateway: ['gateway'] });
    assert.deepStrictEqual(nest.expectedRoles, ['gateway', 'backend']);
  });

  it('rejects an unknown id and ids with path characters', () => {
    assert.match(archetypes.loadArchetype('ghost').error, /unknown archetype ghost/);
    for (const bad of ['../x', '../../etc/passwd', 'a/b', 'a\\b', '.', '..', '', 'Exchange', undefined, 7]) {
      const { archetype, error } = archetypes.loadArchetype(bad);
      assert.strictEqual(archetype, null);
      assert.match(error, /archetype id must match/, String(bad));
    }
  });

  it('validateArchetype names what is wrong without echoing values', () => {
    const good = archetypes.loadArchetype('exchange').archetype;
    assert.deepStrictEqual(archetypes.validateArchetype(good, 'exchange'), []);
    assert.ok(archetypes.validateArchetype({ ...good, id: 'other' }, 'exchange').length > 0);
    assert.ok(archetypes.validateArchetype({ ...good, roles: { backend: 'api' } }, 'exchange').length > 0);
    assert.ok(archetypes.validateArchetype({ ...good, expectedContractKinds: ['cobol'] }, 'exchange').length > 0);
    assert.ok(archetypes.validateArchetype({ ...good, expectedRoles: ['a--b'] }, 'exchange').length > 0);
  });

  it('applyArchetype merges aliases without dropping existing ones and sets the id', () => {
    const nest = archetypes.loadArchetype('nest-service-monorepo').archetype;
    const map = { version: 1, roles: { backend: ['api', 'Service'], bot: ['bot'] }, components: [] };
    const out = archetypes.applyArchetype(map, nest);
    assert.strictEqual(out.archetype, 'nest-service-monorepo');
    assert.deepStrictEqual(out.roles, { backend: ['api', 'Service', 'worker'], bot: ['bot'], gateway: ['gateway'] });
    assert.deepStrictEqual(map.roles.backend, ['api', 'Service'], 'the input map is not changed');
  });
});

describe('init --archetype', () => {
  it('stores the field and the merged roles in a workspace map', (t) => {
    const { root } = makeTcxWorkspace(t);
    const out = init.run(ctx(root, { workspace: true, archetype: 'exchange' }));
    assert.strictEqual(out.code, 0, out.text);
    const map = readJson(root, MAP);
    assert.strictEqual(map.archetype, 'exchange');
    assert.deepStrictEqual(validateSystemMap(map, { manifest: readJson(root, 'adf-workspace.json') }).errors, []);
    for (const role of ['gateway', 'auth', 'admin', 'engine']) assert.ok(map.roles[role], role);
    assert.ok(map.roles.backend.includes('order') && map.roles.backend.includes('service'));
    const role = (name) => map.components.find((c) => c.name === name).role;
    assert.strictEqual(role('gateway'), 'gateway');
    assert.strictEqual(role('order'), 'backend');
  });

  it('stores the field in a monorepo map', (t) => {
    const { root } = makePolyglotMonorepo(t);
    const out = init.run(ctx(root, { archetype: 'nest-service-monorepo', org: 'acme' }));
    assert.strictEqual(out.code, 0, out.text);
    const map = readJson(root, MAP);
    assert.strictEqual(map.archetype, 'nest-service-monorepo');
    assert.strictEqual(map.components.find((c) => c.name === 'gateway').role, 'gateway');
  });

  it('writes no archetype field without the flag', (t) => {
    const { root } = makePolyglotMonorepo(t);
    assert.strictEqual(init.run(ctx(root, { org: 'acme' })).code, 0);
    assert.strictEqual(readJson(root, MAP).archetype, undefined);
  });

  it('exits 2 for an unknown id, a path id or a missing value, and writes nothing', (t) => {
    const { root } = makePolyglotMonorepo(t);
    for (const archetype of ['ghost', '../x', true]) {
      const out = init.run(ctx(root, { archetype, org: 'acme' }));
      assert.strictEqual(out.code, 2, String(archetype));
    }
    assert.ok(!fs.existsSync(path.join(root, MAP)));
  });
});

describe('seed-map --archetype', () => {
  it('seeds a new map with the archetype', (t) => {
    const { root } = makePolyglotMonorepo(t);
    const out = seedMapCommand.run(ctx(root, { archetype: 'nest-service-monorepo', org: 'acme' }));
    assert.strictEqual(out.code, 0, out.text);
    assert.match(out.text, /archetype:nest-service-monorepo/);
    assert.strictEqual(readJson(root, MAP).archetype, 'nest-service-monorepo');
  });

  it('with --merge adds the archetype to an existing map and keeps hand edits', (t) => {
    const { root } = makePolyglotMonorepo(t);
    assert.strictEqual(seedMapCommand.run(ctx(root, { org: 'acme' })).code, 0);
    const map = readJson(root, MAP);
    map.components[0].stack = 'hand-edited';
    writeJson(root, MAP, map);
    const out = seedMapCommand.run(ctx(root, { merge: true, archetype: 'exchange' }));
    assert.strictEqual(out.code, 0, out.text);
    const merged = readJson(root, MAP);
    assert.strictEqual(merged.archetype, 'exchange');
    assert.strictEqual(merged.components[0].stack, 'hand-edited');
    assert.ok(merged.roles.auth);
    const again = seedMapCommand.run(ctx(root, { merge: true, archetype: 'exchange' }));
    assert.match(again.text, /nothing to add/);
  });

  it('rejects an unknown archetype with exit 2', (t) => {
    const { root } = makePolyglotMonorepo(t);
    assert.strictEqual(seedMapCommand.run(ctx(root, { archetype: '../x', org: 'acme' })).code, 2);
  });
});

describe('check with an archetype', () => {
  const run = (root) => check.run({ root, docsRel: 'docs' });

  it('lists the expected roles and contract kinds the map lacks as info, exit 0', (t) => {
    const { root } = makeTcxWorkspace(t);
    assert.strictEqual(init.run(ctx(root, { workspace: true, archetype: 'exchange' })).code, 0);
    const { code, result, text } = run(root);
    assert.strictEqual(code, 0, text);
    for (const role of ['auth', 'admin', 'mobile', 'infra']) {
      assert.ok(result.info.some((i) => i.endsWith(`no component with role ${role}`)), role);
    }
    assert.ok(!result.info.some((i) => i.endsWith('role engine')), 'matching-engine has the engine role');
    assert.ok(!result.info.some((i) => i.includes('contract of kind')), 'the proto contract satisfies the kinds');
    assert.match(text, /\ninfo:\n/);
  });

  it('is silent for a map without an archetype', (t) => {
    const { root } = makeTcxWorkspace(t);
    assert.strictEqual(init.run(ctx(root, { workspace: true })).code, 0);
    assert.deepStrictEqual(run(root).result.info, []);
  });

  it('warns, not fails, on an archetype id this ADF does not ship', (t) => {
    const { root } = makeTcxWorkspace(t);
    assert.strictEqual(init.run(ctx(root, { workspace: true })).code, 0);
    const map = readJson(root, MAP);
    map.archetype = 'ghost';
    writeJson(root, MAP, map);
    const { code, result } = run(root);
    assert.strictEqual(code, 0);
    assert.ok(result.warnings.some((w) => w.includes('unknown archetype ghost')), result.warnings.join('\n'));
  });

  it('fails validation on an archetype id with path characters', (t) => {
    const { root } = makeTcxWorkspace(t);
    assert.strictEqual(init.run(ctx(root, { workspace: true })).code, 0);
    const map = readJson(root, MAP);
    map.archetype = '../x';
    writeJson(root, MAP, map);
    const { code, result } = run(root);
    assert.strictEqual(code, 1);
    assert.ok(result.errors.some((e) => e.startsWith('archetype must match')));
  });
});

describe('--archetype on the command line', () => {
  it('init --dry-run --json shows the archetype and writes nothing', (t) => {
    const { root } = makePolyglotMonorepo(t);
    const { code, json } = cliJson(root, ['init', '--archetype', 'exchange', '--org', 'acme', '--dry-run']);
    assert.strictEqual(code, 0, JSON.stringify(json));
    assert.deepStrictEqual(json.archetype, { id: 'exchange', applied: true });
    assert.ok(json.outputs.some((o) => o.path === MAP && o.status === 'written'));
    assert.ok(!fs.existsSync(path.join(root, MAP)));
    assert.match(cli(root, ['init', '--archetype', 'exchange', '--org', 'acme', '--dry-run']).out, /archetype: exchange/);
  });

  it('init --archetype writes the field, and seed-map --merge --archetype applies one to an existing map', (t) => {
    const { root } = makePolyglotMonorepo(t);
    assert.strictEqual(cli(root, ['init', '--org', 'acme']).code, 0);
    const kept = cliJson(root, ['init', '--archetype', 'exchange', '--org', 'acme']);
    assert.strictEqual(kept.json.archetype.applied, false);
    assert.strictEqual(readJson(root, MAP).archetype, undefined);
    const merged = cliJson(root, ['seed-map', '--merge', '--archetype', 'exchange']);
    assert.strictEqual(merged.code, 0, JSON.stringify(merged.json));
    assert.ok(merged.json.added.includes('archetype:exchange'));
    assert.strictEqual(readJson(root, MAP).archetype, 'exchange');
  });

  it('exits 2 for an unknown id, a path id or a missing value, with init and seed-map', (t) => {
    const { root } = makePolyglotMonorepo(t);
    for (const command of ['init', 'seed-map']) {
      for (const argv of [['--archetype', 'ghost'], ['--archetype', '../x'], ['--archetype']]) {
        const r = cliJson(root, [command, ...argv, '--org', 'acme', '--dry-run']);
        assert.strictEqual(r.code, 2, `${command} ${argv.join(' ')}`);
      }
    }
    assert.ok(!fs.existsSync(path.join(root, MAP)));
  });
});
