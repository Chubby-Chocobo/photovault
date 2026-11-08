'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { resolveDocsRoot } = require('../lib/resolve-docs-root.cjs');

function project(config) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'docs-root-'));
  if (config !== undefined) {
    fs.mkdirSync(path.join(dir, '.claude', 'config'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.claude', 'config', 'adf-config.json'),
      typeof config === 'string' ? config : JSON.stringify(config));
  }
  return dir;
}

test('defaults to docs under the project', () => {
  const dir = project();
  assert.strictEqual(resolveDocsRoot({ projectDir: dir, env: {} }), path.join(dir, 'docs'));
});

test('env ADF_DOCS_PATH wins when absolute', () => {
  const dir = project({ paths: { docs: 'manuals' } });
  const abs = path.join(os.tmpdir(), 'elsewhere-docs');
  assert.strictEqual(resolveDocsRoot({ projectDir: dir, env: { ADF_DOCS_PATH: abs } }), abs);
});

test('relative env value is ignored', () => {
  const dir = project();
  assert.strictEqual(resolveDocsRoot({ projectDir: dir, env: { ADF_DOCS_PATH: 'x' } }), path.join(dir, 'docs'));
});

test('config paths.docs overrides default', () => {
  const dir = project({ paths: { docs: 'manuals' } });
  assert.strictEqual(resolveDocsRoot({ projectDir: dir, env: {} }), path.join(dir, 'manuals'));
});

test('absolute, parent-escaping or malformed config falls back to docs', () => {
  for (const cfg of [{ paths: { docs: '/etc' } }, { paths: { docs: '../x' } }, { paths: { docs: 5 } }, '{bad']) {
    const dir = project(cfg);
    assert.strictEqual(resolveDocsRoot({ projectDir: dir, env: {} }), path.join(dir, 'docs'));
  }
});
