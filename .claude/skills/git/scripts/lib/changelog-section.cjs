'use strict';

// Builds a CHANGELOG section from the conventional commit subjects since the newest release tag.
// --first-parent with merges skipped: a hotfix that was back-merged into the release is listed once,
// under the release it shipped in.

const fs = require('fs');
const path = require('path');
const { git, gitTry } = require('./git-exec.cjs');
const { newestVersion } = require('./semver.cjs');

const GROUPS = [
  ['breaking', 'Breaking changes'],
  ['feat', 'Features'],
  ['fix', 'Bug fixes'],
  ['perf', 'Performance'],
  ['revert', 'Reverts'],
];
const SUBJECT = /^(\w+)(?:\(([^)]+)\))?(!)?:\s*(.+)$/;

/** The newest release tag reachable from `ref`, or null. */
function lastReleaseTag(config, cwd, ref = 'HEAD') {
  const tags = git(['tag', '--merged', ref, '--list', `${config.tagPrefix}*`], { cwd }).split('\n').filter(Boolean);
  const v = newestVersion(tags, config.tagPrefix);
  return v ? `${config.tagPrefix}${v}` : null;
}

/** [{type, scope, breaking, description, sha}] of the commits after `since` (all history when null). */
function readCommits(cwd, since, until = 'HEAD') {
  const range = since ? `${since}..${until}` : until;
  const out = git(['log', '--first-parent', '--no-merges', '--format=%h%x1f%s%x1f%b%x1e', range], { cwd });
  return out.split('\x1e').map((r) => r.trim()).filter(Boolean).map((record) => {
    const [sha, subject, body = ''] = record.split('\x1f');
    const m = SUBJECT.exec(subject);
    if (!m) return null;
    return { sha, type: m[1], scope: m[2] || null, breaking: Boolean(m[3]) || /^BREAKING[ -]CHANGE:/m.test(body), description: m[4] };
  }).filter(Boolean);
}

function formatSection(version, commits, date = new Date().toISOString().slice(0, 10)) {
  const lines = [`## [${version}] - ${date}`];
  for (const [key, title] of GROUPS) {
    const items = commits.filter((c) => (key === 'breaking' ? c.breaking : c.type === key));
    if (items.length === 0) continue;
    lines.push('', `### ${title}`, '');
    for (const c of items) lines.push(`- ${c.scope ? `**${c.scope}:** ` : ''}${c.description} (${c.sha})`);
  }
  if (lines.length === 1) lines.push('', 'No user-facing changes.');
  return `${lines.join('\n')}\n`;
}

/** The section of `version` ("## [1.2.0] - date" or "## 1.2.0 (date)"); group 1 is its body. */
function sectionPattern(version) {
  return new RegExp(`^## \\[?${version.replace(/\./g, '\\.')}\\]?(?=[\\s(]|$)[^\\n]*\\n([\\s\\S]*?)(?=^## |(?![\\s\\S]))`, 'm');
}

/** Puts the section above the newest one, replacing an existing section for the same version. */
function insertSection(existing, version, section) {
  const text = existing || '# Changelog\n';
  const heading = sectionPattern(version);
  if (heading.test(text)) return text.replace(heading, () => `${section}\n`);
  const first = /^## /m.exec(text);
  if (!first) return `${text.trimEnd()}\n\n${section}`;
  return `${text.slice(0, first.index)}${section}\n${text.slice(first.index)}`;
}

function writeChangelog(root, version, section) {
  const file = path.join(root, 'CHANGELOG.md');
  const before = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  const after = insertSection(before, version, section);
  if (after !== before) fs.writeFileSync(file, after);
  return after !== before;
}

/**
 * Notes for a release tag: its CHANGELOG.md section as committed at the tag, else a section built from
 * the commits since the previous release tag.
 */
function releaseNotes(config, cwd, tag) {
  const version = tag.slice(config.tagPrefix.length);
  const committed = gitTry(['show', `${tag}:CHANGELOG.md`], { cwd });
  const found = committed.status === 0 && sectionPattern(version).exec(committed.stdout);
  if (found && found[1].trim()) return found[1].trim();
  const previous = gitTry(['describe', '--tags', '--abbrev=0', '--match', `${config.tagPrefix}*`, `${tag}^`], { cwd });
  const since = previous.status === 0 ? previous.stdout.trim() : null;
  // A release reaches main by a merge commit: its changes are on the second parent's first-parent line
  const isMerge = gitTry(['rev-parse', '--verify', '--quiet', `${tag}^2`], { cwd }).status === 0;
  return formatSection(version, readCommits(cwd, since, isMerge ? `${tag}^2` : tag)).split('\n').slice(2).join('\n').trim();
}

module.exports = { lastReleaseTag, readCommits, formatSection, sectionPattern, insertSection, writeChangelog, releaseNotes };
