#!/usr/bin/env node
/**
 * Tests for template-render.cjs
 * Run: node --test .claude/skills/workspace/scripts/tests/template-render.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { render, readTemplate, TEMPLATES_DIR } = require('../lib/template-render.cjs');

describe('render', () => {
  it('fills every occurrence of a placeholder', () => {
    assert.strictEqual(render('{{a}} and {{a}} and {{b}}', { a: 'x', b: 2 }), 'x and x and 2');
  });

  it('throws on a missing key and never echoes values', () => {
    assert.throws(() => render('hello {{name}}', {}), /needs a value for "name"/);
    assert.throws(() => render('hello {{name}}', { name: undefined }), /needs a value for "name"/);
    assert.throws(() => render('hello {{toString}}', {}), /needs a value for "toString"/);
  });

  it('throws on a leftover or malformed "{{" in the template or in a value', () => {
    assert.throws(() => render('broken {{ name }}', { name: 'x' }), /leftover/);
    assert.throws(() => render('broken {{name', { name: 'x' }), /leftover/);
    assert.throws(() => render('{{name}}', { name: 'evil {{other}}' }), /leftover/);
  });

  it('inserts values literally, without replacement patterns or a second pass', () => {
    assert.strictEqual(render('[{{v}}]', { v: '$& $1 $`' }), '[$& $1 $`]');
  });

  it('renders a list as "- item" lines and an empty list as "- none"', () => {
    assert.strictEqual(render('{{items}}', { items: ['a', 'b'] }), '- a\n- b');
    assert.strictEqual(render('{{items}}', { items: [] }), '- none');
  });

  it('rejects a value that is neither text nor a list', () => {
    assert.throws(() => render('{{v}}', { v: { a: 1 } }), /must be a string/);
    assert.throws(() => render('{{v}}', { v: null }), /must be a string/);
  });
});

describe('readTemplate', () => {
  it('reads a shipped template and refuses a name that leaves the templates dir', () => {
    assert.match(readTemplate('service-doc'), /^# \{\{name\}\}/);
    for (const bad of ['../x', 'claude-md/../../x', '/etc/passwd', 'claude-md/nestjs.md', '']) {
      assert.throws(() => readTemplate(bad), /invalid template name/, bad);
    }
  });

  it('ships neutral templates: no links with placeholders, no product or client names', () => {
    const files = [...fs.readdirSync(path.join(TEMPLATES_DIR, 'claude-md')).map((f) => path.join('claude-md', f)), 'service-doc.md'];
    assert.strictEqual(files.length, 8);
    for (const rel of files) {
      const text = fs.readFileSync(path.join(TEMPLATES_DIR, rel), 'utf8');
      assert.ok(!/\]\([^)]*\{\{/.test(text), `${rel} has a link with a placeholder`);
      assert.ok(!/adf|claude code|tcx|vdax/i.test(text), `${rel} names a product or client`);
    }
  });
});
