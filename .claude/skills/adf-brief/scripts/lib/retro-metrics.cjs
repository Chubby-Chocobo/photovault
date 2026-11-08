'use strict';

// Git-history metrics for the retro mode. Every number comes from one `git log --numstat`
// pass over the window; a metric with no data is null so the report prints N/A, never a guess.

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { scanPlanDirectory } = require('./checkboxes.cjs');
const { localDay } = require('./retro-timeframe.cjs');

const RECORD = '\x1e';
const FIELD = '\x1f';
// Test directories, *.test.* / *.spec.*, test_*.py and Go/Python *_test.* files.
const TEST_FILE_RE = /(^|\/)(__tests__|tests?)\/|\.(test|spec)\.[^/]+$|(^|\/)test_[^/]+$|_test\.[^/]+$/;
const COMMIT_TYPE_RE = /^([a-z]+)(\([^)]*\))?!?:/i;
const PLAN_SKIP_RE = /(^|\/)(reports|research|templates)\//;

function git(root, args) {
  const result = spawnSync('git', args, { cwd: root, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 });
  if (result.status !== 0) {
    throw new Error(`git ${args[0]} failed: ${(result.stderr || result.error?.message || '').trim()}`);
  }
  return result.stdout || '';
}

function latestTagDate(root) {
  const result = spawnSync('git', ['log', '-1', '--no-walk', '--tags', '--format=%cI'], { cwd: root, encoding: 'utf8' });
  const value = (result.stdout || '').trim();
  return result.status === 0 && value ? value : null;
}

// numstat writes a rename as "old => new" or "dir/{old => new}/file"; keep the new path.
function renamedPath(value) {
  const braced = /^(.*)\{(.*) => (.*)\}(.*)$/.exec(value);
  if (braced) return `${braced[1]}${braced[3]}${braced[4]}`.replace(/\/\//g, '/');
  const plain = /^(.*) => (.*)$/.exec(value);
  return plain ? plain[2] : value;
}

function parseLog(output) {
  const commits = [];
  for (const record of output.split(RECORD)) {
    if (!record.trim()) continue;
    const [header, ...lines] = record.split('\n');
    const [hash, date, email, name, subject = ''] = header.split(FIELD);
    const files = [];
    for (const line of lines) {
      const match = /^(-|\d+)\t(-|\d+)\t(.+)$/.exec(line);
      if (!match) continue;
      files.push({
        path: renamedPath(match[3]),
        added: match[1] === '-' ? 0 : Number(match[1]),
        removed: match[2] === '-' ? 0 : Number(match[2]),
      });
    }
    commits.push({ hash, date, email, name, subject, files });
  }
  return commits;
}

// Non-merge commits reachable from HEAD in the window. Renames are detected so a moved file
// is not counted as a full delete plus add; .mailmap folds an author's emails into one.
function readCommits(root, window) {
  if (spawnSync('git', ['rev-parse', '--verify', '--quiet', 'HEAD'], { cwd: root }).status !== 0) return [];
  return parseLog(git(root, [
    '-c', 'core.quotePath=false', 'log', '--no-merges', '-M',
    `--since=${window.since.toISOString()}`, `--until=${window.until.toISOString()}`,
    '--numstat', `--format=${RECORD}%H${FIELD}%cI${FIELD}%aE${FIELD}%aN${FIELD}%s`,
  ]));
}

function isTestFile(file) {
  return TEST_FILE_RE.test(file);
}

function commitType(subject) {
  const match = COMMIT_TYPE_RE.exec(subject);
  return match ? match[1].toLowerCase() : 'other';
}

const round = (value, digits = 2) => Math.round(value * 10 ** digits) / 10 ** digits;
const percent = (part, whole) => (whole > 0 ? round((part / whole) * 100, 1) : null);
const sortCounts = (map) => [...map.entries()].sort((a, b) => (b[1] - a[1]) || a[0].localeCompare(b[0]));

// Checkbox progress of the plan directories that commits in the window touched.
function planProgress(root, commits, warnings) {
  const dirs = new Set();
  for (const commit of commits) {
    for (const file of commit.files) {
      if (file.path.startsWith('plans/') && file.path.endsWith('.md') && !PLAN_SKIP_RE.test(file.path)) {
        dirs.add(path.posix.dirname(file.path));
      }
    }
  }
  const plans = [];
  for (const dir of [...dirs].sort()) {
    if (!fs.existsSync(path.join(root, dir, 'plan.md'))) continue;
    const progress = scanPlanDirectory(path.join(root, dir), warnings);
    if (progress) plans.push({ dir, closed: progress.closed, open: progress.open });
  }
  const closed = plans.reduce((sum, plan) => sum + plan.closed, 0);
  const open = plans.reduce((sum, plan) => sum + plan.open, 0);
  return { plans, closed, open, completion: percent(closed, closed + open) };
}

function summarize(commits, window) {
  const days = new Set();
  const files = new Map();
  const types = new Map();
  const authors = new Map();
  let added = 0;
  let removed = 0;
  let fileChanges = 0;
  let testFileChanges = 0;
  for (const commit of commits) {
    days.add(localDay(new Date(commit.date)));
    const type = commitType(commit.subject);
    types.set(type, (types.get(type) || 0) + 1);
    const author = authors.get(commit.email) || { email: commit.email, name: commit.name, commits: 0, added: 0, removed: 0, types: new Map() };
    author.commits += 1;
    author.types.set(type, (author.types.get(type) || 0) + 1);
    for (const file of commit.files) {
      files.set(file.path, (files.get(file.path) || 0) + 1);
      fileChanges += 1;
      if (isTestFile(file.path)) testFileChanges += 1;
      added += file.added;
      removed += file.removed;
      author.added += file.added;
      author.removed += file.removed;
    }
    authors.set(commit.email, author);
  }
  const net = added - removed;
  return {
    commits: commits.length,
    commitsPerDay: round(commits.length / window.days),
    activeDays: days.size,
    periodDays: window.days,
    activeDayRatio: percent(days.size, window.days),
    filesChanged: files.size,
    fileChanges,
    testFileChanges,
    testRatio: percent(testFileChanges, fileChanges),
    loc: { added, removed, net },
    churnRate: added + removed > 0 ? round((added + removed) / Math.max(Math.abs(net), 1)) : null,
    commitTypes: sortCounts(types).map(([type, count]) => ({ type, count, percent: percent(count, commits.length) })),
    hotspots: sortCounts(files).slice(0, 10).map(([file, changes]) => ({ path: file, changes })),
    authors: [...authors.values()]
      .sort((a, b) => (b.commits - a.commits) || a.email.localeCompare(b.email))
      .map((author) => ({
        email: author.email,
        name: author.name,
        commits: author.commits,
        added: author.added,
        removed: author.removed,
        net: author.added - author.removed,
        types: sortCounts(author.types).map(([type, count]) => ({ type, count })),
      })),
  };
}

// Issue search has day granularity: count issues created or closed on the window's days.
function countIssues(root, window, warnings) {
  const range = `${localDay(window.since)}..${localDay(new Date(window.until - 1))}`;
  const count = (search, state) => {
    const result = spawnSync('gh', ['issue', 'list', '--state', state, '--search', search, '--limit', '1000', '--json', 'number'], { cwd: root, encoding: 'utf8' });
    if (result.status !== 0) throw new Error((result.stderr || result.error?.message || 'gh failed').trim());
    return JSON.parse(result.stdout || '[]').length;
  };
  try {
    return { opened: count(`created:${range}`, 'all'), closed: count(`closed:${range}`, 'closed') };
  } catch (error) {
    warnings.push(`GitHub issue counts unavailable: ${error.message.split('\n')[0]}`);
    return null;
  }
}

module.exports = { countIssues, isTestFile, latestTagDate, parseLog, planProgress, readCommits, summarize };
