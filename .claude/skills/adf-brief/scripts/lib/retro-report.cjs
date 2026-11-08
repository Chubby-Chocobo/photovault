'use strict';

// Builds the retro payload (current window, optional previous window, plans, issues) and renders
// its data sections as Markdown. The skill appends Highlights and Recommendations.

const { spawnSync } = require('node:child_process');
const path = require('node:path');
const { localDay, resolveTimeframe, previousWindow } = require('./retro-timeframe.cjs');
const { countIssues, latestTagDate, planProgress, readCommits, summarize } = require('./retro-metrics.cjs');

function reportPath(label, now) {
  const yymmdd = localDay(now).slice(2).replace(/-/g, '');
  return `plans/reports/retro-${yymmdd}-${label.replace(/[^A-Za-z0-9]+/g, '-')}.md`;
}

function buildRetroPayload(root, options, now = new Date()) {
  const warnings = [];
  const window = resolveTimeframe(options.timeframe, {
    now,
    latestTagDate: options.timeframe === 'sprint' ? latestTagDate(root) : null,
  });
  const commits = readCommits(root, window);
  const payload = {
    generatedAt: now.toISOString(),
    repo: {
      root,
      name: path.basename(root),
      branch: spawnSync('git', ['branch', '--show-current'], { cwd: root, encoding: 'utf8' }).stdout?.trim() || 'detached HEAD',
    },
    window: { label: window.label, since: window.since.toISOString(), until: window.until.toISOString(), days: window.days },
    reportPath: reportPath(window.label, now),
    current: summarize(commits, window),
    previous: null,
    plans: planProgress(root, commits, warnings),
    issues: options.issues ? countIssues(root, window, warnings) : null,
    options: { compare: Boolean(options.compare), team: Boolean(options.team), issues: Boolean(options.issues) },
    warnings,
  };
  // Author identities leave the scanner only when the user asked for the team breakdown.
  if (!options.team) payload.current.authors = payload.current.authors.map(({ commits }) => ({ commits }));
  if (options.compare) {
    const previous = previousWindow(window);
    const summary = summarize(readCommits(root, previous), previous);
    delete summary.authors;
    payload.previous = { ...summary, since: previous.since.toISOString() };
  }
  if (payload.current.commits === 0) warnings.push('No commits in this window.');
  if (!options.issues) warnings.push('GitHub issues not counted; run with --issues to include them.');
  return payload;
}

const cell = (value) => String(value).replace(/\|/g, '\\|');
const show = (value, suffix = '') => (value === null || value === undefined ? 'N/A' : `${value}${suffix}`);

function delta(current, previous) {
  if (current === null || current === undefined || previous === null || previous === undefined) return 'N/A';
  const diff = Math.round((current - previous) * 100) / 100;
  return diff > 0 ? `+${diff}` : String(diff);
}

function table(rows, compare) {
  const lines = compare
    ? ['| Metric | Value | vs previous |', '|--------|-------|-------------|']
    : ['| Metric | Value |', '|--------|-------|'];
  for (const [label, value, current, previous] of rows) {
    lines.push(compare ? `| ${label} | ${value} | ${delta(current, previous)} |` : `| ${label} | ${value} |`);
  }
  return lines;
}

function renderRetroMarkdown(payload) {
  const cur = payload.current;
  const prev = payload.previous || {};
  const compare = Boolean(payload.previous);
  const lines = [
    `<!-- save as ${payload.reportPath} -->`,
    `# Retrospective Report: ${payload.window.label}`,
    '',
    `**Period:** ${localDay(new Date(payload.window.since))} to ${localDay(new Date(new Date(payload.window.until) - 1))} (${payload.window.days} days)`,
    `**Generated:** ${localDay(new Date(payload.generatedAt))}`,
    `**Repo:** ${payload.repo.name} (commits reachable from ${payload.repo.branch}, merges excluded)`,
    `**Authors:** ${cur.authors.length} active`,
    '',
    '## Velocity',
    '',
    ...table([
      ['Total commits', cur.commits, cur.commits, prev.commits],
      ['Commits / day', cur.commitsPerDay, cur.commitsPerDay, prev.commitsPerDay],
      ['Active days', `${cur.activeDays} / ${cur.periodDays} (${show(cur.activeDayRatio, '%')})`, cur.activeDays, prev.activeDays],
      ['Files changed', cur.filesChanged, cur.filesChanged, prev.filesChanged],
    ], compare),
    '',
    '## Code Health',
    '',
    ...table([
      ['LOC added', cur.loc.added, cur.loc.added, prev.loc?.added],
      ['LOC removed', cur.loc.removed, cur.loc.removed, prev.loc?.removed],
      ['Net LOC', cur.loc.net, cur.loc.net, prev.loc?.net],
      ['Churn rate', show(cur.churnRate, 'x'), cur.churnRate, prev.churnRate],
      ['Test-to-code ratio', show(cur.testRatio, '%'), cur.testRatio, prev.testRatio],
    ], compare),
    '',
    '## Commit Distribution',
    '',
  ];
  if (cur.commitTypes.length === 0) lines.push('N/A');
  else {
    const width = Math.max(...cur.commitTypes.map((entry) => entry.type.length));
    const max = cur.commitTypes[0].count;
    lines.push('```');
    for (const entry of cur.commitTypes) {
      const bar = '█'.repeat(Math.max(1, Math.round((entry.count / max) * 20)));
      lines.push(`${entry.type.padEnd(width)} ${bar} ${entry.count} (${entry.percent}%)`);
    }
    lines.push('```');
  }
  lines.push('', '## File Hotspots', '');
  if (cur.hotspots.length === 0) lines.push('N/A');
  else {
    lines.push('| Rank | File | Changes |', '|------|------|---------|');
    cur.hotspots.forEach((spot, index) => lines.push(`| ${index + 1} | \`${cell(spot.path)}\` | ${spot.changes} |`));
  }
  const plans = payload.plans;
  lines.push('', '## Plan Progress', '', '| Metric | Value |', '|--------|-------|',
    `| Plans touched in period | ${plans.plans.length} |`,
    `| Completed tasks (now) | ${plans.closed} |`,
    `| Open tasks (now) | ${plans.open} |`,
    `| Completion rate (now) | ${show(plans.completion, '%')} |`,
    `| Issues opened (period) | ${show(payload.issues?.opened)} |`,
    `| Issues closed (period) | ${show(payload.issues?.closed)} |`);
  if (payload.options.team) {
    lines.push('', '## Team Breakdown', '', '| Author | Commits | LOC Net | Types |', '|--------|---------|---------|-------|');
    for (const author of cur.authors) {
      const types = author.types.map((entry) => `${entry.type} ${entry.count}`).join(', ');
      lines.push(`| ${cell(author.name)} | ${author.commits} | ${author.net} | ${types} |`);
    }
  }
  if (payload.warnings.length > 0) {
    lines.push('', '## Data Notes', '');
    payload.warnings.forEach((warning) => lines.push(`- ${warning}`));
  }
  return lines.join('\n');
}

module.exports = { buildRetroPayload, renderRetroMarkdown, reportPath };
