#!/usr/bin/env node
/**
 * Tests for front-matter.cjs
 * Run: node --test .claude/hooks/lib/__tests__/front-matter.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { parseFrontmatter, toList } = require('../front-matter.cjs');

describe('parseFrontmatter', () => {
  it('reads plain, quoted and numeric values and skips comments and blank lines', () => {
    const data = parseFrontmatter('---\ntitle: "Add login"\nstatus: in-progress\n\n# note\nphase: 4\nname: \'x y\'\n---\n# Body\n');
    assert.deepStrictEqual(data, { title: 'Add login', status: 'in-progress', phase: '4', name: 'x y' });
  });

  it('returns {} without a front matter block', () => {
    assert.deepStrictEqual(parseFrontmatter('# Title\n\ntext'), {});
    assert.deepStrictEqual(parseFrontmatter(''), {});
  });

  it('handles CRLF', () => {
    assert.deepStrictEqual(parseFrontmatter('---\r\ntitle: A\r\nstatus: done\r\n---\r\nbody'), { title: 'A', status: 'done' });
  });

  it('keeps an inline list as a string for callers that do not know lists', () => {
    assert.strictEqual(parseFrontmatter('---\nscope: [services/order, contracts/proto]\n---\n').scope, '[services/order, contracts/proto]');
  });

  it('turns an empty value followed by "- item" lines into an array, dropping trailing comments and quotes', () => {
    const data = parseFrontmatter('---\nscope:\n  - services/order  # the service\n  - "contracts/proto"\n  - \'apps/web\'\nstatus: pending\n---\n');
    assert.deepStrictEqual(data.scope, ['services/order', 'contracts/proto', 'apps/web']);
    assert.strictEqual(data.status, 'pending');
  });

  it('keeps an empty value as an empty string when no list follows', () => {
    const data = parseFrontmatter('---\nscope:\nstatus: pending\n---\n');
    assert.strictEqual(data.scope, '');
    assert.strictEqual(data.status, 'pending');
  });

  it('does not read list items after a non-empty value', () => {
    const data = parseFrontmatter('---\ntitle: A\n  - not a list\nstatus: x\n---\n');
    assert.strictEqual(data.title, 'A');
    assert.strictEqual(data.status, 'x');
  });
});

describe('toList', () => {
  const listOf = (lines) => toList(parseFrontmatter(`---\n${lines.join('\n')}\n---\n`).items);

  it('reads an inline list, with quotes and a trailing comment', () => {
    assert.deepStrictEqual(listOf(['items: [a/b, "c d", \'e\']  # note']), ['a/b', 'c d', 'e']);
  });

  it('reads a block list and one comma-separated value', () => {
    assert.deepStrictEqual(listOf(['items:', '  - a  # one', '  - "b"']), ['a', 'b']);
    assert.deepStrictEqual(listOf(['items: a, b']), ['a', 'b']);
  });

  it('parses the numeric dependency form that parseFrontmatter leaves as a string', () => {
    assert.deepStrictEqual(listOf(['items: [1, 2]']), ['1', '2']);
  });

  it('returns [] for nothing, an empty or unclosed list, or a non-string value', () => {
    assert.deepStrictEqual(listOf([]), []);
    assert.deepStrictEqual(listOf(['items: []']), []);
    assert.deepStrictEqual(listOf(['items: [a, b']), []);
    assert.deepStrictEqual(toList(undefined), []);
    assert.deepStrictEqual(toList(7), []);
    assert.deepStrictEqual(toList(['a', 3, 'b']), ['a', 'b']);
  });
});
