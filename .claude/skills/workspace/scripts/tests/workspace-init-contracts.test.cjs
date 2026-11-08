'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { makeTcxWorkspace, makePolyglotMonorepo } = require('../../../../hooks/__tests__/fixtures/workspace-fixtures.cjs');
const { listConventions } = require('../../../../hooks/lib/docs-layout.cjs');
const { parseFrontmatter } = require('../../../../hooks/lib/front-matter.cjs');
const { cliJson } = require('./workspace-test-helpers.cjs');

const CONTRACTS = 'docs/conventions/contracts.md';
const DESCRIPTION = 'Where API and event contracts live, how they change, and how consumers pin them';
const statusOf = (json) => json.outputs.find((o) => o.path === CONTRACTS).status;

describe('workspace init: contracts policy', () => {
  it('writes contracts.md once with its description front matter, in a workspace', (t) => {
    const { root } = makeTcxWorkspace(t);
    const first = cliJson(root, ['init']);
    assert.equal(first.code, 0);
    assert.equal(statusOf(first.json), 'written');
    const text = fs.readFileSync(path.join(root, CONTRACTS), 'utf8');
    assert.equal(parseFrontmatter(text).description, DESCRIPTION);
    for (const needle of ['buf breaking', 'oasdiff breaking --fail-on ERR <base> <rev>', 'drift --fail-on unpinned,differs', 'read-only deploy key']) {
      assert.ok(text.includes(needle), needle);
    }
    assert.equal(statusOf(cliJson(root, ['init']).json), 'kept');
    assert.deepEqual(listConventions(path.join(root, 'docs')), [{ file: 'contracts.md', description: DESCRIPTION }]);
  });

  it('keeps an existing file untouched', (t) => {
    const { root } = makeTcxWorkspace(t);
    fs.mkdirSync(path.join(root, 'docs/conventions'), { recursive: true });
    fs.writeFileSync(path.join(root, CONTRACTS), 'team policy\n');
    assert.equal(statusOf(cliJson(root, ['init']).json), 'kept');
    assert.equal(fs.readFileSync(path.join(root, CONTRACTS), 'utf8'), 'team policy\n');
  });

  it('plans it in a dry run without writing, and writes it in a monorepo', (t) => {
    const ws = makeTcxWorkspace(t);
    assert.equal(statusOf(cliJson(ws.root, ['init', '--dry-run']).json), 'written');
    assert.ok(!fs.existsSync(path.join(ws.root, CONTRACTS)));
    const { root } = makePolyglotMonorepo(t);
    assert.equal(statusOf(cliJson(root, ['init']).json), 'written');
    assert.ok(fs.existsSync(path.join(root, CONTRACTS)));
  });
});
