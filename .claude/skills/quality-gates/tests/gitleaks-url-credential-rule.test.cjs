'use strict';

// The gitleaks template carries the same credential-URL regex as the ADF hooks. This keeps the two
// from drifting and checks the rule's shape (path filter, RE2-safe syntax).

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const { CREDENTIAL_URL_SOURCE } = require('../../../hooks/lib/manifest-credential-redactor.cjs');

const TEMPLATE = path.resolve(__dirname, '..', 'templates', 'gitleaks.toml');
const QUICK_SCAN = path.resolve(__dirname, '..', 'references', 'quick-scan-secret-patterns.md');

// Samples are assembled at runtime so this file holds no credential-shaped literal
const TOKEN = 'ghp_' + 'A'.repeat(36);
const url = (userinfo) => `https://${userinfo}@github.com/acme/x.git`;

/** Fields of the `[[rules]]` block with the given id; multi-line literal ('''...''') and plain strings. */
function ruleFields(toml, id) {
  const blocks = toml.split(/^\[\[rules\]\]\s*$/m).slice(1);
  const block = blocks.find((b) => new RegExp(`^\\s*id\\s*=\\s*"${id}"\\s*$`, 'm').test(b));
  assert.ok(block, `rule ${id} not found`);
  const fields = {};
  for (const m of block.matchAll(/^\s*(\w+)\s*=\s*(?:'''(.*?)'''|"([^"]*)"|(\d+)|(\[.*\]))\s*$/gm)) {
    fields[m[1]] = m[2] ?? m[3] ?? m[4] ?? m[5];
  }
  return fields;
}

const rule = ruleFields(fs.readFileSync(TEMPLATE, 'utf8'), 'url-embedded-credential');

test('the rule regex is exactly CREDENTIAL_URL_SOURCE', () => {
  assert.strictEqual(rule.regex, CREDENTIAL_URL_SOURCE);
});

test('the rule regex is RE2-safe and compiles', () => {
  assert.ok(!/\(\?(?:=|!|<=|<!|<[A-Za-z])|\\[1-9]/.test(rule.regex), 'no lookaround or backreference');
  assert.doesNotThrow(() => new RegExp(rule.regex));
});

test('the compiled rule flags credentials and spares placeholders', () => {
  const re = new RegExp(rule.regex);
  for (const userinfo of [TOKEN, `x-access-token:${TOKEN}`, 'user:' + 'pw1', 'q'.repeat(52), `glpat-${'z'.repeat(20)}`]) {
    assert.ok(re.test(url(userinfo)), userinfo.slice(0, 8));
  }
  assert.ok(re.test(`git+${url(TOKEN)}`));
  for (const text of ['https://${TOKEN}@github.com/a', 'https://<user>:<pw>@h.io', 'git@github.com:acme/x.git', 'https://github.com/acme/x.git', 'https://user@h.io']) {
    assert.ok(!re.test(text), text);
  }
});

test('the secret group is the userinfo', () => {
  assert.strictEqual(rule.secretGroup, '2');
  const match = new RegExp(rule.regex).exec(url(TOKEN));
  assert.strictEqual(match[2], TOKEN);
});

test('the rule is limited to manifest and config paths', () => {
  const pathRe = new RegExp(rule.path);
  for (const file of ['Cargo.toml', 'services/market/Cargo.toml', 'package.json', 'apps/web/package.json', 'go.mod', 'pom.xml', 'build.gradle',
    'build.gradle.kts', 'pyproject.toml', 'requirements.txt', 'composer.json', 'Gemfile', '.gitmodules', 'a/.npmrc', '.git-credentials']) {
    assert.ok(pathRe.test(file), file);
  }
  for (const file of ['src/index.ts', 'README.md', 'Cargo.lock', 'notpackage.json', 'docs/Cargo.toml.md']) {
    assert.ok(!pathRe.test(file), file);
  }
});

test('the quick-scan reference lists the same pattern as a grep form', () => {
  const text = fs.readFileSync(QUICK_SCAN, 'utf8');
  const section = text.split('### Credentials Embedded in URLs')[1] || '';
  const pattern = /```\n(.+)\n```/.exec(section);
  assert.ok(pattern, 'grep form missing');
  // Same pattern, written with plain groups for grep -E
  assert.strictEqual(pattern[1], CREDENTIAL_URL_SOURCE.replace(/\(\?:/g, '('));
});
