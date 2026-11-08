#!/usr/bin/env node
/**
 * Tests for component-stack.cjs
 * Run: node --test .claude/skills/workspace/scripts/tests/component-stack.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { STACKS, STACK_ROLES, detectStack } = require('../lib/component-stack.cjs');

function component(t, files) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-stack-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const [rel, content] of Object.entries(files)) fs.writeFileSync(path.join(dir, rel), typeof content === 'string' ? content : JSON.stringify(content));
  return dir;
}

describe('detectStack', () => {
  const cases = [
    ['nestjs', { 'package.json': { dependencies: { '@nestjs/core': '^10.0.0' } } }],
    ['nestjs', { 'package.json': { devDependencies: { '@nestjs/core': '^10.0.0' } } }],
    ['react-native', { 'package.json': { dependencies: { 'react-native': '0.74.0', react: '18' } } }],
    ['vue', { 'package.json': { dependencies: { vue: '^3.4.0' } } }],
    ['vue', { 'package.json': { dependencies: { nuxt: '^3.0.0' } } }],
    ['maven', { 'pom.xml': '<project/>' }],
    ['foundry', { 'foundry.toml': '[profile.default]\n' }],
    ['python', { 'pyproject.toml': '[project]\nname = "x"\n' }],
    ['python', { 'requirements.txt': 'flask\n' }],
    ['unknown', { 'package.json': { dependencies: { express: '^4.0.0' } } }],
    ['unknown', { 'go.mod': 'module x\n' }],
    ['unknown', {}],
  ];
  for (const [stack, files] of cases) {
    it(`${stack} from ${Object.keys(files).join(', ') || 'an empty dir'}`, (t) => {
      assert.strictEqual(detectStack(component(t, files)), stack);
    });
  }

  it('prefers a package.json framework over other markers', (t) => {
    assert.strictEqual(detectStack(component(t, { 'package.json': { dependencies: { '@nestjs/core': '1' } }, 'pom.xml': '<project/>' })), 'nestjs');
  });

  it('survives an unreadable package.json, an array package.json and a missing dir', (t) => {
    assert.strictEqual(detectStack(component(t, { 'package.json': '{ nope' })), 'unknown');
    assert.strictEqual(detectStack(component(t, { 'package.json': '[]', 'pom.xml': '<project/>' })), 'maven');
    assert.strictEqual(detectStack(path.join(os.tmpdir(), 'adf-stack-does-not-exist')), 'unknown');
  });

  it('only returns listed stacks and maps every stack to a role', () => {
    assert.deepStrictEqual(STACKS, ['nestjs', 'react-native', 'vue', 'maven', 'foundry', 'python', 'unknown']);
    assert.deepStrictEqual(Object.keys(STACK_ROLES), STACKS);
  });
});
