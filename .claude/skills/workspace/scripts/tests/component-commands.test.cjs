#!/usr/bin/env node
/**
 * Tests for component-commands.cjs
 * Run: node --test .claude/skills/workspace/scripts/tests/component-commands.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { commandsFor } = require('../lib/component-commands.cjs');

function component(t, files) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'adf-cmds-')));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const [rel, content] of Object.entries(files)) fs.writeFileSync(path.join(dir, rel), typeof content === 'string' ? content : JSON.stringify(content));
  return dir;
}

const pkg = (scripts) => ({ name: 'x', scripts });

describe('commandsFor: node stacks', () => {
  it('pnpm lockfile and start:dev give pnpm run start:dev', (t) => {
    const dir = component(t, { 'package.json': pkg({ 'start:dev': 'nest start --watch', test: 'jest', lint: 'eslint .' }), 'pnpm-lock.yaml': '' });
    const c = commandsFor(dir, 'nestjs');
    assert.deepStrictEqual([c.run, c.test, c.lint, c.build], ['pnpm run start:dev', 'pnpm run test', 'pnpm run lint', null]);
    assert.deepStrictEqual(c.generatedDirs, ['dist/']);
  });

  it('without a lockfile npm is used, and dev beats serve and start', (t) => {
    const dir = component(t, { 'package.json': pkg({ start: 'node .', serve: 'vite preview', dev: 'vite' }) });
    const c = commandsFor(dir, 'vue');
    assert.strictEqual(c.run, 'npm run dev');
    assert.strictEqual(c.test, null);
    assert.strictEqual(c.lint, null);
  });

  it('start:dev > dev > serve > start, and the other lockfiles map to their manager', (t) => {
    const order = ['start', 'serve', 'dev', 'start:dev'];
    const scripts = {};
    const expected = ['npm run start', 'npm run serve', 'npm run dev', 'npm run start:dev'];
    order.forEach((name, i) => {
      scripts[name] = 'x';
      assert.strictEqual(commandsFor(component(t, { 'package.json': pkg(scripts) }), 'nestjs').run, expected[i]);
    });
    assert.strictEqual(commandsFor(component(t, { 'package.json': pkg({ test: 'x' }), 'yarn.lock': '' }), 'vue').test, 'yarn run test');
    assert.strictEqual(commandsFor(component(t, { 'package.json': pkg({ test: 'x' }), 'bun.lockb': '' }), 'vue').test, 'bun run test');
  });

  it('only fixed script names are used, whatever package.json holds', (t) => {
    const dir = component(t, { 'package.json': pkg({ 'dev; rm -rf /': 'x', '$(id)': 'y', test: 5 }) });
    const c = commandsFor(dir, 'nestjs');
    assert.deepStrictEqual([c.run, c.test, c.lint], [null, null, null]);
  });

  it('handles a missing, broken or non-object package.json', (t) => {
    for (const text of [null, '{ not json', '[]', '{"scripts": 5}']) {
      const dir = component(t, text === null ? {} : { 'package.json': text });
      assert.deepStrictEqual([commandsFor(dir, 'vue').run, commandsFor(dir, 'vue').test], [null, null]);
    }
  });

  it('react-native lists the native build dirs', (t) => {
    assert.deepStrictEqual(commandsFor(component(t, {}), 'react-native').generatedDirs, ['ios/Pods', 'android/build']);
  });
});

describe('commandsFor: other stacks', () => {
  it('maven runs mvn test and ignores target/', (t) => {
    const c = commandsFor(component(t, { 'pom.xml': '<project/>' }), 'maven');
    assert.deepStrictEqual([c.test, c.run, c.lint], ['mvn test', null, null]);
    assert.deepStrictEqual(c.generatedDirs, ['target/']);
  });

  it('foundry builds and tests with forge, and lib/ is vendored', (t) => {
    const c = commandsFor(component(t, { 'foundry.toml': '' }), 'foundry');
    assert.deepStrictEqual([c.build, c.test], ['forge build', 'forge test']);
    assert.deepStrictEqual(c.generatedDirs, ['out/', 'cache/']);
    assert.deepStrictEqual(c.vendoredDirs, ['lib/']);
  });

  it('python uses uv run pytest only with uv.lock', (t) => {
    assert.strictEqual(commandsFor(component(t, { 'pyproject.toml': '' }), 'python').test, 'pytest');
    const uv = commandsFor(component(t, { 'pyproject.toml': '', 'uv.lock': '' }), 'python');
    assert.strictEqual(uv.test, 'uv run pytest');
    assert.deepStrictEqual(uv.generatedDirs, ['.venv']);
  });

  it('an unknown stack has no commands and nothing generated', (t) => {
    const c = commandsFor(component(t, {}), 'unknown');
    assert.deepStrictEqual(c, { run: null, build: null, test: null, lint: null, generatedDirs: [], vendoredDirs: [] });
  });
});

describe('commandsFor: vendored submodules', () => {
  const gitmodules = [
    '[submodule "protos"]\n\tpath = src/protos\n\turl = https://github.com/acme/proto.git',
    '[submodule "thirdparty"]\n\tpath = third_party/sdk\n\turl = https://github.com/other/sdk.git',
    '[submodule "forge-std"]\n\tpath = lib/forge-std\n\turl = https://github.com/acme/forge-std.git',
    '[submodule "odd"]\n\tpath = vendor/$(id)\n\turl = https://github.com/acme/odd.git',
  ].join('\n');

  it('lists submodules classified vendored (other owner or vendor prefix) as safe dir entries', (t) => {
    const dir = component(t, { '.gitmodules': gitmodules });
    assert.deepStrictEqual(commandsFor(dir, 'nestjs', { orgs: ['acme'] }).vendoredDirs, ['third_party/sdk/', 'lib/forge-std/']);
  });

  it('merges with the foundry lib/ without duplicates', (t) => {
    const dir = component(t, { '.gitmodules': gitmodules, 'foundry.toml': '' });
    assert.deepStrictEqual(commandsFor(dir, 'foundry', { orgs: ['acme'] }).vendoredDirs, ['lib/', 'third_party/sdk/', 'lib/forge-std/']);
  });
});
