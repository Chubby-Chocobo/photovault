#!/usr/bin/env node
/**
 * Tests for member-link.cjs (the member marker)
 * Run: node --test .claude/hooks/lib/__tests__/member-link.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { renderMarker, readMarker, canWriteMarker } = require('../member-link.cjs');

const URL = 'https://github.com/acme/tcx-workspace';

describe('member marker', () => {
  const manifest = { org: ['acme', 'tcx-client'], client: 'tcx', product: 'tcx', repo: URL };

  it('renders the exact shape, with the manifest org array, and reads it back', () => {
    const text = renderMarker({ manifest, component: 'order' });
    assert.deepStrictEqual(JSON.parse(text), { adf: 1, workspace: URL, host: 'github.com', org: ['acme', 'tcx-client'], client: 'tcx', product: 'tcx', component: 'order' });
    assert.ok(text.endsWith('}\n'));
    const read = readMarker(text);
    assert.strictEqual(read.ours, true);
    assert.strictEqual(read.marker.component, 'order');
  });

  it('leaves out client and product the manifest does not have, and refuses a manifest without a canonical repo', () => {
    const text = renderMarker({ manifest: { org: ['acme'], repo: URL }, component: 'order' });
    assert.deepStrictEqual(Object.keys(JSON.parse(text)), ['adf', 'workspace', 'host', 'org', 'component']);
    assert.strictEqual(canWriteMarker({ org: ['acme'] }), false);
    assert.strictEqual(canWriteMarker({ org: ['acme'], repo: 'git@github.com:acme/x.git' }), false);
    assert.throws(() => renderMarker({ manifest: { org: ['acme'] }, component: 'order' }), /canonical/);
    assert.throws(() => renderMarker({ manifest, component: 'Bad Name' }), /component/);
  });

  it('calls a file without "adf": 1 foreign, and an ADF file with a bad field ours but unusable', () => {
    for (const text of ['{ "workspace": "x" }', '{"adf": 2}', '[]', 'not json', '"adf"', 'null']) {
      assert.deepStrictEqual(readMarker(text), { ours: false, marker: null }, text);
    }
    const good = JSON.parse(renderMarker({ manifest, component: 'order' }));
    const broken = [
      { ...good, component: 'Bad Name' },
      { ...good, org: [] },
      { ...good, host: 'evil.example' },
      { ...good, workspace: 'git@github.com:acme/x.git' },
      { ...good, product: 'Not Valid' },
    ];
    for (const value of broken) assert.deepStrictEqual(readMarker(JSON.stringify(value)), { ours: true, marker: null }, JSON.stringify(value));
  });
});
