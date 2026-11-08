#!/usr/bin/env node

const { afterEach, beforeEach, describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

// A private log dir, so hooks spawned by other test files cannot change the line counts asserted here
process.env.ADF_HOOK_LOG_DIR = fs.mkdtempSync(path.join(require('os').tmpdir(), 'hook-logger-test-'));
process.on('exit', () => fs.rmSync(process.env.ADF_HOOK_LOG_DIR, { recursive: true, force: true }));
const LOG_FILE = path.join(process.env.ADF_HOOK_LOG_DIR, 'hook-log.jsonl');
const { createHookTimer, logHook, logHookCrash } = require('../lib/hook-logger.cjs');

let originalExists = false;
let originalContent = '';

function readEntries() {
  if (!fs.existsSync(LOG_FILE)) return [];
  return fs.readFileSync(LOG_FILE, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map(line => JSON.parse(line));
}

beforeEach(() => {
  originalExists = fs.existsSync(LOG_FILE);
  originalContent = originalExists ? fs.readFileSync(LOG_FILE, 'utf8') : '';
  fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true });
  fs.writeFileSync(LOG_FILE, '', 'utf8');
});

afterEach(() => {
  if (originalExists) {
    fs.writeFileSync(LOG_FILE, originalContent, 'utf8');
  } else if (fs.existsSync(LOG_FILE)) {
    fs.unlinkSync(LOG_FILE);
  }
});

describe('hook-logger', () => {
  it('writes structured hook fields', () => {
    logHook('privacy-block', {
      event: 'PreToolUse',
      tool: 'Grep',
      target: '.env',
      note: 'approval-required',
      status: 'block',
      exit: 2
    });

    const [entry] = readEntries();
    assert.strictEqual(entry.hook, 'privacy-block');
    assert.strictEqual(entry.event, 'PreToolUse');
    assert.strictEqual(entry.tool, 'Grep');
    assert.strictEqual(entry.target, '.env');
    assert.strictEqual(entry.note, 'approval-required');
    assert.strictEqual(entry.status, 'block');
    assert.strictEqual(entry.exit, 2);
  });

  it('merges base timer fields into the final entry', async () => {
    const timer = createHookTimer('usage-context-awareness', {
      event: 'PostToolUse',
      tool: 'Grep'
    });

    await new Promise(resolve => setTimeout(resolve, 5));
    timer.end({ status: 'skip', note: 'throttled' });

    const [entry] = readEntries();
    assert.strictEqual(entry.hook, 'usage-context-awareness');
    assert.strictEqual(entry.event, 'PostToolUse');
    assert.strictEqual(entry.tool, 'Grep');
    assert.strictEqual(entry.status, 'skip');
    assert.strictEqual(entry.note, 'throttled');
    assert.ok(entry.dur >= 0);
  });

  it('normalizes crash logging', () => {
    logHookCrash('scout-block', new Error('boom'), { event: 'PreToolUse', tool: 'Read' });

    const [entry] = readEntries();
    assert.strictEqual(entry.hook, 'scout-block');
    assert.strictEqual(entry.event, 'PreToolUse');
    assert.strictEqual(entry.tool, 'Read');
    assert.strictEqual(entry.status, 'crash');
    assert.strictEqual(entry.error, 'boom');
  });

  it('rotates under lock and preserves the newest entries', () => {
    const lines = [];
    for (let i = 0; i < 1000; i++) {
      lines.push(JSON.stringify({ ts: `2026-03-18T12:00:${String(i % 60).padStart(2, '0')}.000Z`, hook: 'seed', status: 'ok', note: String(i) }));
    }
    fs.writeFileSync(LOG_FILE, lines.join('\n') + '\n', 'utf8');

    logHook('hook-logger', { status: 'ok', note: 'latest' });

    const entries = readEntries();
    assert.strictEqual(entries.length, 500);
    assert.strictEqual(entries.at(-1).note, 'latest');
  });

  describe('lock left behind by a killed hook', () => {
    const LOCK_FILE = path.join(path.dirname(LOG_FILE), 'hook-log.lock');
    const seed = () => fs.writeFileSync(LOG_FILE,
      Array.from({ length: 1000 }, (_, i) => JSON.stringify({ hook: 'seed', note: String(i) })).join('\n') + '\n', 'utf8');
    afterEach(() => fs.rmSync(LOCK_FILE, { force: true }));

    it('is removed when stale, so rotation keeps working', () => {
      seed();
      fs.writeFileSync(LOCK_FILE, '');
      const old = new Date(Date.now() - 60000);
      fs.utimesSync(LOCK_FILE, old, old);

      logHook('hook-logger', { status: 'ok', note: 'latest' });

      assert.strictEqual(readEntries().length, 500);
      assert.ok(!fs.existsSync(LOCK_FILE));
    });

    it('is left alone while fresh, and the entry is still written', () => {
      fs.writeFileSync(LOCK_FILE, '');

      logHook('hook-logger', { status: 'ok', note: 'latest' });

      assert.strictEqual(readEntries().at(-1).note, 'latest');
      assert.ok(fs.existsSync(LOCK_FILE));
    });
  });
});
