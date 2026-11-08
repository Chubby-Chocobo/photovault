'use strict';

// A throwaway project with a bare remote, for the git-flow tests. Git runs with an empty global
// config, so the developer's hooks, signing and aliases never leak in.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const base = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-git-flow-home-'));
const globalConfig = path.join(base, 'gitconfig');
fs.writeFileSync(globalConfig, '[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n');
Object.assign(process.env, { GIT_CONFIG_GLOBAL: globalConfig, GIT_CONFIG_NOSYSTEM: '1', CLAUDE_PROJECT_DIR: '', GH_HOST: 'invalid.example' });
process.on('exit', () => fs.rmSync(base, { recursive: true, force: true }));

const SCRIPT = path.join(__dirname, '..', 'git-flow.cjs');

function sh(cwd, cmd, ...args) {
  const r = spawnSync(cmd, args, { cwd, encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`${cmd} ${args.join(' ')}: ${r.stderr || r.stdout}`);
  return r.stdout.trim();
}

/** Runs git-flow.cjs; returns {code, out, err, json}. A last argument {env} adds environment variables. */
function flow(cwd, ...args) {
  const extra = typeof args.at(-1) === 'object' ? args.pop().env : {};
  const r = spawnSync(process.execPath, [SCRIPT, ...args], { cwd, encoding: 'utf8', input: '', env: { ...process.env, ...extra } });
  let json = null;
  try { json = JSON.parse(r.stdout); } catch { /* text output */ }
  return { code: r.status, out: r.stdout.trim(), err: r.stderr.trim(), json };
}

/**
 * @param {object} t node:test context, for cleanup
 * @param {{git?: object, version?: string, tag?: string|null}} opts
 */
function makeRepo(t, { git = {}, version = '1.0.0', tag = 'v1.0.0' } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-git-flow-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const remote = path.join(dir, 'remote.git');
  const work = path.join(dir, 'work');
  sh(dir, 'git', 'init', '--quiet', '--bare', remote);
  sh(dir, 'git', 'clone', '--quiet', remote, work);
  write(work, '.claude/config/adf-config.json', JSON.stringify({ git }, null, 2));
  write(work, 'package.json', `${JSON.stringify({ name: 'demo', version }, null, 2)}\n`);
  write(work, 'CHANGELOG.md', `# Changelog\n\n## [${version}] - 2026-01-01\n\n- first release\n`);
  write(work, 'src/app.js', 'module.exports = 1;\n');
  commit(work, 'chore: initial commit');
  sh(work, 'git', 'push', '--quiet', '-u', 'origin', 'main');
  if (tag) { sh(work, 'git', 'tag', '-a', tag, '-m', tag); sh(work, 'git', 'push', '--quiet', 'origin', tag); }
  return { dir, remote, work };
}

function write(root, rel, content) {
  fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
  fs.writeFileSync(path.join(root, rel), content);
}

const read = (root, rel) => fs.readFileSync(path.join(root, rel), 'utf8');

function commit(cwd, message) {
  sh(cwd, 'git', 'add', '--all');
  sh(cwd, 'git', 'commit', '--quiet', '--allow-empty', '-m', message);
  return sh(cwd, 'git', 'rev-parse', 'HEAD');
}

/** Squash-merges `head` into the checked-out branch like GitHub does, and pushes. */
function squashInto(cwd, base, head, subject) {
  sh(cwd, 'git', 'checkout', '--quiet', base);
  sh(cwd, 'git', 'pull', '--quiet', '--ff-only');
  sh(cwd, 'git', 'merge', '--quiet', '--squash', head);
  sh(cwd, 'git', 'commit', '--quiet', '-m', subject);
  sh(cwd, 'git', 'push', '--quiet', 'origin', base);
  return sh(cwd, 'git', 'rev-parse', 'HEAD');
}

/** A merge commit like GitHub's "Create a merge commit", and push. */
function mergeInto(cwd, base, head, subject) {
  sh(cwd, 'git', 'checkout', '--quiet', base);
  sh(cwd, 'git', 'pull', '--quiet', '--ff-only');
  sh(cwd, 'git', 'merge', '--quiet', '--no-ff', '-m', subject, head);
  sh(cwd, 'git', 'push', '--quiet', 'origin', base);
  return sh(cwd, 'git', 'rev-parse', 'HEAD');
}

/** Gives the project ADF's hook libraries and git scripts, as an install does. */
function withAdfScripts(work) {
  const claude = path.join(__dirname, '..', '..', '..', '..');
  const keep = (src) => !src.split(path.sep).includes('tests') && !src.split(path.sep).includes('__tests__');
  for (const rel of ['hooks/lib', 'skills/git/scripts']) fs.cpSync(path.join(claude, rel), path.join(work, '.claude', rel), { recursive: true, filter: keep });
}

/** A directory holding a fake `gh` that always fails, to put first on PATH. */
function failingGh() {
  const bin = fs.mkdtempSync(path.join(base, 'gh-'));
  fs.writeFileSync(path.join(bin, 'gh'), '#!/bin/sh\necho "HTTP 403: Resource not accessible by integration" >&2\nexit 1\n', { mode: 0o755 });
  return bin;
}

module.exports = { sh, flow, failingGh, withAdfScripts, makeRepo, write, read, commit, squashInto, mergeInto };
