#!/usr/bin/env node
/**
 * Tests for `workspace.cjs sync` and `attach` through the CLI entry point
 * Run: node --test .claude/skills/workspace/scripts/tests/member-commands.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { cli, cliJson, parseArgsFor } = Object.assign(require('./workspace-test-helpers.cjs'), { parseArgsFor: require('../workspace.cjs').parseArgs });
const { preparedWorkspace, exists } = require('./member-test-helpers.cjs');
const { URL, SETTINGS, serveWorkspace, standaloneMember } = require('./member-attach-helpers.cjs');

describe('sync through the CLI', () => {
  it('plans and exits 2 without --yes, writes with --yes, and --check needs no --yes', (t) => {
    const ws = preparedWorkspace(t);
    const planned = cli(ws.root, ['sync'], { raw: true });
    assert.strictEqual(planned.code, 2);
    assert.match(planned.out, /re-run with --yes/);
    assert.ok(!exists(ws.members.order, '.adf-workspace.json'));
    assert.strictEqual(cli(ws.root, ['sync', '--dry-run'], { raw: true }).code, 0);
    assert.strictEqual(cliJson(ws.root, ['sync', '--check'], { raw: true }).code, 1);
    const done = cliJson(ws.root, ['sync', '--yes'], { raw: true });
    assert.strictEqual(done.code, 0, JSON.stringify(done.json));
    assert.strictEqual(done.json.counts.written, 7);
    assert.ok(exists(ws.members.order, '.adf-workspace.json'));
    assert.strictEqual(cliJson(ws.root, ['sync', '--check'], { raw: true }).code, 0);
  });

  it('--member and --from take a value', (t) => {
    assert.strictEqual(parseArgsFor(['sync', '--member', 'order']).member, 'order');
    assert.strictEqual(parseArgsFor(['sync', '--from', '/ws']).from, '/ws');
    assert.strictEqual(parseArgsFor(['attach', URL, '--dir', '/x']).dir, '/x');
    assert.throws(() => parseArgsFor(['sync', '--member']), /--member needs a value/);
    const ws = preparedWorkspace(t);
    const r = cliJson(ws.root, ['sync', '--member', 'gateway', '--yes'], { raw: true });
    assert.deepStrictEqual(r.json.rows.map((x) => x.component), ['gateway']);
  });
});

describe('attach through the CLI', () => {
  it('prints the plan with exit 2 without --yes, and clones and grants with --yes', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t);
    const planned = cli(m.root, ['attach', URL], { raw: true });
    assert.strictEqual(planned.code, 2, planned.err);
    assert.match(planned.out, /would get/);
    assert.ok(!fs.existsSync(m.workspaceDir));
    const done = cliJson(m.root, ['attach', URL, '--yes'], { raw: true });
    assert.strictEqual(done.code, 0, JSON.stringify(done.json));
    assert.strictEqual(done.json.workspace.clone, 'cloned');
    assert.deepStrictEqual(JSON.parse(fs.readFileSync(path.join(m.root, SETTINGS), 'utf8')).permissions.additionalDirectories, [m.workspaceDir]);
  });

  it('refuses an untrusted URL with exit 1 and a single JSON object', (t) => {
    const m = standaloneMember(t);
    const r = cliJson(m.root, ['attach', 'https://github.com/mallory/tcx-workspace', '--yes'], { raw: true });
    assert.strictEqual(r.code, 1);
    assert.strictEqual(r.json.ok, false);
    assert.ok(r.json.errors.some((e) => e.includes('URL owner: mallory')));
  });
});
