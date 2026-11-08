'use strict';

// Shared by the member-sync and member-attach tests: a scaffolded TCX workspace whose members have
// committed CLAUDE.md files (and no AGENTS.md), and calls into the two command modules.

const fs = require('node:fs');
const path = require('node:path');
const { cli, git, scaffoldWorkspace, editManifest, readJson } = require('./workspace-test-helpers.cjs');
const sync = require('../lib/member-sync.cjs');

/** Stage the listed files that exist in `dir` and commit; returns the new HEAD. */
function commitFiles(dir, files = ['CLAUDE.md', '.adf-workspace.json']) {
  const present = files.filter((f) => { try { fs.lstatSync(path.join(dir, f)); return true; } catch { return false; } });
  if (present.length > 0) git(dir, 'add', '--all', '--', ...present);
  git(dir, 'commit', '--quiet', '--allow-empty', '-m', 'chore: update');
  return git(dir, 'rev-parse', 'HEAD');
}

/**
 * The TCX workspace with product tcx, scaffolded CLAUDE.md files committed in every member, and no
 * CLAUDE.md in services/trading (apps/mobile is not cloned, contracts/tcx-proto has no component).
 */
function preparedWorkspace(t) {
  const ws = scaffoldWorkspace(t);
  editManifest(ws.root, (m) => { m.product = 'tcx'; m.client = 'tcx'; });
  const scaffolded = cli(ws.root, ['scaffold', '--only', 'claude-md']);
  if (scaffolded.code !== 0) throw new Error(`scaffold failed: ${scaffolded.out}`);
  fs.rmSync(path.join(ws.members.trading, 'CLAUDE.md'));
  for (const dir of Object.values(ws.members)) commitFiles(dir, ['CLAUDE.md']);
  return ws;
}

const memberDirs = (ws) => ws.members;
const headsOf = (ws) => Object.fromEntries(Object.entries(ws.members).map(([name, dir]) => [name, git(dir, 'rev-parse', 'HEAD')]));
const read = (...parts) => fs.readFileSync(path.join(...parts), 'utf8');
const exists = (...parts) => fs.existsSync(path.join(...parts));

/** Run sync in-process (the command module, no confirmation gate). */
function runSync(root, flags = {}, docsRel = 'docs') {
  return sync.run({ root, docsRel, opts: { _: ['sync'], ...flags } });
}

const rowOf = (outcome, name) => outcome.result.rows.find((r) => r.component === name || (r.component === null && r.member === name));
const writtenNames = (outcome) => outcome.result.rows.filter((r) => r.action === 'written').map((r) => r.component).sort();

module.exports = { commitFiles, preparedWorkspace, memberDirs, headsOf, read, exists, runSync, rowOf, writtenNames, readJson };
