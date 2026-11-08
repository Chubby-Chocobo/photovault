#!/usr/bin/env node
'use strict';

// Native pre-commit hook (installed by `git-flow.cjs install-git-hooks`): refuses a commit whose
// staged changes hold secret files or credential-shaped lines, for commits made outside Claude Code.
// It scans with the same scanner as the commit-guard hook and fails closed once it runs: a change the scan
// could not read, or any error in the scan, refuses the commit. Output names files, lines and rules, never values.
// A dedicated script (not a git-flow.cjs command), so a checkout from before this hook existed has
// no file for the hook script to find and its commits pass.

const fs = require('fs');
const path = require('path');
const { scanCommit, scanFailureCause } = require('../../../hooks/lib/commit-secret-scanner.cjs');
const { getGitConfig } = require('../../../hooks/lib/git-flow-config.cjs');

const MAX_LISTED = 10;
const AGENT_LINE = 'If you are an AI agent: stop and tell the user; do not change files, settings or hooks to get past this check.';
const CONFIG_NOTE = "The project's adf-config.json does not parse, so its commit-guard settings were not applied.";

// File names come from the repository: keep control characters out of the terminal
const printable = (name) => name.replace(/[\u0000-\u001f\u007f]/g, '?');

/** True when the project's config file exists but is not valid JSON (getGitConfig then reads defaults). */
function configIsBroken(root) {
  let raw;
  try { raw = fs.readFileSync(path.join(root, '.claude', 'config', 'adf-config.json'), 'utf8'); } catch { return false; }
  try { JSON.parse(raw); return false; } catch { return true; }
}

function listed(items, format) {
  const lines = items.slice(0, MAX_LISTED).map((item) => `  - ${format(item)}`);
  if (items.length > MAX_LISTED) lines.push(`  ... and ${items.length - MAX_LISTED} more`);
  return lines;
}

/** @returns {{ exit: number, lines: string[] }} */
function check(cwd) {
  // The repository being committed decides, not the session that started git
  delete process.env.CLAUDE_PROJECT_DIR;
  const config = getGitConfig(cwd);
  if (!config.commit.secrets) return { exit: 0, lines: [] };
  const note = configIsBroken(config.root) ? [CONFIG_NOTE] : [];

  let scan;
  try {
    scan = scanCommit(cwd, { tracked: 'cached', allowFiles: config.commit.allowSecretFiles });
  } catch (err) {
    return { exit: 1, lines: ['ADF pre-commit: the staged changes could not be scanned for secrets, so the commit is refused.', `Cause: ${scanFailureCause(err)}.`, ...note, AGENT_LINE] };
  }
  const { files, findings, unscanned } = scan;
  if (!files.length && !findings.length && !unscanned.length) return { exit: 0, lines: [] };

  const lines = [];
  if (files.length || findings.length) {
    lines.push('ADF pre-commit: this commit would record secrets (values not shown):');
    lines.push(...listed(files, (f) => `${printable(f)} (secret file)`));
    lines.push(...listed(findings, (f) => `${printable(f.file)}:${f.line} (${f.rule})`));
    lines.push('Unstage them (git restore --staged <file>) and keep the value in an untracked .env.');
  }
  if (unscanned.length) {
    lines.push('ADF pre-commit: these staged changes could not be scanned for secrets, so the commit is refused:');
    lines.push(...listed(unscanned, printable));
  }
  lines.push(...note, AGENT_LINE);
  if (files.length || findings.length) lines.push('Fake values and test fixtures: see "No staged secrets" in the project\'s git-workflow.md.');
  return { exit: 1, lines };
}

function main() {
  try {
    const { exit, lines } = check(process.cwd());
    if (lines.length) console.error(lines.join('\n'));
    return exit;
  } catch (err) {
    console.error(['ADF pre-commit: the scan failed, so the commit is refused.', `Cause: ${scanFailureCause(err)}.`, AGENT_LINE].join('\n'));
    return 1;
  }
}

if (require.main === module) process.exit(main());

module.exports = { main, check };
