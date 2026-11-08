#!/usr/bin/env node
'use strict';

// The project's git workflow as commands. Every rule and name comes from the `git` section of
// .claude/config/adf-config.json; the process is written in docs/conventions/git-workflow.md.
// Hooks, skills and CI call this script instead of restating the rules.

const fs = require('fs');
const path = require('path');
const { getGitConfig, branchKind } = require('../../../hooks/lib/git-flow-config.cjs');
const { git, defaultRemote, currentBranch } = require('./lib/git-exec.cjs');
const { listTags, openReleases, resolveReleaseVersion } = require('./lib/release-version.cjs');
const { isVersion } = require('./lib/semver.cjs');
const { effectiveVersionFiles, readVersions, writeVersions, checkVersions } = require('./lib/version-files.cjs');
const { checkPr, checkPush, expectedStrategy } = require('./lib/branch-guards.cjs');
const { tagRelease, headFromGitHub, headFromSubject } = require('./lib/release-tagger.cjs');
const { setupCi, checkCi } = require('./lib/ci-setup.cjs');
const { lastReleaseTag, readCommits, formatSection, writeChangelog, releaseNotes } = require('./lib/changelog-section.cjs');
const { cutRelease, backMerge } = require('./lib/release-cutter.cjs');
const { installHooks, installReport, uninstallHooks, uninstallReport, HOOK_NAMES } = require('./lib/native-git-hooks.cjs');
const { checkPushUpdates } = require('./lib/native-pre-push-check.cjs');

const USAGE = `Usage: git-flow.cjs <command> [options]   (all commands: --json, --remote <name>, --cwd <dir>)

  status [--head <branch>]            flow, active release, where this branch's PR goes and how it merges
  pr-target [--head <branch>]         just the branch this branch's PR targets
  active-release                      the open release/x.y.z on the remote (--json lists all in open[], even two)
  cut-release <x.y.z> | --next minor|patch  [--dry-run]
                                      create release/x.y.z from main with the version bump; --next picks the
                                      version from the newest tag and the version files on main
  bump-version <x.y.z> | --branch | --check <x.y.z>
                                      write (or check) the version files
  resolve-version [--head <branch>]   the version merging this branch into main would release
  check-pr --base <b> --head <h>      the flow rules for a pull request
  check-push --range <from>..<to> [--skip-merged-pr]
                                      the rules for a direct push to main (CI: skip pushes made by a PR merge)
  tag-release --sha <sha> [--head <b>] [--dry-run] [--no-gh]
                                      check a merge into main and tag it
  changelog [--since <tag>] [--version <x.y.z>] [--write]
                                      the changelog section since the last release
  release-notes --tag <tag>           the CHANGELOG.md section of a release, for the GitHub release
  back-merge                          merge main into the checked-out release after a hotfix
  setup-ci [--check] [--dry-run]      copy the CI guards and tagger to .github/workflows once, or report drift
  install-git-hooks [--only pre-push|pre-commit] [--chain] [--uninstall]
                                      opt-in native pre-push (push rules) and pre-commit (secret scan) hooks,
                                      run by a person; written only into the repository's own git dir`;

const VALUE_FLAGS = new Set(['--remote', '--cwd', '--only', '--base', '--head', '--range', '--sha', '--since', '--version', '--notes', '--tag', '--next']);
const OPTIONAL_VALUE_FLAGS = new Set(['--check']); // bump-version --check <x.y.z>, setup-ci --check

function parseArgs(argv) {
  const opts = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (VALUE_FLAGS.has(a)) {
      if (argv[i + 1] === undefined) throw new Error(`${a} needs a value`);
      opts[a.slice(2)] = argv[++i];
    } else if (OPTIONAL_VALUE_FLAGS.has(a)) {
      opts[a.slice(2)] = argv[i + 1] !== undefined && !argv[i + 1].startsWith('-') ? argv[++i] : true;
    } else if (a.startsWith('--')) opts[a.slice(2)] = true;
    else opts._.push(a);
  }
  return opts;
}

const lines = (list) => list.map((p) => `  - ${p}`).join('\n');

const COMMANDS = {
  status(config, ctx, opts) {
    const branch = opts.head || currentBranch(ctx.cwd);
    const { open } = config.enabled ? openReleases(config, ctx) : { open: [] };
    const kind = branch ? branchKind(config, branch) : null;
    const target = prTarget(config, kind, open);
    const result = { flow: config.flow, enforcement: config.enforcement, mainBranch: config.mainBranch, activeRelease: open[0] || null, branch, target, strategy: target ? expectedStrategy(config, target, branch) : null };
    const text = [`flow: ${config.flow} (enforcement: ${config.enforcement})`, `active release: ${result.activeRelease || 'none'}`, `branch: ${branch || '(detached)'}`];
    if (target) text.push(`PR target: ${target} (${result.strategy === 'merge' ? 'merge commit' : result.strategy || 'any merge'})`);
    else if (config.flow === 'release-train' && kind !== 'main' && kind !== null) text.push('PR target: none open; cut a release first (cut-release x.y.z)');
    return { result, text: text.join('\n') };
  },
  'pr-target'(config, ctx, opts) {
    const branch = opts.head || currentBranch(ctx.cwd);
    const kind = branch ? branchKind(config, branch) : null;
    const target = prTarget(config, kind, config.enabled ? openReleases(config, ctx).open : []);
    if (!target && config.flow === 'release-train' && kind !== 'main') throw new Error('no open release to target; cut one with cut-release x.y.z');
    return { result: { branch, target }, text: target || config.mainBranch };
  },
  'active-release'(config, ctx, opts) {
    const { open, malformed } = openReleases(config, ctx);
    if (open.length > 1 && !opts.json) throw new Error(`more than one open release: ${open.join(', ')}`);
    const warn = malformed.length ? `\n(ignored, not release/x.y.z: ${malformed.join(', ')})` : '';
    return { result: { activeRelease: open.length === 1 ? open[0] : null, open, malformed }, text: `${open[0] || ''}${warn}`.trim() };
  },
  'cut-release'(config, ctx, opts) {
    const r = cutRelease(config, { version: opts._[1], next: opts.next, cwd: ctx.cwd, remote: ctx.remote, dryRun: opts['dry-run'] });
    if (opts.next && opts['dry-run']) return { result: r, text: r.version };
    const text = opts['dry-run'] ? `Would:\n${lines(r.steps)}` : `${r.branch}: ${r.created ? 'created' : 'already existed'}, ${r.committed ? `committed ${r.touched.join(', ')}` : 'version already set'}`;
    return { result: r, text };
  },
  'bump-version'(config, ctx, opts) {
    const files = effectiveVersionFiles(config, config.root);
    if (opts.check === true) throw new Error('bump-version --check needs a version: --check x.y.z');
    if (opts.check) {
      const problems = checkVersions(readVersions(files, (p) => readFile(config.root, p)), opts.check);
      return { result: { ok: problems.length === 0, problems }, text: problems.length ? lines(problems) : `version files hold ${opts.check}`, exit: problems.length ? 1 : 0 };
    }
    const version = opts.branch ? resolveReleaseVersion(config, currentBranch(ctx.cwd), { tags: listTags(ctx.cwd, ctx.remote) }) : opts._[1];
    if (!version) throw new Error(opts.branch ? 'this branch releases nothing; bump on a release or hotfix branch' : 'give a version: bump-version x.y.z');
    if (!isVersion(version)) throw new Error(`"${version}" is not x.y.z`);
    const touched = opts['dry-run'] ? [] : writeVersions(files, config.root, version);
    return { result: { version, touched }, text: touched.length ? `set ${version} in ${touched.join(', ')}` : `version files already hold ${version}` };
  },
  'resolve-version'(config, ctx, opts) {
    const head = opts.head || currentBranch(ctx.cwd);
    const version = resolveReleaseVersion(config, head, { tags: listTags(ctx.cwd, ctx.remote) });
    return { result: { head, version }, text: version || '' };
  },
  'check-pr'(config, ctx, opts) {
    if (!opts.base || !opts.head) throw new Error('check-pr needs --base and --head');
    const r = checkPr(config, { base: opts.base, head: opts.head, cwd: ctx.cwd, remote: ctx.remote });
    return { result: r, text: r.ok ? `ok: ${opts.head} -> ${opts.base}${r.strategy ? ` (${r.strategy})` : ''}` : lines(r.problems), exit: r.ok ? 0 : 1 };
  },
  'check-push'(config, ctx, opts) {
    const [from, to] = String(opts.range || '').split('..');
    if (!from || !to) throw new Error('check-push needs --range <from>..<to>');
    if (opts['skip-merged-pr']) {
      const sha = git(['rev-parse', '--verify', `${to}^{commit}`], { cwd: ctx.cwd });
      const head = headFromGitHub(sha, ctx.cwd, config.mainBranch).head || headFromSubject(git(['log', '-1', '--format=%s', sha], { cwd: ctx.cwd }));
      if (head) return { result: { ok: true, problems: [], mergedPr: head }, text: `skipped: ${sha.slice(0, 7)} merged ${head} through a PR` };
    }
    const r = checkPush(config, { from, to, cwd: ctx.cwd, remote: ctx.remote });
    return { result: r, text: r.ok ? `ok: ${r.commits ?? 0} commit(s) may push to ${config.mainBranch}` : lines(r.problems), exit: r.ok ? 0 : 1 };
  },
  'tag-release'(config, ctx, opts) {
    const sha = git(['rev-parse', '--verify', `${opts.sha || 'HEAD'}^{commit}`], { cwd: ctx.cwd });
    const r = tagRelease(config, { sha, head: opts.head, cwd: ctx.cwd, remote: opts['dry-run'] ? null : ctx.remote, github: !opts['no-gh'], dryRun: opts['dry-run'], notes: opts.notes });
    if (r.problems.length > 0) return { result: r, text: `not tagged, the merge breaks the flow:\n${lines(r.problems)}`, exit: 1 };
    return { result: r, text: r.tag ? (opts['dry-run'] && !r.alreadyTagged ? `would tag ${r.tag}` : r.reason) : `no tag: ${r.reason}` };
  },
  changelog(config, ctx, opts) {
    const since = opts.since || lastReleaseTag(config, ctx.cwd);
    const version = opts.version || resolveReleaseVersion(config, currentBranch(ctx.cwd), { tags: listTags(ctx.cwd) }) || 'Unreleased';
    const section = formatSection(version, readCommits(ctx.cwd, since));
    const written = opts.write && !opts['dry-run'] ? writeChangelog(config.root, version, section) : false;
    return { result: { since, version, section, written }, text: opts.write ? `${written ? 'wrote' : 'unchanged'} CHANGELOG.md section ${version}` : section.trimEnd() };
  },
  'release-notes'(config, ctx, opts) {
    if (!opts.tag) throw new Error('release-notes needs --tag <tag>');
    const notes = releaseNotes(config, ctx.cwd, opts.tag);
    return { result: { tag: opts.tag, notes }, text: notes };
  },
  'setup-ci'(config, ctx, opts) {
    if (opts.check) {
      const r = checkCi(config);
      const lines2 = r.map((w) => `${w.target}: ${{ missing: 'not set up (run setup-ci)', current: 'matches ADF\'s template', 'template-changed': `ADF's template changed since the copy; compare with ${w.template}`, 'not-from-adf': 'exists but was not made by setup-ci' }[w.status]}`);
      return { result: r, text: lines2.join('\n') };
    }
    const r = setupCi(config, { dryRun: opts['dry-run'] });
    const text = r.map((w) => `${w.target}: ${{ created: 'created; replace the verify job with your checks', exists: 'already exists, left alone (setup-ci --check reports drift)', 'would-create': 'would be created' }[w.status]}`).join('\n');
    return { result: r, text };
  },
  'back-merge'(config, ctx) {
    const r = backMerge(config, { cwd: ctx.cwd, remote: ctx.remote });
    if (r.conflicts.length > 0) return { result: r, text: `merge stopped; resolve these, then commit:\n${lines(r.conflicts)}`, exit: 1 };
    return { result: r, text: r.merged ? `merged ${r.source}; push the release branch when ready` : `already contains ${r.source}` };
  },
  'install-git-hooks'(config, ctx, opts) {
    if (opts.only !== undefined && !HOOK_NAMES.includes(opts.only)) throw new Error(`--only takes ${HOOK_NAMES.join(' or ')}`);
    const only = opts.only || null;
    if (opts.uninstall) { const r = uninstallHooks(ctx.cwd, { only }); return { result: r, text: uninstallReport(r) }; }
    const r = installHooks(ctx.cwd, { chain: opts.chain, only });
    const { text, exit } = installReport(r, git(['rev-parse', '--show-toplevel'], { cwd: ctx.cwd }));
    return { result: r, text, exit };
  },
  'pre-push'(config, ctx) {
    const input = fs.readFileSync(0, 'utf8').split('\n');
    const problems = checkPushUpdates(config, { lines: input, cwd: ctx.cwd, remote: ctx.remote || defaultRemote(ctx.cwd), allowTags: process.env.ADF_GIT_FLOW_TAGGER === '1' });
    return { result: { problems }, text: problems.length ? `push refused by the ADF git workflow:\n${lines(problems)}` : '', exit: problems.length ? 1 : 0 };
  },
};

/** Where a branch of this kind opens its PR, or null (main itself, or no open release). */
function prTarget(config, kind, open) {
  if (config.flow === 'release-train') return kind === 'release' || kind === 'hotfix' ? config.mainBranch : kind === 'main' ? null : open[0] || null;
  return kind === 'main' ? null : config.mainBranch;
}

function readFile(root, rel) {
  try { return fs.readFileSync(path.join(root, rel), 'utf8'); } catch { return null; }
}

function main(argv) {
  let opts;
  try { opts = parseArgs(argv); } catch (err) { console.error(`${err.message}\n\n${USAGE}`); return 2; }
  const command = opts._[0];
  if (opts.help || opts.h) { console.log(USAGE); return 0; }
  if (!command) { console.error(USAGE); return 2; }
  if (!COMMANDS[command]) { console.error(`unknown command: ${command}\n\n${USAGE}`); return 2; }
  const cwd = path.resolve(opts.cwd || process.cwd());
  try {
    const config = getGitConfig(cwd);
    const ctx = { cwd, remote: command === 'pre-push' ? opts._[1] : opts.remote || defaultRemote(cwd) };
    const { result, text, exit = 0 } = COMMANDS[command](config, ctx, opts);
    if (opts.json) console.log(JSON.stringify(result, null, 2));
    else if (text) (exit ? console.error : console.log)(text);
    return exit;
  } catch (err) {
    if (opts.json) console.log(JSON.stringify({ error: err.message, code: err.refusal ? err.code : 'error' }));
    console.error(err.message);
    return 1;
  }
}

if (require.main === module) process.exit(main(process.argv.slice(2)));

module.exports = { main, parseArgs, COMMANDS };
