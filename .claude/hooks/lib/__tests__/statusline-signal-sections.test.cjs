'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { setColorEnabled } = require('../colors.cjs');
const { SIGNAL_SECTION_RENDERERS: { cache, pr, verify }, hyperlink, toEpochMs } = require('../statusline-signal-sections.cjs');
const { getSectionRenderer } = require('../statusline-section-registry.cjs');
const { visibleLength } = require('../statusline-string-utils.cjs');

const strip = (text) => String(text).replace(/\x1b\[[0-9;]*m/g, '');
const theme = { accent: 'cyan', contextLow: 'green', contextMid: 'yellow', contextHigh: 'red' };
const NOW = Date.parse('2026-10-13T10:00:00Z');

test.beforeEach(() => setColorEnabled(false));
test.after(() => setColorEnabled(null));

test('cache: minutes left while warm; hidden when cold, expired or unknown', () => {
  const at = (ms) => ({ promptCache: { warm: true, expires_at: (NOW + ms) / 1000 }, now: NOW });
  assert.strictEqual(cache(at(42 * 60000), {}), '🧊 42m');
  assert.strictEqual(cache(at(30000), {}), '🧊 1m');
  assert.strictEqual(cache(at(65 * 60000), {}), '🧊 1h 5m');
  assert.strictEqual(cache({ promptCache: { warm: true, expires_at: new Date(NOW + 600000).toISOString() }, now: NOW }, {}), '🧊 10m');
  assert.strictEqual(cache(at(-1000), {}), null);
  assert.strictEqual(cache({ promptCache: { warm: false, expires_at: NOW / 1000 + 600 }, now: NOW }, {}), null);
  assert.strictEqual(cache({ promptCache: { warm: true }, now: NOW }, {}), null);
  assert.strictEqual(cache({}, {}), null);
  assert.strictEqual(toEpochMs(NOW), NOW, 'epoch milliseconds pass through');
});

test('pr: number, review state and kind; hidden without a PR', () => {
  const url = 'https://github.com/o/r/pull/18';
  assert.strictEqual(pr({ pr: { number: 18, url, review_state: 'approved' } }, {}), '🔗 #18 ✓ approved');
  assert.strictEqual(strip(pr({ pr: { number: 18, review_state: 'changes_requested' } }, {})), '🔗 #18 ✎ changes');
  assert.strictEqual(strip(pr({ pr: { number: 7, kind: 'mr', review_state: 'draft' } }, {})), '🔗 !7 ◌ draft');
  assert.strictEqual(strip(pr({ pr: { number: 9 } }, {})), '🔗 #9');
  assert.strictEqual(pr({ pr: { number: '18' } }, {}), null);
  assert.strictEqual(pr({}, {}), null);
});

test('pr link: OSC 8 only with colors on and an http(s) URL; it takes no columns', (t) => {
  const noColor = process.env.NO_COLOR;
  delete process.env.NO_COLOR; // NO_COLOR always wins over setColorEnabled
  t.after(() => { if (noColor !== undefined) process.env.NO_COLOR = noColor; });
  setColorEnabled(true);
  const linked = hyperlink('https://github.com/o/r/pull/18', '#18');
  assert.strictEqual(linked, '\x1b]8;;https://github.com/o/r/pull/18\x1b\\#18\x1b]8;;\x1b\\');
  assert.strictEqual(visibleLength(linked), 3);
  assert.strictEqual(hyperlink('javascript:alert(1)', '#18'), '#18');
  assert.strictEqual(hyperlink('https://x.test/\x1b]8;;evil', '#18'), '#18', 'control characters cannot break out of the link');
  setColorEnabled(false);
  assert.strictEqual(hyperlink('https://github.com/o/r/pull/18', '#18'), '#18');
});

test('verify: count of edited code files no check has covered', () => {
  assert.strictEqual(verify({ unverifiedCount: 3 }, {}), '⚠ 3 unverified');
  assert.strictEqual(verify({ unverifiedCount: 0 }, {}), null);
});

test('model shows effort and fast mode; context shows tokens above 200k and a /compact hint from 85%', () => {
  const model = getSectionRenderer('model');
  assert.strictEqual(strip(model({ modelName: 'Opus 5.5', effortLevel: 'xhigh', fastMode: true }, {}, theme)), '🤖 Opus 5.5 · xhigh ⚡');
  assert.strictEqual(strip(model({ modelName: 'Opus 5.5' }, {}, theme)), '🤖 Opus 5.5');
  const context = getSectionRenderer('context');
  assert.match(strip(context({ contextPercent: 42, contextSize: 1000000, contextTokens: 420000 }, {}, theme)), /42% 420k\/1M$/);
  assert.match(strip(context({ contextPercent: 42, contextSize: 200000, contextTokens: 84000 }, {}, theme)), /42%$/);
  assert.match(strip(context({ contextPercent: 88, contextSize: 200000, contextTokens: 176000 }, {}, theme)), /88% \/compact$/);
});

test('verify-before-stop can be required without running its hook', () => {
  const result = spawnSync(process.execPath, ['-e', 'const v = require(process.argv[1]); console.log(typeof v.readState, typeof v.statePath)', path.resolve(__dirname, '..', '..', 'verify-before-stop.cjs')], { encoding: 'utf8', input: '' });
  assert.strictEqual(result.status, 0, result.stderr);
  assert.strictEqual(result.stdout.trim(), 'function function');
});

test('statusline end to end: stdin signals and the verify state reach the rendered line', () => {
  const sessionId = `signals-${process.pid}-${Date.now()}`;
  const stateFile = path.join(os.tmpdir(), `adf-verify-${sessionId}.json`);
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'statusline-signals-'));
  fs.mkdirSync(path.join(project, '.claude', 'config'), { recursive: true });
  fs.writeFileSync(path.join(project, '.claude', 'config', 'adf-config.json'), JSON.stringify({ statusline: 'compact' }));
  fs.writeFileSync(stateFile, JSON.stringify({ files: ['src/a.js', 'src/b.js'] }));
  const now = Math.floor(Date.now() / 1000);
  const input = {
    session_id: sessionId,
    model: { display_name: 'Opus 5.5' },
    effort: { level: 'high' },
    workspace: { current_dir: project },
    context_window: { context_window_size: 1000000, used_percentage: 30, total_input_tokens: 300000 },
    prompt_cache: { warm: true, expires_at: now + 1800 },
    pr: { number: 42, url: 'https://github.com/o/r/pull/42', review_state: 'pending' },
  };
  try {
    const result = spawnSync(process.execPath, [path.resolve(__dirname, '..', '..', '..', 'statusline.cjs')], {
      cwd: project, input: JSON.stringify(input), encoding: 'utf8',
      env: { ...process.env, NO_COLOR: '1', CLAUDE_PROJECT_DIR: '', HOME: project },
    });
    assert.strictEqual(result.status, 0, result.stderr);
    const [line1, line2] = result.stdout.trim().split('\n');
    assert.match(line1, /🤖 Opus 5\.5 · high .* 30% 300k\/1M {2}🧊 (29|30)m/);
    assert.match(line2, /🔗 #42 … review {2}⚠ 2 unverified/);
  } finally {
    fs.rmSync(stateFile, { force: true });
    fs.rmSync(path.join(os.tmpdir(), `adf-context-${sessionId}.json`), { force: true });
    fs.rmSync(project, { recursive: true, force: true });
  }
});

test('hardening: inherited review states, 1M rounding, 8-bit controls, stale cache expiry, the cache warning colour', (t) => {
  assert.strictEqual(strip(pr({ pr: { number: 1, review_state: 'constructor' } }, {})), '🔗 #1');
  assert.strictEqual(strip(pr({ pr: { number: 1, review_state: '__proto__' } }, {})), '🔗 #1');
  const context = getSectionRenderer('context');
  assert.match(strip(context({ contextPercent: 99, contextSize: 1000000, contextTokens: 999700 }, {}, theme)), /1M\/1M/);
  assert.strictEqual(cache({ promptCache: { warm: true, expires_at: NOW / 1000 + 2 * 86400 }, now: NOW }, {}), null);

  const noColor = process.env.NO_COLOR;
  delete process.env.NO_COLOR;
  t.after(() => { if (noColor !== undefined) process.env.NO_COLOR = noColor; });
  setColorEnabled(true);
  assert.strictEqual(hyperlink('https://x.test/a\u009cevil', '#1'), '#1');
  const soon = cache({ promptCache: { warm: true, expires_at: NOW / 1000 + 120 }, now: NOW }, {});
  const later = cache({ promptCache: { warm: true, expires_at: NOW / 1000 + 1200 }, now: NOW }, {});
  assert.notStrictEqual(soon.replace('2m', ''), later.replace('20m', ''), 'the last five minutes use a different colour');
  const section = pr({ pr: { number: 18, url: 'https://github.com/o/r/pull/18', review_state: 'approved' } }, {});
  assert.strictEqual(visibleLength(section), visibleLength('🔗 #18 ✓ approved'), 'link and colour codes take no columns');
});

test('full mode: session on the first line; directory, branch, PR and changes on the next', () => {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'statusline-full-'));
  fs.mkdirSync(path.join(project, '.claude', 'config'), { recursive: true });
  fs.writeFileSync(path.join(project, '.claude', 'config', 'adf-config.json'), JSON.stringify({ statusline: 'full' }));
  const input = {
    session_id: `full-${process.pid}-${Date.now()}`,
    model: { display_name: 'Opus 5.5' },
    effort: { level: 'turbo' },
    workspace: { current_dir: project },
    context_window: { context_window_size: 200000, used_percentage: 30 },
    pr: { number: 42, review_state: 'approved' },
    cost: { total_lines_added: 12, total_lines_removed: 3 },
  };
  try {
    const result = spawnSync(process.execPath, [path.resolve(__dirname, '..', '..', '..', 'statusline.cjs')], {
      cwd: project, input: JSON.stringify(input), encoding: 'utf8',
      env: { ...process.env, NO_COLOR: '1', CLAUDE_PROJECT_DIR: '', HOME: project, COLUMNS: '200' },
    });
    assert.strictEqual(result.status, 0, result.stderr);
    const [line1, line2] = result.stdout.trim().split('\n');
    assert.match(line1, /^🤖 Opus 5\.5 {2}▰/, 'an unknown effort level is not shown');
    assert.ok(!line1.includes('📁'));
    assert.match(line2, /^📁 .*🔗 #42 ✓ approved {2}📝 \+12 -3$/);
  } finally {
    fs.rmSync(path.join(os.tmpdir(), `adf-context-${input.session_id}.json`), { force: true });
    fs.rmSync(project, { recursive: true, force: true });
  }
});
