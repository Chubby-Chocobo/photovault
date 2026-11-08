'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { sh, flow, makeRepo, write, read, withAdfScripts } = require('./git-flow-test-repo.cjs');

// Built by concatenation so this file never holds a literal credential-shaped string
const FAKE_AWS = 'AKIA' + 'QWERTYUIOPASDFGH';

const PRE_COMMIT_LINE = 's="$(git rev-parse --show-toplevel)/.claude/skills/git/scripts/native-pre-commit.cjs"; if [ -f "$s" ] && command -v node >/dev/null 2>&1; then node "$s" || exit 1; fi';
const PRE_PUSH_LINE = 's="$(git rev-parse --show-toplevel)/.claude/skills/git/scripts/git-flow.cjs"; if [ -f "$s" ] && command -v node >/dev/null 2>&1; then node "$s" pre-push "$@" || exit 1; fi';

// What 1.2.4 wrote into a husky v9 project's own .husky/pre-push
const HUSKY_BLOCK_124 = `# >>> adf-git-flow pre-push (git-flow.cjs install-git-hooks)
adf_script="$(git rev-parse --show-toplevel)/.claude/skills/git/scripts/git-flow.cjs"
[ ! -f "$adf_script" ] || node "$adf_script" pre-push "$@"
# <<< adf-git-flow pre-push
`;
// What 1.2.4 wrote into a plain hooks dir (also husky v8's .husky/)
const HOOK_FILE_124 = `#!/bin/sh
# adf-git-flow pre-push: written by git-flow.cjs install-git-hooks; remove with install-git-hooks --uninstall
input=$(cat)
dir=$(dirname "$0")
if [ -x "$dir/pre-push.adf-chained" ]; then
  printf '%s\\n' "$input" | "$dir/pre-push.adf-chained" "$@" || exit $?
fi
script="$(git rev-parse --show-toplevel)/.claude/skills/git/scripts/git-flow.cjs"
[ -f "$script" ] || exit 0
printf '%s\\n' "$input" | node "$script" pre-push "$@"
`;

function adfRepo(t, opts) {
  const repo = makeRepo(t, opts);
  withAdfScripts(repo.work);
  write(repo.work, '.claude/config/adf-config.json', '{}');
  return repo;
}

const gitRun = (cwd, ...args) => {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
  return { code: r.status, out: r.stdout.trim(), err: r.stderr.trim() };
};

/** Every file under dir with its content, for "nothing was written" checks. */
function snapshot(root) {
  const out = {};
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === '.git' && dir === root) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else out[path.relative(root, full)] = entry.isSymbolicLink() ? 'link' : fs.readFileSync(full, 'utf8');
    }
  };
  walk(root);
  return out;
}

const hooksDir = (work) => path.join(work, '.git', 'hooks');
const exists = (work, rel) => fs.existsSync(path.join(work, rel));

describe('install-git-hooks into the git dir', () => {
  it('installs both hooks, reports them as installed on a re-run, and uninstalls cleanly', (t) => {
    const { work } = adfRepo(t);
    const first = flow(work, 'install-git-hooks');
    assert.equal(first.code, 0, first.err);
    for (const hook of ['pre-commit', 'pre-push']) {
      assert.match(read(work, `.git/hooks/${hook}`), new RegExp(`^# adf-git-flow ${hook}:`, 'm'));
      assert.ok(fs.statSync(path.join(hooksDir(work), hook)).mode & 0o100, `${hook} is executable`);
    }
    const again = flow(work, 'install-git-hooks');
    assert.equal(again.code, 0);
    assert.match(again.out, /pre-commit: already installed/);
    assert.match(again.out, /pre-push: already installed/);
    const gone = flow(work, 'install-git-hooks', '--uninstall');
    assert.equal(gone.code, 0);
    assert.equal(exists(work, '.git/hooks/pre-commit'), false);
    assert.equal(exists(work, '.git/hooks/pre-push'), false);
  });

  it('--only installs one hook, and a later full install adds the other', (t) => {
    const { work } = adfRepo(t);
    assert.equal(flow(work, 'install-git-hooks', '--only', 'pre-commit').code, 0);
    assert.equal(exists(work, '.git/hooks/pre-push'), false);
    const r = flow(work, 'install-git-hooks');
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /pre-commit: already installed/);
    assert.ok(exists(work, '.git/hooks/pre-push'));
    assert.equal(flow(work, 'install-git-hooks', '--uninstall', '--only', 'pre-push').code, 0);
    assert.ok(exists(work, '.git/hooks/pre-commit'), '--only leaves the other hook');
    assert.equal(exists(work, '.git/hooks/pre-push'), false);
    assert.match(flow(work, 'install-git-hooks', '--only', 'post-commit').err, /--only takes pre-commit or pre-push/);
  });

  it('keeps a foreign hook: refuses without --chain, chains with it, and restores it on uninstall', (t) => {
    const { work } = adfRepo(t);
    const hook = path.join(hooksDir(work), 'pre-push');
    fs.writeFileSync(hook, '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    const refused = flow(work, 'install-git-hooks');
    assert.equal(refused.code, 1);
    assert.match(refused.err, /not ADF's; pass --chain/);
    assert.equal(exists(work, '.git/hooks/pre-commit'), false, 'a refusal writes neither hook');
    const chained = flow(work, 'install-git-hooks', '--chain');
    assert.equal(chained.code, 0, chained.err);
    assert.match(chained.out, /pre-push \(runs the existing hook first\)/);
    assert.match(read(work, '.git/hooks/pre-push'), /adf-git-flow pre-push/);
    assert.equal(read(work, '.git/hooks/pre-push.adf-chained'), '#!/bin/sh\nexit 0\n');
    assert.equal(flow(work, 'install-git-hooks', '--uninstall').code, 0);
    assert.equal(read(work, '.git/hooks/pre-push'), '#!/bin/sh\nexit 0\n');
    assert.equal(exists(work, '.git/hooks/pre-push.adf-chained'), false);
  });

  it('refuses when the chained name is taken, before writing either hook', (t) => {
    const { work } = adfRepo(t);
    fs.writeFileSync(path.join(hooksDir(work), 'pre-commit'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    fs.writeFileSync(path.join(hooksDir(work), 'pre-commit.adf-chained'), '#!/bin/sh\nexit 0\n');
    const r = flow(work, 'install-git-hooks', '--chain');
    assert.equal(r.code, 1);
    assert.match(r.err, /pre-commit\.adf-chained already exists/);
    assert.equal(exists(work, '.git/hooks/pre-push'), false);
  });

  it('a chained pre-commit runs first and can refuse', (t) => {
    const { work } = adfRepo(t);
    fs.writeFileSync(path.join(hooksDir(work), 'pre-commit'), '#!/bin/sh\necho "own check" >&2\nexit 1\n', { mode: 0o755 });
    assert.equal(flow(work, 'install-git-hooks', '--chain').code, 0);
    write(work, 'a.txt', 'a\n');
    sh(work, 'git', 'add', 'a.txt');
    const r = gitRun(work, 'commit', '-m', 'feat: a');
    assert.equal(r.code, 1);
    assert.match(r.err, /own check/);
  });

  it('refuses a repository without ADF scripts, naming the cause, and writes nothing', (t) => {
    const { work } = makeRepo(t);
    const r = flow(work, 'install-git-hooks');
    assert.equal(r.code, 1);
    assert.match(r.err, /this repository has no ADF scripts/);
    assert.match(r.err, /would pass every commit unchecked/);
    assert.equal(exists(work, '.git/hooks/pre-commit'), false);
    assert.equal(exists(work, '.git/hooks/pre-push'), false);
  });

  it('refuses a tree from before the pre-commit script, but --only pre-push still installs', (t) => {
    const { work } = adfRepo(t);
    fs.rmSync(path.join(work, '.claude/skills/git/scripts/native-pre-commit.cjs'));
    assert.match(flow(work, 'install-git-hooks').err, /native-pre-commit\.cjs is missing/);
    assert.equal(exists(work, '.git/hooks/pre-push'), false);
    assert.equal(flow(work, 'install-git-hooks', '--only', 'pre-push').code, 0);
  });

  it('writes into the common git dir from a linked worktree', (t) => {
    const { work, dir } = adfRepo(t);
    sh(work, 'git', 'add', '--all');
    sh(work, 'git', 'commit', '--quiet', '-m', 'chore: scripts');
    const linked = path.join(dir, 'linked');
    sh(work, 'git', 'worktree', 'add', '--quiet', '-b', 'feat/x', linked);
    const r = flow(linked, 'install-git-hooks');
    assert.equal(r.code, 0, r.err);
    assert.ok(exists(work, '.git/hooks/pre-commit'));
    assert.ok(exists(work, '.git/hooks/pre-push'));
    write(linked, 'k.js', `k = "${FAKE_AWS}"\n`);
    sh(linked, 'git', 'add', 'k.js');
    assert.equal(gitRun(linked, 'commit', '-m', 'feat: k').code, 1, 'the hook scans the worktree it runs in');
  });

  it('prints install results as JSON', (t) => {
    const { work } = adfRepo(t);
    const r = flow(work, 'install-git-hooks', '--json');
    assert.deepEqual(r.json.hooks.map((h) => [h.hook, h.state]), [['pre-commit', 'written'], ['pre-push', 'written']]);
  });
});

describe('install-git-hooks and entries it must not write through', () => {
  it('treats a dangling hook symlink as a foreign hook and never writes through it', (t) => {
    const { work } = adfRepo(t);
    fs.symlinkSync('../../scripts/hooks/pre-commit', path.join(hooksDir(work), 'pre-commit'));
    const before = snapshot(work);
    const refused = flow(work, 'install-git-hooks', '--only', 'pre-commit');
    assert.equal(refused.code, 1);
    assert.match(refused.err, /not ADF's; pass --chain/);
    assert.deepEqual(snapshot(work), before, 'nothing appeared in the work tree');
    const chained = flow(work, 'install-git-hooks', '--only', 'pre-commit', '--chain');
    assert.equal(chained.code, 0, chained.err);
    assert.deepEqual(snapshot(work), before, 'still nothing in the work tree');
    assert.match(read(work, '.git/hooks/pre-commit'), /adf-git-flow pre-commit/);
    assert.ok(fs.lstatSync(path.join(hooksDir(work), 'pre-commit.adf-chained')).isSymbolicLink());
    assert.equal(flow(work, 'install-git-hooks', '--uninstall', '--only', 'pre-commit').code, 0);
    assert.ok(fs.lstatSync(path.join(hooksDir(work), 'pre-commit')).isSymbolicLink(), 'the symlink is restored');
  });
});

describe('install-git-hooks with a hooks dir outside the git dir', () => {
  const layouts = {
    'husky v8 (.husky)': (work) => { fs.mkdirSync(path.join(work, '.husky')); sh(work, 'git', 'config', 'core.hooksPath', '.husky'); },
    'husky v9 (.husky/_)': (work) => { fs.mkdirSync(path.join(work, '.husky', '_'), { recursive: true }); sh(work, 'git', 'config', 'core.hooksPath', '.husky/_'); },
    '.githooks': (work) => { fs.mkdirSync(path.join(work, '.githooks')); sh(work, 'git', 'config', 'core.hooksPath', '.githooks'); },
    'a dir outside the repository': (work, dir) => { const out = path.join(dir, 'shared-hooks'); fs.mkdirSync(out); sh(work, 'git', 'config', 'core.hooksPath', out); },
    "another repository's hooks dir": (work, dir) => {
      const other = path.join(dir, 'other');
      sh(dir, 'git', 'init', '--quiet', other);
      sh(work, 'git', 'config', 'core.hooksPath', path.join(other, '.git', 'hooks'));
    },
  };

  for (const [name, setup] of Object.entries(layouts)) {
    it(`writes nothing and prints both lines for ${name}`, (t) => {
      const { work, dir } = adfRepo(t);
      setup(work, dir);
      const before = snapshot(dir);
      const status = gitRun(work, 'status', '--porcelain').out;
      const r = flow(work, 'install-git-hooks');
      assert.equal(r.code, 1);
      assert.match(r.err, /not installed/);
      assert.ok(r.err.includes(PRE_COMMIT_LINE), 'pre-commit line');
      assert.ok(r.err.includes(PRE_PUSH_LINE), 'pre-push line');
      assert.deepEqual(snapshot(dir), before, 'no file written or renamed');
      assert.equal(gitRun(work, 'status', '--porcelain').out, status);
    });
  }

  it('writes nothing for a global core.hooksPath either', (t) => {
    const { work, dir } = adfRepo(t);
    const shared = path.join(dir, 'global-hooks');
    fs.mkdirSync(shared);
    sh(work, 'git', 'config', '--global', 'core.hooksPath', shared);
    t.after(() => spawnSync('git', ['config', '--global', '--unset', 'core.hooksPath'], { cwd: os.tmpdir() }));
    const r = flow(work, 'install-git-hooks');
    assert.equal(r.code, 1);
    assert.deepEqual(fs.readdirSync(shared), []);
  });

  it('counts a 1.2.x husky pre-push block as installed and prints only the pre-commit line', (t) => {
    const { work } = adfRepo(t);
    fs.mkdirSync(path.join(work, '.husky', '_'), { recursive: true });
    sh(work, 'git', 'config', 'core.hooksPath', '.husky/_');
    write(work, '.husky/pre-push', `#!/bin/sh\n${HUSKY_BLOCK_124}npm test\n`);
    const r = flow(work, 'install-git-hooks');
    assert.equal(r.code, 1);
    assert.match(r.err, /pre-push: already installed/);
    assert.ok(r.err.includes(PRE_COMMIT_LINE));
    assert.ok(!r.err.includes(PRE_PUSH_LINE));
    assert.equal(read(work, '.husky/pre-push'), `#!/bin/sh\n${HUSKY_BLOCK_124}npm test\n`);
    const onlyPush = flow(work, 'install-git-hooks', '--only', 'pre-push');
    assert.equal(onlyPush.code, 0, 'nothing left to install is not a failure');
  });

  it('counts the printed lines, once a person pasted them into the hook files, as installed', (t) => {
    const { work } = adfRepo(t);
    sh(work, 'git', 'config', 'core.hooksPath', '.githooks');
    const first = flow(work, 'install-git-hooks');
    assert.equal(first.code, 1);
    write(work, '.githooks/pre-commit', `#!/bin/sh\n${PRE_COMMIT_LINE}\nnpm run lint\n`);
    const second = flow(work, 'install-git-hooks');
    assert.equal(second.code, 1);
    assert.match(second.err, /pre-commit: already installed/);
    assert.ok(!second.err.includes(PRE_COMMIT_LINE), 'only the pre-push line is still printed');
    assert.ok(second.err.includes(PRE_PUSH_LINE));
    write(work, '.githooks/pre-push', `#!/bin/sh\n${PRE_PUSH_LINE}\n`);
    const done = flow(work, 'install-git-hooks');
    assert.equal(done.code, 0, done.err);
    assert.match(done.out, /pre-push: already installed/);
  });

  it('does not count a commented-out or partial copy of the printed line as installed', (t) => {
    const { work } = adfRepo(t);
    sh(work, 'git', 'config', 'core.hooksPath', '.githooks');
    write(work, '.githooks/pre-commit', `#!/bin/sh\n# ${PRE_COMMIT_LINE}\necho "${PRE_COMMIT_LINE.slice(0, 60)}"\n`);
    const r = flow(work, 'install-git-hooks', '--only', 'pre-commit');
    assert.equal(r.code, 1);
    assert.doesNotMatch(r.err, /already installed/);
    assert.ok(r.err.includes(PRE_COMMIT_LINE), 'the line is still printed');
    write(work, '.githooks/pre-commit', `#!/bin/sh\n  ${PRE_COMMIT_LINE}  \n`);
    assert.equal(flow(work, 'install-git-hooks', '--only', 'pre-commit').code, 0, 'indentation does not matter');
  });

  it('a printed pre-commit line, first in the hook file, leaves the hook\'s own commands running', (t) => {
    const { work } = adfRepo(t);
    sh(work, 'git', 'config', 'core.hooksPath', '.husky');
    write(work, '.husky/pre-commit', `#!/bin/sh\n${PRE_COMMIT_LINE}\ntouch own-command-ran\n`);
    fs.chmodSync(path.join(work, '.husky/pre-commit'), 0o755);
    write(work, 'a.txt', 'a\n');
    sh(work, 'git', 'add', 'a.txt');
    assert.equal(gitRun(work, 'commit', '-m', 'feat: a').code, 0);
    assert.ok(exists(work, 'own-command-ran'), 'a pass runs the commands after the line');
    fs.rmSync(path.join(work, 'own-command-ran'));
    write(work, 'k.js', `k = "${FAKE_AWS}"\n`);
    sh(work, 'git', 'add', 'k.js');
    const refused = gitRun(work, 'commit', '-m', 'feat: k');
    assert.equal(refused.code, 1);
    assert.match(refused.err, /k\.js:1 \(AWS access key\)/);
    assert.equal(exists(work, 'own-command-ran'), false, 'a refusal stops the hook');
  });

  it('a printed pre-push line, first in the hook file, still sees the ref lines before a later stdin reader', (t) => {
    const { work } = adfRepo(t);
    sh(work, 'git', 'config', 'core.hooksPath', '.husky');
    write(work, '.husky/pre-push', `#!/bin/sh\n${PRE_PUSH_LINE}\ncat > /dev/null\n`);
    fs.chmodSync(path.join(work, '.husky/pre-push'), 0o755);
    sh(work, 'git', 'add', '--all');
    sh(work, 'git', 'commit', '--quiet', '--no-verify', '-m', 'chore: hooks');
    sh(work, 'git', 'push', '--quiet', '--no-verify', 'origin', 'main');
    sh(work, 'git', 'commit', '--quiet', '--no-verify', '--amend', '-m', 'chore: rewritten');
    const push = gitRun(work, 'push', '--force', 'origin', 'main');
    assert.notEqual(push.code, 0);
    assert.match(push.err, /force-pushing main is not allowed/);
  });
});

describe('install-git-hooks --uninstall', () => {
  it('removes a 1.2.4 husky v9 block and leaves the project\'s own commands', (t) => {
    const { work } = adfRepo(t);
    fs.mkdirSync(path.join(work, '.husky', '_'), { recursive: true });
    sh(work, 'git', 'config', 'core.hooksPath', '.husky/_');
    write(work, '.husky/pre-push', `#!/bin/sh\n${HUSKY_BLOCK_124}npm test\n`);
    const r = flow(work, 'install-git-hooks', '--uninstall');
    assert.equal(r.code, 0, r.err);
    assert.equal(read(work, '.husky/pre-push'), '#!/bin/sh\nnpm test\n');
  });

  it('removes a 1.2.4 husky v8 marked hook and restores the project\'s own', (t) => {
    const { work } = adfRepo(t);
    sh(work, 'git', 'config', 'core.hooksPath', '.husky');
    write(work, '.husky/pre-push', HOOK_FILE_124);
    write(work, '.husky/pre-push.adf-chained', '#!/bin/sh\nnpm test\n');
    const r = flow(work, 'install-git-hooks', '--uninstall');
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /restored the hook it ran first/);
    assert.equal(read(work, '.husky/pre-push'), '#!/bin/sh\nnpm test\n');
    assert.equal(exists(work, '.husky/pre-push.adf-chained'), false);
  });

  it('restores the project\'s hook parked under the chained name when ADF\'s hook file is gone', (t) => {
    const { work } = adfRepo(t);
    write(work, '.git/hooks/pre-push.adf-chained', '#!/bin/sh\nnpm test\n');
    const r = flow(work, 'install-git-hooks', '--uninstall', '--only', 'pre-push');
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /restored .*pre-push from pre-push\.adf-chained/);
    assert.equal(read(work, '.git/hooks/pre-push'), '#!/bin/sh\nnpm test\n');
    assert.equal(exists(work, '.git/hooks/pre-push.adf-chained'), false);
    write(work, '.git/hooks/pre-commit', '#!/bin/sh\nexit 0\n');
    write(work, '.git/hooks/pre-commit.adf-chained', 'parked\n');
    flow(work, 'install-git-hooks', '--uninstall', '--only', 'pre-commit');
    assert.equal(read(work, '.git/hooks/pre-commit.adf-chained'), 'parked\n', 'a hook that is there is never replaced');
  });

  it('touches no hook file without ADF\'s marker, in any hooks dir', (t) => {
    const { work, dir } = adfRepo(t);
    const shared = path.join(dir, 'shared-hooks');
    fs.mkdirSync(shared);
    sh(work, 'git', 'config', 'core.hooksPath', shared);
    fs.writeFileSync(path.join(shared, 'pre-push'), '#!/bin/sh\nnpm test\n');
    fs.writeFileSync(path.join(shared, 'pre-commit'), '#!/bin/sh\n# mentions adf-git-flow pre-commit in a comment\nexit 0\n');
    fs.writeFileSync(path.join(shared, 'pre-push.adf-chained'), 'someone else\'s file\n');
    const before = snapshot(shared);
    const r = flow(work, 'install-git-hooks', '--uninstall');
    assert.equal(r.code, 0);
    assert.match(r.out, /no ADF pre-push hook installed/);
    assert.deepEqual(snapshot(shared), before);
  });

  it('removes ADF\'s marked hooks from a hooks dir outside the git dir', (t) => {
    const { work, dir } = adfRepo(t);
    const shared = path.join(dir, 'shared-hooks');
    fs.mkdirSync(shared);
    sh(work, 'git', 'config', 'core.hooksPath', shared);
    fs.writeFileSync(path.join(shared, 'pre-push'), HOOK_FILE_124, { mode: 0o755 });
    fs.writeFileSync(path.join(shared, 'pre-push.adf-chained'), '#!/bin/sh\nexit 0\n');
    assert.equal(flow(work, 'install-git-hooks', '--uninstall').code, 0);
    assert.equal(fs.readFileSync(path.join(shared, 'pre-push'), 'utf8'), '#!/bin/sh\nexit 0\n');
  });
});

describe('hook scripts', () => {
  it('a commit from a tree with 1.2.4\'s git scripts and no native-pre-commit.cjs passes', (t) => {
    const { work } = adfRepo(t);
    assert.equal(flow(work, 'install-git-hooks').code, 0);
    fs.rmSync(path.join(work, '.claude/skills/git/scripts/native-pre-commit.cjs'));
    write(work, 'k.js', `k = "${FAKE_AWS}"\n`);
    sh(work, 'git', 'add', 'k.js');
    const r = gitRun(work, 'commit', '-m', 'feat: k');
    assert.equal(r.code, 0, r.err);
  });

  it('a missing node warns and passes', (t) => {
    const { work } = adfRepo(t);
    assert.equal(flow(work, 'install-git-hooks', '--only', 'pre-commit').code, 0);
    write(work, 'k.js', `k = "${FAKE_AWS}"\n`);
    sh(work, 'git', 'add', 'k.js');
    // A PATH with git's own directory but no node
    const gitBin = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-git-bin-'));
    t.after(() => fs.rmSync(gitBin, { recursive: true, force: true }));
    const gitPath = spawnSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).stdout.trim();
    fs.symlinkSync(gitPath, path.join(gitBin, 'git'));
    for (const tool of ['sh', 'dirname']) {
      const p = spawnSync('sh', ['-c', `command -v ${tool}`], { encoding: 'utf8' }).stdout.trim();
      fs.symlinkSync(p, path.join(gitBin, tool));
    }
    const r = spawnSync(gitPath, ['commit', '-m', 'feat: k'], { cwd: work, encoding: 'utf8', env: { ...process.env, PATH: gitBin } });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stderr, /ADF pre-commit: node not found; secret scan skipped/);
  });

  it('the installed pre-push hook stops a real force push to main', (t) => {
    const { work } = adfRepo(t);
    assert.equal(flow(work, 'install-git-hooks').code, 0);
    sh(work, 'git', 'commit', '--quiet', '--amend', '--no-verify', '-m', 'chore: rewritten');
    const push = gitRun(work, 'push', '--force', 'origin', 'main');
    assert.notEqual(push.code, 0);
    assert.match(push.err, /force-pushing main is not allowed/);
  });
});
