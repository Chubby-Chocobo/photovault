#!/usr/bin/env node
/**
 * Tests for member-attach.cjs: the clone, the membership check and unsafe settings
 * Run: node --test .claude/skills/workspace/scripts/tests/member-attach-clone.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { git } = require('./workspace-test-helpers.cjs');
const { URL, SETTINGS, write, serveWorkspace, standaloneMember, attachTo, settings, attach } = require('./member-attach-helpers.cjs');

describe('attach: the clone and the settings', () => {
  it('errors when the workspace does not list this repo, and leaves the clone and the settings as they were', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t, { origin: 'https://github.com/tcx-client/stranger', marker: { component: 'stranger' } });
    const r = attachTo(m.root, URL, { yes: true });
    assert.strictEqual(r.code, 1);
    assert.match(r.text, /does not list this repo/);
    assert.match(r.text, /clone was left in place/);
    assert.ok(fs.existsSync(m.workspaceDir));
    assert.ok(!fs.existsSync(path.join(m.root, SETTINGS)));
  });

  it('accepts a renamed repo when the marker component is in the workspace map', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t, { origin: 'https://github.com/tcx-client/order-renamed' });
    assert.strictEqual(attachTo(m.root, URL, { yes: true }).code, 0);
  });

  it('refuses a target that is a clone of a different repo, or a folder that is not a clone', (t) => {
    serveWorkspace(t);
    const other = standaloneMember(t);
    fs.mkdirSync(other.workspaceDir);
    git(other.workspaceDir, 'init', '--quiet');
    git(other.workspaceDir, 'remote', 'add', 'origin', 'https://github.com/acme/something-else');
    assert.match(attachTo(other.root, URL, { yes: true }).text, /clone of a different repo/);
    const full = standaloneMember(t);
    write(path.join(full.workspaceDir, 'notes.txt'), 'mine');
    assert.match(attachTo(full.root, URL, { yes: true }).text, /not empty and is not a git clone/);
    assert.strictEqual(fs.readFileSync(path.join(full.workspaceDir, 'notes.txt'), 'utf8'), 'mine');
  });

  it('reports a failed clone without leaking anything and writes no settings', (t) => {
    const m = standaloneMember(t);
    const r = attachTo(m.root, 'https://github.com/acme/no-such-workspace-xyz', { yes: true, dir: path.join(m.parent, 'gone') });
    assert.strictEqual(r.code, 1);
    assert.match(r.text, /git clone failed/);
    assert.ok(!fs.existsSync(path.join(m.root, SETTINGS)));
  });

  it('stops on settings it cannot merge safely', (t) => {
    serveWorkspace(t);
    const odd = standaloneMember(t);
    write(path.join(odd.root, SETTINGS), { permissions: { additionalDirectories: [1, 'x'] } });
    assert.match(attachTo(odd.root, URL, { yes: true }).text, /must be an array of strings/);
    assert.deepStrictEqual(settings(odd.root).permissions.additionalDirectories, [1, 'x']);
    const broken = standaloneMember(t);
    write(path.join(broken.root, SETTINGS), '{ nope');
    assert.strictEqual(attachTo(broken.root, URL, { yes: true }).code, 1);
  });
});
