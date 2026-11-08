'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const { parseArgs } = require('./brief-scan.cjs');
const { resolveTimeframe, previousWindow } = require('./lib/retro-timeframe.cjs');
const { isTestFile } = require('./lib/retro-metrics.cjs');
const { parseLog } = require('./lib/retro-metrics.cjs');
const { buildRetroPayload, renderRetroMarkdown } = require('./lib/retro-report.cjs');

const NOW = new Date(2026, 2, 15, 12, 0, 0);

function git(cwd, args, date) {
  const env = { ...process.env };
  if (date) Object.assign(env, { GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date });
  const result = spawnSync('git', args, { cwd, encoding: 'utf8', env });
  assert.equal(result.status, 0, `git ${args.join(' ')} failed\n${result.stderr}`);
  return (result.stdout || '').trim();
}

function commit(repo, files, message, date, author) {
  for (const [file, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(repo, file)), { recursive: true });
    fs.writeFileSync(path.join(repo, file), content);
  }
  git(repo, ['add', '.']);
  git(repo, ['-c', `user.name=${author}`, '-c', `user.email=${author.toLowerCase()}@example.com`, 'commit', '-m', message], date);
}

// One commit before the previous window, one in it, three in the 7-day window, one after "now".
function createRetroRepo() {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'brief-retro-'));
  git(repo, ['init', '-b', 'main']);
  commit(repo, { 'README.md': '# fixture\n' }, 'chore: initial', '2026-02-01T10:00:00', 'Alice');
  commit(repo, { 'src/parser.js': 'a\nb\nc\n' }, 'feat: add parser', '2026-03-05T10:00:00', 'Alice');
  commit(repo, {
    'src/parser.js': 'a\nB\nc\n',
    'src/parser.test.js': 't1\nt2\n',
    'plans/260310-parser/plan.md': '# Parser\n- [x] parse\n- [ ] errors\n',
  }, 'fix(parser): handle empty input', '2026-03-10T10:00:00', 'Alice');
  commit(repo, { 'docs/notes.md': 'note\n' }, 'docs: notes', '2026-03-10T15:00:00', 'Bob');
  commit(repo, { 'README.md': '# fixture\nmore\n', 'img.png': Buffer.from([0, 1, 2, 0, 255]) }, 'update readme', '2026-03-12T10:00:00', 'Bob');
  commit(repo, { 'late.md': 'late\n' }, 'feat: after the window', '2026-03-20T10:00:00', 'Bob');
  return repo;
}

test('resolveTimeframe handles relative windows, inclusive ranges and errors', () => {
  const week = resolveTimeframe('7d', { now: NOW });
  assert.equal(week.days, 7);
  assert.deepEqual([week.since.getDate(), week.since.getHours()], [9, 0]);
  assert.equal(resolveTimeframe('2w', { now: NOW }).days, 14);
  const endOfMarch = resolveTimeframe('1m', { now: new Date(2026, 2, 31, 9) });
  assert.deepEqual([endOfMarch.since.getMonth(), endOfMarch.since.getDate()], [2, 1]);
  assert.equal(resolveTimeframe(undefined, { now: NOW }).label, '7d');
  const month = resolveTimeframe('1m', { now: NOW });
  assert.deepEqual([month.since.getMonth(), month.since.getDate()], [1, 16]);
  const range = resolveTimeframe('2026-03-01:2026-03-02', { now: NOW });
  assert.equal(range.days, 2);
  assert.equal(range.until.getDate(), 3);
  assert.throws(() => resolveTimeframe('2026-02-30:2026-03-02', { now: NOW }), /not a valid date/);
  assert.throws(() => resolveTimeframe('2026-03-05:2026-03-01', { now: NOW }), /empty/);
  assert.throws(() => resolveTimeframe('0d', { now: NOW }), /at least 1/);
  assert.throws(() => resolveTimeframe('weekly', { now: NOW }), /unknown timeframe/);
  assert.throws(() => resolveTimeframe('sprint', { now: NOW }), /latest git tag/);
  assert.equal(resolveTimeframe('sprint', { now: NOW, latestTagDate: '2026-03-01T00:00:00Z' }).label, 'sprint');
});

test('previousWindow covers the same calendar days and ends before the window', () => {
  const window = resolveTimeframe('2026-03-08:2026-03-14', { now: NOW });
  const previous = previousWindow(window);
  assert.equal(previous.until.getTime(), window.since.getTime() - 1000);
  assert.deepEqual([previous.since.getDate(), previous.since.getHours(), previous.days], [1, 0, 7]);
});

test('a range across a daylight-saving change keeps its calendar length', () => {
  const script = `const { resolveTimeframe, previousWindow } = require(${JSON.stringify(require.resolve('./lib/retro-timeframe.cjs'))});
    const w = resolveTimeframe('2026-10-26:2026-11-01');
    const p = previousWindow(w);
    console.log(JSON.stringify([w.days, p.since.getHours(), p.since.getDate()]));`;
  const result = spawnSync(process.execPath, ['-e', script], { env: { ...process.env, TZ: 'America/New_York' }, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), [7, 0, 19]);
});

test('parseArgs reads the retro timeframe and flags', () => {
  assert.equal(parseArgs(['--retro']).timeframe, undefined);
  assert.equal(parseArgs(['--retro', '--compare', '2w']).timeframe, '2w');
  assert.equal(parseArgs(['--retro', 'sprint', '--format', 'html']).format, 'html');
  assert.throws(() => parseArgs(['--retro', '--format', 'pdf']), /md or html/);
  assert.throws(() => parseArgs(['7d']), /Unknown option/);
  const options = parseArgs(['--retro', '2w', '--compare', '--team', '--issues', '--json']);
  assert.deepEqual(
    [options.retro, options.timeframe, options.compare, options.team, options.issues, options.json],
    [true, '2w', true, true, true, true],
  );
});

test('parseLog counts binary files with no lines and keeps the new path of a rename', () => {
  const [entry] = parseLog('\x1eabc\x1f2026-03-01T00:00:00+00:00\x1fa@x\x1fA\x1ffeat: x\n\n-\t-\timg.png\n3\t1\tsrc/a.js\n'
    + '0\t0\tsrc/{old => new}/b.js\n1\t0\tsrc/{ => lib}/c.js\n2\t2\tread.md => docs/read.md\n');
  assert.deepEqual(entry.files.map((file) => file.path), ['img.png', 'src/a.js', 'src/new/b.js', 'src/lib/c.js', 'docs/read.md']);
  assert.deepEqual(entry.files[0], { path: 'img.png', added: 0, removed: 0 });
});

test('isTestFile recognizes common test layouts only', () => {
  for (const file of ['src/a.test.ts', 'a.spec.js', '__tests__/x.js', 'tests/unit/x.py', 'pkg/test_x.py', 'pkg/x_test.go']) {
    assert.ok(isTestFile(file), file);
  }
  for (const file of ['src/latest_value.py', 'src/contest.js', 'docs/testing.md']) assert.ok(!isTestFile(file), file);
});

test('buildRetroPayload computes metrics for the window only', () => {
  const repo = createRetroRepo();
  try {
    const payload = buildRetroPayload(repo, { timeframe: '7d', compare: true, team: true }, NOW);
    const cur = payload.current;
    assert.equal(cur.commits, 3);
    assert.equal(cur.activeDays, 2);
    assert.equal(cur.commitsPerDay, 0.43);
    assert.equal(cur.filesChanged, 6);
    assert.equal(cur.testFileChanges, 1);
    assert.equal(cur.testRatio, 16.7);
    assert.deepEqual(cur.loc, { added: 8, removed: 1, net: 7 });
    assert.equal(cur.churnRate, 1.29);
    assert.deepEqual(cur.commitTypes.map((entry) => entry.type), ['docs', 'fix', 'other']);
    assert.deepEqual(cur.authors.map((author) => [author.name, author.commits]), [['Bob', 2], ['Alice', 1]]);
    assert.deepEqual(payload.plans, {
      plans: [{ dir: 'plans/260310-parser', closed: 1, open: 1 }], closed: 1, open: 1, completion: 50,
    });
    assert.equal(payload.previous.commits, 1);
    assert.equal(payload.issues, null);
    assert.equal(payload.reportPath, 'plans/reports/retro-260315-7d.md');
    assert.ok(cur.activeDays <= cur.periodDays);
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});

test('renderRetroMarkdown prints deltas, team rows and N/A for missing data', () => {
  const repo = createRetroRepo();
  try {
    const markdown = renderRetroMarkdown(buildRetroPayload(repo, { timeframe: '7d', compare: true, team: true }, NOW));
    assert.match(markdown, /\| Total commits \| 3 \| \+2 \|/);
    assert.match(markdown, /\| Bob \| 2 \| 2 \| docs 1, other 1 \|/);
    assert.match(markdown, /\| Issues closed \(period\) \| N\/A \|/);
    assert.match(markdown, /run with --issues/);

    assert.match(markdown, /^<!-- save as plans\/reports\/retro-260315-7d\.md -->/);
    assert.match(markdown, /reachable from main, merges excluded/);

    const plainPayload = buildRetroPayload(repo, { timeframe: '7d' }, NOW);
    assert.doesNotMatch(JSON.stringify(plainPayload), /example\.com|Alice|Bob/);
    const plain = renderRetroMarkdown(plainPayload);
    assert.doesNotMatch(plain, /vs previous/);
    assert.doesNotMatch(plain, /Team Breakdown/);
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});

test('an empty window reports N/A instead of zero ratios', () => {
  const repo = createRetroRepo();
  try {
    const payload = buildRetroPayload(repo, { timeframe: '2025-01-01:2025-01-02' }, NOW);
    assert.equal(payload.current.commits, 0);
    assert.equal(payload.current.testRatio, null);
    assert.equal(payload.current.churnRate, null);
    assert.match(renderRetroMarkdown(payload), /Churn rate \| N\/A/);
    assert.ok(payload.warnings.includes('No commits in this window.'));
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});

test('merges are skipped, renames are not churn and non-ASCII plan paths are read', () => {
  const repo = createRetroRepo();
  try {
    git(repo, ['checkout', '-q', '-b', 'side', 'HEAD~1']);
    commit(repo, { 'plans/260313-ü/plan.md': '# Ü\n- [x] done\n' }, 'docs: plan', '2026-03-13T10:00:00', 'Alice');
    git(repo, ['checkout', '-q', 'main']);
    git(repo, ['-c', 'user.name=Bob', '-c', 'user.email=bob@example.com', 'merge', '--no-ff', '-q', '-m', 'merge side', 'side'], '2026-03-14T10:00:00');
    git(repo, ['mv', 'src/parser.js', 'src/core-parser.js']);
    git(repo, ['-c', 'user.name=Bob', '-c', 'user.email=bob@example.com', 'commit', '-q', '-m', 'refactor: rename parser'], '2026-03-14T11:00:00');
    const payload = buildRetroPayload(repo, { timeframe: '7d' }, NOW);
    assert.equal(payload.current.commits, 5);
    assert.equal(payload.current.commitTypes.find((entry) => entry.type === 'other').count, 1);
    assert.ok(payload.current.hotspots.some((spot) => spot.path === 'src/core-parser.js'));
    assert.deepEqual(payload.plans.plans.map((plan) => plan.dir), ['plans/260310-parser', 'plans/260313-ü']);
    assert.equal(payload.current.loc.added, 10); // 8 before, 2 in the new plan, 0 for the pure rename
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});

test('a repo with no commits reports an empty window', () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'brief-retro-empty-'));
  try {
    git(repo, ['init', '-b', 'main']);
    const payload = buildRetroPayload(repo, { timeframe: '7d' }, NOW);
    assert.equal(payload.current.commits, 0);
    assert.ok(payload.warnings.includes('No commits in this window.'));
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});

test('sprint starts at the latest tag', () => {
  const repo = createRetroRepo();
  try {
    git(repo, ['tag', 'v1.0.0', 'HEAD~2']);
    const payload = buildRetroPayload(repo, { timeframe: 'sprint' }, NOW);
    assert.equal(payload.window.label, 'sprint');
    assert.equal(payload.current.commits, 1);
  } finally {
    fs.rmSync(repo, { recursive: true, force: true });
  }
});
