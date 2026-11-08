#!/usr/bin/env node
/**
 * Tests for member-attach.cjs: the trust anchor and what attach refuses
 * Run: node --test .claude/skills/workspace/scripts/tests/member-attach-trust.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { git } = require('./workspace-test-helpers.cjs');
const { URL, SETTINGS, write, serveWorkspace, standaloneMember, attachTo, attach } = require('./member-attach-helpers.cjs');

describe('attach: trust anchor', () => {
  const refusedWith = (r, ...parts) => {
    assert.strictEqual(r.code, 1, r.text);
    for (const part of parts) assert.ok(r.text.includes(part), `${part} in:\n${r.text}`);
  };

  it('refuses a URL whose owner is not in the marker org, naming the owner, the origin owner and the org', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t);
    refusedWith(attachTo(m.root, 'https://github.com/mallory/tcx-workspace', { yes: true }), 'URL owner: mallory', 'member origin owner: tcx-client', 'marker org: acme, tcx-client');
    assert.ok(!fs.existsSync(m.workspaceDir) && !fs.existsSync(path.join(m.root, SETTINGS)));
  });

  it('refuses when the member origin owner is not in the marker org', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t, { origin: 'https://github.com/mallory/order' });
    refusedWith(attachTo(m.root, URL, { yes: true }), 'URL owner: acme', 'member origin owner: mallory', 'marker org: acme, tcx-client');
    assert.ok(!fs.existsSync(m.workspaceDir));
  });

  it('refuses when the member has no origin, or the URL is on another host', (t) => {
    serveWorkspace(t);
    const m = standaloneMember(t);
    refusedWith(attachTo(m.root, 'https://gitlab.com/acme/tcx-workspace', { yes: true }), 'URL host: gitlab.com (marker host: github.com)');
    git(m.root, 'remote', 'remove', 'origin');
    refusedWith(attachTo(m.root, URL, { yes: true }), 'no usable origin remote');
  });

  it('matches owners case-insensitively and accepts an ssh URL for the same owner', (t) => {
    const m = standaloneMember(t);
    const r = attachTo(m.root, 'git@github.com:ACME/tcx-workspace.git', { 'dry-run': true });
    assert.strictEqual(r.code, 0, r.text);
  });

  it('refuses URLs with credentials, a leading dash, or a form git should not be handed', (t) => {
    const m = standaloneMember(t);
    for (const url of ['https://user:tok@github.com/acme/tcx-workspace', 'https://ghp_abc@github.com/acme/tcx-workspace', '-oProxyCommand=x', '--upload-pack=x', 'file:///tmp/x.git', '/tmp/x', 'git://github.com/acme/tcx-workspace', 'github:acme/tcx-workspace', 'ext::sh -c x', 'https://github.com/acme/tcx-workspace?x=1', 'https://github.com/acme/tcx-workspace#frag', 'git@github.com:acme/tcx-workspace.git?x']) { // adf-allow-secret
      const r = attachTo(m.root, url, { yes: true });
      assert.strictEqual(r.code, 1, url);
      assert.ok(r.text.startsWith('refused:'), url);
      assert.ok(!r.text.includes('tok') && !r.text.includes('ghp_'), 'no credential in the message');
    }
    assert.strictEqual(attachTo(m.root, undefined).code, 2);
    assert.strictEqual(attach.run({ root: m.root, docsRel: 'docs', opts: { _: ['attach', URL, 'extra'] } }).code, 2);
  });

  it('needs a valid ADF marker', (t) => {
    const none = standaloneMember(t, { withMarker: false });
    assert.match(attachTo(none.root, URL).text, /no \.adf-workspace\.json/);
    const foreign = standaloneMember(t);
    write(path.join(foreign.root, '.adf-workspace.json'), { workspace: URL });
    assert.match(attachTo(foreign.root, URL).text, /not a valid ADF marker/);
    const bad = standaloneMember(t, { marker: { org: [] } });
    assert.match(attachTo(bad.root, URL).text, /not a valid ADF marker/);
  });
});
