'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { makePolyglotMonorepo } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { seedMap } = require('../lib/system-map-seed.cjs');

const put = (root, rel, text) => {
  fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
  fs.writeFileSync(path.join(root, rel), text);
};
const existing = (repo) => ({ version: 1, components: [], contracts: [{ id: 'vdax-libs', kind: 'other', path: 'contracts/vdax', repo }] });
const consumesOf = (map) => Object.fromEntries(map.components.map((c) => [c.name, c.consumes || []]));

describe('seedMap: consumes from Cargo and npm pins', () => {
  it('adds a contract whose repo a Cargo git dependency or an npm git URL points at', (t) => {
    const { root } = makePolyglotMonorepo(t);
    put(root, 'services/billing/Cargo.toml', '[dependencies]\nv = { git = "ssh://git@github.com/acme/vdax-libs.git", tag = "v1.0.0" }\n');
    put(root, 'services/gateway/package.json', JSON.stringify({ name: 'gateway', dependencies: { v: 'github:acme/vdax-libs#v1.0.0' } }));
    put(root, 'apps/admin-web/package.json', JSON.stringify({ name: 'admin-web', dependencies: { vue: '^3.4.0', other: 'github:acme/other' } }));
    const consumes = consumesOf(seedMap({ root, existing: existing('https://github.com/acme/vdax-libs') }).map);
    assert.deepEqual(consumes.billing, ['vdax-libs']);
    assert.deepEqual(consumes.gateway, ['vdax-libs']);
    assert.deepEqual(consumes['admin-web'], []);
  });

  it('never stores a credential from a pinned URL and ignores unrelated repos', (t) => {
    const { root } = makePolyglotMonorepo(t);
    const token = `${'ghp_'}${'C'.repeat(36)}`;
    put(root, 'services/billing/Cargo.toml', `[dependencies]\nv = { git = "https://${token}@github.com/acme/vdax-libs", tag = "v1" }\n`);
    const { map } = seedMap({ root, existing: existing('https://github.com/acme/vdax-libs') });
    assert.deepEqual(consumesOf(map).billing, ['vdax-libs']);
    assert.ok(!JSON.stringify(map).includes(token));
    assert.deepEqual(consumesOf(seedMap({ root, existing: existing('https://github.com/acme/else') }).map).billing, []);
  });
});
