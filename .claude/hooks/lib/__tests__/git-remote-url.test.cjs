#!/usr/bin/env node
/**
 * Tests for git-remote-url.cjs
 * Run: node --test .claude/hooks/lib/__tests__/git-remote-url.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { parseRemoteUrl, canonicalUrl, stripCredentials, sameRepo, ownerOf, toProtocol } = require('../git-remote-url.cjs');

describe('git-remote-url', () => {
  describe('parseRemoteUrl and canonicalUrl', () => {
    const forms = [
      'https://github.com/acme/tcx-proto',
      'https://github.com/acme/tcx-proto.git',
      'https://GitHub.com/acme/tcx-proto.git/',
      'git+https://github.com/acme/tcx-proto.git#master',
      'ssh://git@github.com/acme/tcx-proto.git',
      'git@github.com:acme/tcx-proto.git',
      'github:acme/tcx-proto',
      'https://user:tok@github.com/acme/tcx-proto.git', // adf-allow-secret
    ];

    for (const url of forms) {
      it(`parses ${url}`, () => {
        assert.deepStrictEqual(parseRemoteUrl(url), { host: 'github.com', owner: 'acme', repo: 'tcx-proto', path: 'acme/tcx-proto' });
        assert.strictEqual(canonicalUrl(url), 'https://github.com/acme/tcx-proto');
      });
    }

    it('keeps GitLab subgroups in path and takes the first segment as owner', () => {
      assert.deepStrictEqual(parseRemoteUrl('https://gitlab.com/g/sub/r.git'), { host: 'gitlab.com', owner: 'g', repo: 'r', path: 'g/sub/r' });
      assert.strictEqual(canonicalUrl('git@gitlab.com:g/sub/r.git'), 'https://gitlab.com/g/sub/r');
    });

    it('returns null for local paths, file:// and junk', () => {
      for (const url of ['/srv/git/r.git', './r', '../r.git', '~/r', 'C:\\repos\\r', 'C:/repos/r', 'file:///srv/git/r.git', '', '   ', 'plain', 'https://host', 'https://host/onlyone', 'https://host/a/../b', null, undefined, 42]) {
        assert.strictEqual(parseRemoteUrl(url), null, String(url));
        assert.strictEqual(canonicalUrl(url), null, String(url));
      }
    });

    it('never puts credentials in the parsed parts', () => {
      assert.ok(!JSON.stringify(parseRemoteUrl('https://user:tok@github.com/o/r')).includes('tok')); // adf-allow-secret
    });
  });

  describe('stripCredentials', () => {
    it('removes user:token@ and token@ from https URLs', () => {
      assert.strictEqual(stripCredentials('https://user:tok@host/o/r'), 'https://host/o/r'); // adf-allow-secret
      assert.strictEqual(stripCredentials('https://tok@host/o/r'), 'https://host/o/r');
      assert.strictEqual(stripCredentials('git+https://tok@host/o/r.git#v1'), 'git+https://host/o/r.git#v1');
      assert.ok(!/@/.test(stripCredentials('https://user:tok@host/o/r').split('/')[2])); // adf-allow-secret
    });

    it('keeps an @ later in the path', () => {
      assert.strictEqual(stripCredentials('https://tok@host/o/r@v1'), 'https://host/o/r@v1');
    });

    it('drops only a password from ssh:// and leaves scp-style and clean URLs alone', () => {
      assert.strictEqual(stripCredentials('ssh://git:pw@host/o/r'), 'ssh://git@host/o/r');
      assert.strictEqual(stripCredentials('ssh://git@host/o/r'), 'ssh://git@host/o/r');
      assert.strictEqual(stripCredentials('git@github.com:o/r.git'), 'git@github.com:o/r.git');
      assert.strictEqual(stripCredentials('https://host/o/r'), 'https://host/o/r');
      assert.strictEqual(stripCredentials('/local/path'), '/local/path');
    });

    it('passes non-strings through', () => {
      assert.strictEqual(stripCredentials(undefined), undefined);
    });
  });

  describe('sameRepo and ownerOf', () => {
    it('ignores .git, host case, protocol and credentials', () => {
      assert.ok(sameRepo('https://github.com/o/r', 'git@github.com:o/r.git'));
      assert.ok(sameRepo('https://GITHUB.com/o/r.git', 'https://github.com/o/r'));
      assert.ok(sameRepo('https://tok@github.com/o/r', 'github:o/r'));
    });

    it('tells different repos, owners and hosts apart', () => {
      assert.ok(!sameRepo('https://github.com/o/r', 'https://github.com/o/r2'));
      assert.ok(!sameRepo('https://github.com/o/r', 'https://github.com/p/r'));
      assert.ok(!sameRepo('https://github.com/o/r', 'https://gitlab.com/o/r'));
      assert.ok(!sameRepo('/local/r', '/local/r'));
      assert.ok(!sameRepo('https://github.com/o/r', null));
    });

    it('returns the owner or null', () => {
      assert.strictEqual(ownerOf('git@github.com:acme/r.git'), 'acme');
      assert.strictEqual(ownerOf('https://gitlab.com/g/sub/r'), 'g');
      assert.strictEqual(ownerOf('/local/path'), null);
    });
  });

  describe('toProtocol', () => {
    it('converts between https and ssh keeping the full path', () => {
      assert.strictEqual(toProtocol('https://github.com/o/r', 'ssh'), 'git@github.com:o/r.git');
      assert.strictEqual(toProtocol('git@github.com:o/r.git', 'https'), 'https://github.com/o/r');
      assert.strictEqual(toProtocol('ssh://git@github.com/o/r.git', 'https'), 'https://github.com/o/r');
      assert.strictEqual(toProtocol('github:o/r', 'ssh'), 'git@github.com:o/r.git');
    });

    it('keeps GitLab subgroups', () => {
      assert.strictEqual(toProtocol('https://gitlab.com/g/sub/r', 'ssh'), 'git@gitlab.com:g/sub/r.git');
      assert.strictEqual(toProtocol('git@gitlab.com:g/sub/r.git', 'https'), 'https://gitlab.com/g/sub/r');
      assert.strictEqual(parseRemoteUrl(toProtocol('https://gitlab.com/g/sub/r', 'ssh')).owner, 'g');
    });

    it('keeps a non-GitHub host', () => {
      assert.strictEqual(toProtocol('https://git.example.com/team/r', 'ssh'), 'git@git.example.com:team/r.git');
      assert.strictEqual(toProtocol('git@git.example.com:team/r.git', 'https'), 'https://git.example.com/team/r');
    });

    it('returns null for local paths, file:// and a port', () => {
      for (const url of ['/srv/git/r.git', './r', 'file:///srv/git/r.git', 'ssh://git@h:2222/o/r', 'https://h:8443/o/r']) {
        assert.strictEqual(toProtocol(url, 'ssh'), null, url);
        assert.strictEqual(toProtocol(url, 'https'), null, url);
      }
    });

    it('returns an unsupported protocol as null', () => {
      assert.strictEqual(toProtocol('https://github.com/o/r', 'git'), null);
    });

    it('leaves a URL already in the target protocol as written, minus credentials', () => {
      assert.strictEqual(toProtocol('https://github.com/o/r', 'https'), 'https://github.com/o/r');
      assert.strictEqual(toProtocol('https://github.com/o/r.git', 'https'), 'https://github.com/o/r.git');
      assert.strictEqual(toProtocol('git@github.com:o/r.git', 'ssh'), 'git@github.com:o/r.git');
      assert.strictEqual(toProtocol('https://tok@github.com/o/r', 'https'), 'https://github.com/o/r');
    });

    it('never returns credentials', () => {
      assert.ok(!String(toProtocol('https://user:tok@github.com/o/r', 'ssh')).includes('tok')); // adf-allow-secret
    });
  });
});
