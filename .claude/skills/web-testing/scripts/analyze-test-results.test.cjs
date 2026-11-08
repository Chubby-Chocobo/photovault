'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const SCRIPT = path.join(__dirname, 'analyze-test-results.cjs');

function analyze(t, flag, content, extra = []) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-analyze-results-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'results');
  fs.writeFileSync(file, content);
  const r = spawnSync(process.execPath, [SCRIPT, `--${flag}`, file, '--output', 'json', ...extra], { encoding: 'utf8' });
  const jsonStart = r.stdout.indexOf('{');
  return { status: r.status, summary: jsonStart === -1 ? null : JSON.parse(r.stdout.slice(jsonStart)) };
}

describe('analyze-test-results JUnit', () => {
  const ROOT_WITH_ERRORS = `<?xml version="1.0"?>
<testsuites name="jest tests" tests="3" failures="0" errors="2" time="1.5">
  <testsuite name="suite A" tests="3" failures="0" errors="2" skipped="0" time="1.5">
    <testcase name="ok" classname="A" time="0.1"/>
    <testcase name="boom" classname="A" time="0.2"><error message="exploded">TypeError: x</error></testcase>
    <testcase name="bang" classname="A" time="0.2"><error message="exploded">RangeError: y</error></testcase>
  </testsuite>
</testsuites>`;

  it('counts each test once when a testsuites root wraps the suites', (t) => {
    const { summary } = analyze(t, 'junit', ROOT_WITH_ERRORS);
    assert.equal(summary.total, 3);
    assert.equal(summary.suites.length, 1);
  });

  it('counts errored tests as failed, not passed', (t) => {
    const { summary } = analyze(t, 'junit', ROOT_WITH_ERRORS);
    assert.equal(summary.passed, 1);
    assert.equal(summary.failed, 2);
    assert.deepEqual(summary.failures.map((f) => f.name), ['boom', 'bang']);
  });

  it('fails the pass-rate threshold when tests errored', (t) => {
    const { status } = analyze(t, 'junit', ROOT_WITH_ERRORS, ['--fail-threshold', '90']);
    assert.equal(status, 1);
  });

  it('does not blame a passing testcase for a later failure', (t) => {
    const xml = '<testsuite name="s" tests="2" failures="1"><testcase name="good"/><testcase name="bad"><failure>nope</failure></testcase></testsuite>';
    const { summary } = analyze(t, 'junit', xml);
    assert.deepEqual(summary.failures.map((f) => f.name), ['bad']);
  });
});

describe('analyze-test-results Playwright', () => {
  it('keeps a suite whose tests all failed', (t) => {
    const json = JSON.stringify({
      suites: [{ title: 'login', specs: [{ title: 'a', tests: [{ status: 'unexpected', results: [{ error: { message: 'bad' } }] }] }] }],
    });
    const { summary } = analyze(t, 'playwright', json);
    assert.equal(summary.failed, 1);
    assert.deepEqual(summary.suites.map((s) => [s.name, s.failed]), [['login', 1]]);
  });
});

describe('init-playwright', () => {
  it('generates a config that loads the global setup file it writes', (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-init-playwright-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const r = spawnSync(process.execPath, [path.join(__dirname, 'init-playwright.cjs'), '--dir', dir], { encoding: 'utf8' });
    assert.equal(r.status, 0);
    const config = fs.readFileSync(path.join(dir, 'playwright.config.ts'), 'utf8');
    assert.match(config, /globalSetup: '\.\/tests\/e2e\/global-setup\.ts'/);
    assert.ok(fs.existsSync(path.join(dir, 'tests/e2e/global-setup.ts')));
  });
});
