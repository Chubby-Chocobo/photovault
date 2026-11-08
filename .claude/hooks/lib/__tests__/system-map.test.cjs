#!/usr/bin/env node
/**
 * Tests for system-map.cjs and system-map-validate.cjs
 * Run: node --test .claude/hooks/lib/__tests__/system-map.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  MAP_REL, DEFAULT_ROLES, SAFE_TEXT, VIA, KINDS, mapPath, loadSystemMap, validateSystemMap, roleFor, componentForPath, callersOf, consumersOf,
} = require('../system-map.cjs');

const GIT = { flow: 'off', enforcement: 'ask', mainBranch: 'develop' };
const manifest = {
  version: 1, client: 'tcx', product: 'tcx', org: ['acme', 'tcx-client'],
  members: [
    { name: 'order', path: 'services/order', repo: 'https://github.com/acme/tcx-order.git', git: GIT },
    { name: 'matching-engine', path: 'services/matching-engine', repo: 'https://github.com/acme/tcx-matching-engine.git', git: GIT },
    { name: 'tcx-proto', path: 'contracts/tcx-proto', repo: 'https://github.com/acme/tcx-proto.git', git: GIT },
  ],
};
const workspaceMap = (extra = {}) => ({
  version: 1, client: 'tcx', product: 'tcx',
  roles: { frontend: ['fe', 'web'] },
  components: [
    { name: 'order', member: 'order', role: 'backend', stack: 'nestjs', calls: [{ to: 'matching-engine', via: 'kafka', topic: 'orders.new' }], consumes: ['tcx-proto'], produces: [] },
    { name: 'matching-engine', member: 'matching-engine', subpath: 'core', role: 'engine', stack: 'maven' },
  ],
  contracts: [{ id: 'tcx-proto', kind: 'proto', member: 'tcx-proto' }],
  ...extra,
});
const monorepoMap = (extra = {}) => ({
  version: 1, org: ['acme'],
  components: [
    { name: 'billing', path: 'services/billing', calls: [{ to: 'ranker', via: 'grpc' }], consumes: ['order-proto'] },
    { name: 'ranker', path: 'services/ranker' },
  ],
  contracts: [{ id: 'order-proto', kind: 'proto', path: 'contracts/proto', repo: 'https://github.com/acme/protos.git' }],
  ...extra,
});

function projectWith(t, map, docsRel = 'docs') {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-map-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  if (map !== undefined) {
    fs.mkdirSync(path.dirname(mapPath(dir, docsRel)), { recursive: true });
    fs.writeFileSync(mapPath(dir, docsRel), typeof map === 'string' ? map : JSON.stringify(map));
  }
  return dir;
}

const errorsOf = (map, manifestArg = manifest) => validateSystemMap(map, { manifest: manifestArg }).errors;
const withComponent = (patch) => workspaceMap({ components: [{ ...workspaceMap().components[0], ...patch }, workspaceMap().components[1]] });

describe('validateSystemMap (workspace)', () => {
  it('accepts the documented example', () => {
    assert.deepStrictEqual(errorsOf(workspaceMap()), []);
  });

  it('errors on an unknown member, call target and contract id', () => {
    assert.ok(errorsOf(withComponent({ member: 'nope' })).some((e) => e.includes('.member must name a manifest member')));
    assert.ok(errorsOf(withComponent({ member: undefined })).some((e) => e.includes('.member must name a manifest member')));
    assert.ok(errorsOf(withComponent({ calls: [{ to: 'ghost', via: 'rest' }] })).some((e) => e.includes('.to must name a component')));
    assert.ok(errorsOf(withComponent({ consumes: ['ghost'] })).some((e) => e.includes('consumes must name contract ids')));
    assert.ok(errorsOf(withComponent({ produces: ['ghost'] })).some((e) => e.includes('produces must name contract ids')));
    assert.ok(errorsOf(workspaceMap({ contracts: [{ id: 'tcx-proto', kind: 'proto', member: 'nope' }] })).some((e) => e.includes('contracts[0]')));
  });

  it('errors on bad via, kind, names and duplicates', () => {
    assert.ok(errorsOf(withComponent({ calls: [{ to: 'matching-engine', via: 'smoke' }] })).some((e) => e.includes('via must be one of')));
    assert.ok(errorsOf(workspaceMap({ contracts: [{ id: 'tcx-proto', kind: 'xml', member: 'tcx-proto' }] })).some((e) => e.includes('kind must be one of')));
    assert.ok(errorsOf(withComponent({ name: 'Order' })).some((e) => e.includes('.name must match')));
    assert.ok(errorsOf(withComponent({ name: 'matching-engine' })).some((e) => e.includes('duplicates')));
    assert.ok(errorsOf(workspaceMap({ contracts: [workspaceMap().contracts[0], workspaceMap().contracts[0]] })).some((e) => e.includes('duplicates')));
  });

  it('exports the enums', () => {
    assert.deepStrictEqual(VIA, ['grpc', 'rest', 'kafka', 'amqp', 'websocket', 'db', 'other']);
    assert.deepStrictEqual(KINDS, ['proto', 'openapi', 'asyncapi', 'json-schema', 'abi', 'graphql', 'other']);
    assert.ok(SAFE_TEXT.test('orders.new'));
  });

  describe('rendered-string safety', () => {
    const bad = ['orders\nnew', 'x --> y', '<script>', 'a--b', '', ' lead', 'x>y', 'tab\there', 'x'.repeat(122)];
    for (const topic of bad) {
      it(`rejects topic ${JSON.stringify(topic).slice(0, 30)}`, () => {
        const errors = errorsOf(withComponent({ calls: [{ to: 'matching-engine', via: 'kafka', topic }] }));
        assert.ok(errors.some((e) => e.includes('.topic must match')), JSON.stringify(errors));
      });
    }

    it('rejects unsafe role, stack, subpath, client, product and role aliases', () => {
      assert.ok(errorsOf(withComponent({ role: 'a<b' })).some((e) => e.includes('.role must match')));
      assert.ok(errorsOf(withComponent({ stack: 'x\ny' })).some((e) => e.includes('.stack must match')));
      assert.ok(errorsOf(withComponent({ subpath: '../x' })).some((e) => e.includes('.subpath must match')));
      assert.ok(errorsOf(withComponent({ subpath: 'a--b' })).some((e) => e.includes('.subpath must match')));
      assert.ok(errorsOf(workspaceMap({ client: 'a<b' })).some((e) => e.includes('client must match')));
      assert.ok(errorsOf(workspaceMap({ product: 'a -->' })).some((e) => e.includes('product must match')));
      assert.ok(errorsOf(workspaceMap({ roles: { frontend: ['fe', 'x\ny'] } })).some((e) => e.includes('roles.frontend')));
      assert.ok(errorsOf(workspaceMap({ roles: { 'a<b': ['x'] } })).some((e) => e.includes('roles has a key')));
    });

    it('accepts ordinary values', () => {
      const ok = withComponent({ role: 'smart-contract', stack: 'react-native', subpath: 'packages/core', calls: [{ to: 'matching-engine', via: 'kafka', topic: 'orders.new:v2@eu-1' }] });
      assert.deepStrictEqual(errorsOf(ok), []);
    });
  });

  it('warns on a stored path/repo and on the map org, and on unknown keys', () => {
    const map = withComponent({ path: 'x/y', extra: 1 });
    map.org = ['someone'];
    const { errors, warnings } = validateSystemMap(map, { manifest });
    assert.deepStrictEqual(errors, []);
    assert.ok(warnings.some((w) => w.includes('.path is derived')));
    assert.ok(warnings.some((w) => w.includes('unknown key "extra"')));
    assert.ok(warnings.some((w) => w.includes('org is read from the manifest')));
  });

  it('rejects non-objects, a wrong version and non-array collections', () => {
    assert.ok(errorsOf([]).some((e) => e.includes('JSON object')));
    assert.ok(errorsOf(workspaceMap({ version: 2 })).some((e) => e.includes('version must be 1')));
    assert.ok(errorsOf(workspaceMap({ components: {} })).some((e) => e.includes('components must be an array')));
  });
});

describe('validateSystemMap (monorepo)', () => {
  it('accepts paths and a contract repo without a manifest', () => {
    assert.deepStrictEqual(validateSystemMap(monorepoMap(), {}).errors, []);
  });

  it('requires a safe path and rejects member without a manifest', () => {
    const noPath = monorepoMap({ components: [{ name: 'billing' }] });
    assert.ok(validateSystemMap(noPath).errors.some((e) => e.includes('.path is required')));
    const dots = monorepoMap({ components: [{ name: 'billing', path: 'services/../x' }] });
    assert.ok(validateSystemMap(dots).errors.some((e) => e.includes('.path is required')));
    const absolute = monorepoMap({ components: [{ name: 'billing', path: '/etc' }] });
    assert.ok(validateSystemMap(absolute).errors.some((e) => e.includes('.path is required')));
    const joined = monorepoMap({ components: [{ name: 'billing', member: 'order', path: 'services/billing' }] });
    assert.ok(validateSystemMap(joined).errors.some((e) => e.includes('need adf-workspace.json')));
  });

  it('validates org as an owner array and a contract repo without credentials', () => {
    assert.ok(validateSystemMap(monorepoMap({ org: 'acme' })).errors.some((e) => e.includes('org must be a non-empty array')));
    assert.ok(validateSystemMap(monorepoMap({ org: [] })).errors.some((e) => e.includes('org must be a non-empty array')));
    const token = `${'ghp_'}${'C'.repeat(36)}`;
    const leaky = monorepoMap({ contracts: [{ id: 'order-proto', kind: 'proto', path: 'contracts/proto', repo: `https://${token}@github.com/acme/protos.git` }] });
    const { errors } = validateSystemMap(leaky);
    assert.ok(errors.some((e) => e.includes('credentials')));
    assert.ok(!errors.join('\n').includes(token));
  });
});

describe('loadSystemMap', () => {
  it('derives path and repo from the manifest and never stores them', (t) => {
    const root = projectWith(t, workspaceMap({ org: ['ignored'] }));
    const { map, errors } = loadSystemMap(root, 'docs', { manifest });
    assert.deepStrictEqual(errors, []);
    const [order, engine] = map.components;
    assert.strictEqual(order.path, 'services/order');
    assert.strictEqual(order.repo, 'https://github.com/acme/tcx-order.git');
    assert.strictEqual(engine.path, 'services/matching-engine/core');
    assert.strictEqual(map.contracts[0].path, 'contracts/tcx-proto');
    assert.strictEqual(map.contracts[0].repo, 'https://github.com/acme/tcx-proto.git');
    assert.deepStrictEqual(map.org, ['acme', 'tcx-client']);
    const onDisk = JSON.parse(fs.readFileSync(mapPath(root), 'utf8'));
    assert.strictEqual(onDisk.components[0].path, undefined);
    assert.strictEqual(onDisk.contracts[0].repo, undefined);
  });

  it('ignores a stored path or repo in favor of the manifest', (t) => {
    const map = withComponent({ path: 'evil/place', repo: 'https://github.com/evil/x' });
    const loaded = loadSystemMap(projectWith(t, map), 'docs', { manifest });
    assert.strictEqual(loaded.map.components[0].path, 'services/order');
    assert.strictEqual(loaded.map.components[0].repo, 'https://github.com/acme/tcx-order.git');
  });

  it('keeps stored paths and the map org without a manifest', (t) => {
    const { map } = loadSystemMap(projectWith(t, monorepoMap()), 'docs');
    assert.strictEqual(map.components[0].path, 'services/billing');
    assert.deepStrictEqual(map.org, ['acme']);
    assert.strictEqual(map.contracts[0].repo, 'https://github.com/acme/protos.git');
  });

  it('reports an invalid manifest file instead of applying monorepo rules', (t) => {
    const root = projectWith(t, workspaceMap());
    fs.writeFileSync(path.join(root, 'adf-workspace.json'), '{ "version": 2 }');
    const loaded = loadSystemMap(root, 'docs', { manifest: null });
    assert.strictEqual(loaded.map, null);
    assert.deepStrictEqual(loaded.errors, ['adf-workspace.json is invalid; fix it before the map can be loaded']);
  });

  it('returns map null with no error when the file is absent', (t) => {
    assert.deepStrictEqual(loadSystemMap(projectWith(t), 'docs', {}), { map: null, errors: [], warnings: [] });
  });

  it('reports invalid JSON and validation errors without throwing', (t) => {
    const broken = loadSystemMap(projectWith(t, '{ nope'), 'docs');
    assert.strictEqual(broken.map, null);
    assert.ok(broken.errors[0].includes('not valid JSON'));
    const token = `${'ghp_'}${'E'.repeat(36)}`;
    const leaky = loadSystemMap(projectWith(t, `{ "x": "${token}" oops }`), 'docs');
    assert.ok(!leaky.errors.join('\n').includes(token));
    const invalid = loadSystemMap(projectWith(t, withComponent({ member: 'nope' })), 'docs', { manifest });
    assert.strictEqual(invalid.map, null);
    assert.ok(invalid.errors.length > 0);
  });

  it('honors a custom docs dir and refuses an escaping one', (t) => {
    const root = projectWith(t, workspaceMap(), 'documentation');
    assert.ok(mapPath(root, 'documentation').endsWith(path.join('documentation', ...MAP_REL.split('/'))));
    assert.ok(loadSystemMap(root, 'documentation', { manifest }).map);
    assert.strictEqual(mapPath(root, '../escape'), path.join(root, 'docs', ...MAP_REL.split('/')));
    assert.strictEqual(mapPath(root, '/abs'), path.join(root, 'docs', ...MAP_REL.split('/')));
  });
});

describe('roleFor', () => {
  const table = [
    ['tcx-admin-fe', 'frontend'], ['tcx-admin-be', 'backend'], ['xswap-interface', 'frontend'], ['vdax-sc', 'smart-contract'],
    ['tcx-matching-engine', 'engine'], ['foo', 'unknown'], ['admin-web', 'frontend'], ['matching-engine', 'engine'],
    ['TCX-Admin-FE', 'frontend'], ['telegram-bot', 'bot'], ['tcx-sdk', 'sdk'], ['order', 'unknown'], ['', 'unknown'],
  ];
  for (const [name, role] of table) {
    it(`${JSON.stringify(name)} -> ${role}`, () => assert.strictEqual(roleFor(name), role));
  }

  it('custom roles replace the defaults', () => {
    const roles = { payments: ['pay', 'order'] };
    assert.strictEqual(roleFor('tcx-pay', roles), 'payments');
    assert.strictEqual(roleFor('order', roles), 'payments');
    assert.strictEqual(roleFor('tcx-admin-fe', roles), 'unknown');
  });

  it('prefers the last segment over the whole name', () => {
    assert.strictEqual(roleFor('api-fe', { frontend: ['fe'], backend: ['api-fe'] }), 'frontend');
  });

  it('exposes the default table', () => {
    assert.deepStrictEqual(Object.keys(DEFAULT_ROLES), ['frontend', 'backend', 'smart-contract', 'engine', 'mobile', 'infra', 'bot', 'sdk']);
  });
});

describe('queries', () => {
  const map = {
    components: [
      { name: 'order', path: 'services/order', calls: [{ to: 'engine', via: 'kafka', topic: 'orders.new' }], consumes: ['proto'] },
      { name: 'gateway', path: 'services/gateway', calls: [{ to: 'engine', via: 'grpc' }, { to: 'order', via: 'rest' }], consumes: ['proto'] },
      { name: 'engine', path: 'services/engine' },
      { name: 'engine-core', path: 'services/engine/core' },
    ],
  };

  it('callersOf is the inverse of calls', () => {
    const callers = callersOf(map, 'engine');
    assert.deepStrictEqual(callers.map((c) => c.component.name), ['order', 'gateway']);
    assert.deepStrictEqual(callers.map((c) => c.via), ['kafka', 'grpc']);
    assert.strictEqual(callers[0].topic, 'orders.new');
    assert.strictEqual('topic' in callers[1], false);
    assert.deepStrictEqual(callersOf(map, 'gateway'), []);
    assert.deepStrictEqual(callersOf(null, 'x'), []);
  });

  it('consumersOf lists components that consume a contract', () => {
    assert.deepStrictEqual(consumersOf(map, 'proto').map((c) => c.name), ['order', 'gateway']);
    assert.deepStrictEqual(consumersOf(map, 'none'), []);
  });

  it('componentForPath picks the longest path prefix', () => {
    assert.strictEqual(componentForPath(map, 'services/order/src/a.ts').name, 'order');
    assert.strictEqual(componentForPath(map, 'services/engine/core/x').name, 'engine-core');
    assert.strictEqual(componentForPath(map, 'services/engine/other').name, 'engine');
    assert.strictEqual(componentForPath(map, './services/order').name, 'order');
    assert.strictEqual(componentForPath(map, 'services\\order\\a.ts').name, 'order');
    assert.strictEqual(componentForPath(map, 'services/orderly/a.ts'), null);
    assert.strictEqual(componentForPath(map, 'docs/x.md'), null);
    assert.strictEqual(componentForPath(null, 'x'), null);
  });
});
