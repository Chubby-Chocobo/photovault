#!/usr/bin/env node
'use strict';

// The workspace commands: set up, check and bootstrap a multi-repo workspace, and seed its system
// map. Entry point on every platform (including Windows):
//   node .claude/skills/workspace/scripts/workspace.cjs <command> [options]
// Later phases append to COMMANDS; SKILL.md's argument-hint is tested against the names here.

const fs = require('fs');
const { getProjectRoot } = require('../../../hooks/lib/adf-config-utils.cjs');
const { docsRelOf } = require('../../../hooks/lib/member-link.cjs');
const init = require('./lib/workspace-init.cjs');
const check = require('./lib/workspace-check.cjs');
const bootstrap = require('./lib/workspace-bootstrap.cjs');
const seedMap = require('./lib/seed-map-command.cjs');
const scope = require('./lib/scope-command.cjs');
const scaffold = require('./lib/scaffold-command.cjs');
const drift = require('./lib/drift-command.cjs');
const repos = require('./lib/repos-command.cjs');
const prLinks = require('./lib/pr-links-command.cjs');
const memberSync = require('./lib/member-sync.cjs');
const memberAttach = require('./lib/member-attach.cjs');
const { redact } = require('./lib/workspace-git.cjs');
const { needsYes } = require('./lib/workspace-util.cjs');

/** @type {{ name: string, run: (ctx: { root: string, docsRel: string, opts: object }) => { code: number, result: object, text: string } }[]} */
const COMMANDS = [
  { name: 'init', run: needsYes(init.run) },
  { name: 'check', run: check.run },
  { name: 'bootstrap', run: needsYes(bootstrap.run) },
  { name: 'seed-map', run: seedMap.run },
  { name: 'scope', run: scope.run },
  { name: 'scaffold', run: needsYes(scaffold.run) },
  { name: 'drift', run: drift.run },
  { name: 'repos', run: repos.run },
  { name: 'pr-links', run: prLinks.run },
  { name: 'sync', run: memberSync.runConfirmed },
  { name: 'attach', run: needsYes(memberAttach.run) },
];

const USAGE = `Usage: workspace.cjs <command> [options]   (all commands: --json, --dry-run, --cwd <dir>)

  init [--workspace] [--client x --product y --org a,b] [--archetype <id>] [--fix-remotes] --yes
                                  write adf-workspace.json, the ignore blocks, bootstrap.sh and the system map (--archetype exchange|nest-service-monorepo adds its roles)
  check                           validate the manifest, the system map and the members on disk
  bootstrap [--pull] [--only a,b] [--allow-local] [--fix-remotes] [--protocol ssh|https|auto] --yes
                                  clone the members that are missing
  seed-map [--merge] [--archetype <id>]
                                  write the system map, or add the missing entries with --merge; --archetype merges that archetype's roles in
  scope [--plan <dir>] [--paths a,b] [--write-settings | --clear-settings] [--yes]
                                  show the scope of a plan or paths and what to load; settings are written only with --yes
  scaffold [<component>] [--only claude-md|service-docs] --yes
                                  write the CLAUDE.md of each component that has none, and docs/architecture/services/<name>.md
  drift [--fail-on differs,unpinned,not-at-local-head,...] [--allow-missing]
                                  report which ref each consumer pins per contract; exit 1 on a listed finding (and on a member that is not cloned, unless --allow-missing)
  repos [--plan <dir> | --paths a,b | --changed]
                                  per repo: branch, staged/unstaged/untracked, upstream, ahead/behind, the PR base and whether it has its own .claude/; the workspace repo is always listed
  pr-links --branch <b> [--plan <dir> | --paths a,b] [--write]
                                  list the open same-repo PRs of a branch across the members; --write adds a "Related pull requests" block to each PR body (needs gh)
  sync [--member <name>] [--check] [--force] [--from <workspace dir>] [--yes]
                                  write the marker and the system-context block into each member's CLAUDE.md; never commits. --check writes nothing and exits 1 when a block is missing, stale or edited
  attach <workspace-url> [--dir <path>] [--yes]
                                  run in a standalone member: clone the workspace next to it and grant it in .claude/settings.local.json; the URL must match the owners in the member's marker

init, bootstrap, scaffold, sync and attach only plan until --yes is given (--dry-run always plans; sync --check needs no --yes): confirm the plan, then re-run with --yes.
scope --write-settings and --clear-settings print the settings diff and write nothing until --yes is given.`;

const VALUE_FLAGS = new Set(['--cwd', '--client', '--product', '--org', '--only', '--protocol', '--plan', '--paths', '--fail-on', '--branch', '--member', '--from', '--dir', '--archetype']);

/** @returns {{ _: string[], [flag: string]: string|boolean|string[] }} */
function parseArgs(argv) {
  const opts = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (VALUE_FLAGS.has(a)) {
      const value = argv[i + 1];
      if (value === undefined || value.startsWith('-')) throw new Error(`${a} needs a value that does not start with "-"`);
      opts[a.slice(2)] = value;
      i += 1;
    } else if (a.startsWith('--')) opts[a.slice(2)] = true;
    else opts._.push(a);
  }
  return opts;
}

/**
 * Exit code of a run. With --json stdout always carries exactly one JSON object, even for a usage
 * error or an internal failure; without it, problems go to stderr.
 * @param {string[]} argv
 * @param {{ out?: (s: string) => void, err?: (s: string) => void }} [io]
 * @returns {number}
 */
function main(argv, { out = (s) => process.stdout.write(`${s}\n`), err = (s) => process.stderr.write(`${s}\n`) } = {}) {
  const json = argv.includes('--json');
  const stop = (code, message) => {
    if (json) out(JSON.stringify({ ok: false, errors: [message] }));
    else err(message);
    return code;
  };
  let opts;
  try { opts = parseArgs(argv); } catch (e) { return stop(2, e.message); }
  const command = COMMANDS.find((c) => c.name === opts._[0]);
  if (!command) return stop(2, USAGE);
  try {
    const cwd = typeof opts.cwd === 'string' ? opts.cwd : process.cwd();
    if (!fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) return stop(2, `--cwd is not a directory: ${cwd}`);
    const root = getProjectRoot(cwd);
    const outcome = command.run({ root, docsRel: docsRelOf(root), opts });
    out(json ? JSON.stringify(outcome.result) : outcome.text);
    return outcome.code;
  } catch (e) {
    return stop(1, `workspace ${command.name} failed: ${redact(e && e.message ? e.message : e && e.code ? e.code : 'error')}`);
  }
}

if (require.main === module) process.exit(main(process.argv.slice(2)));

module.exports = { COMMANDS, USAGE, parseArgs, main };
