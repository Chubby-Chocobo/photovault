'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { spawnSync, execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { scanDiff, isSecretFile, matchLine } = require('../lib/commit-secret-scanner.cjs');
const { extractCommitMessage, checkCommitMessage } = require('../lib/commit-message-parser.cjs');

const HOOK = path.resolve(__dirname, '..', 'commit-guard.cjs');
// Built by concatenation so this file never contains a literal credential-shaped string
const FAKE_AWS = 'AKIA' + 'QWERTYUIOPASDFGH';
const FAKE_GITHUB = 'ghp_' + 'abcdefghijklmnopqrstuvwxyz0123456789AB';

function makeRepo(config) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'commit-guard-'));
  const git = (...args) => execFileSync('git', args, { cwd: dir, stdio: 'ignore' });
  git('init', '--initial-branch=main');
  git('config', 'user.email', 'test@example.com');
  git('config', 'user.name', 'Test');
  if (config) {
    fs.mkdirSync(path.join(dir, '.claude', 'config'), { recursive: true });
    fs.writeFileSync(path.join(dir, '.claude', 'config', 'adf-config.json'), JSON.stringify(config));
  }
  fs.writeFileSync(path.join(dir, 'README.md'), '# repo\n');
  git('add', '.');
  git('commit', '-m', 'init');
  git('checkout', '-q', '-b', 'feat/test'); // off the main branch, so only the check under test speaks
  return { dir, git };
}

function runHook(dir, command, env = {}) {
  const result = spawnSync('node', [HOOK], {
    input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command }, cwd: dir }),
    encoding: 'utf8',
    cwd: dir,
    env: { ...process.env, HOME: dir, CLAUDE_PROJECT_DIR: '', ...env },
  });
  assert.strictEqual(result.status, 0, result.stderr);
  return result.stdout.trim() ? JSON.parse(result.stdout).hookSpecificOutput : null;
}

test('scanDiff reports added credential lines with file and line, never the value', () => {
  const diff = [
    'diff --git a/src/a.js b/src/a.js', '--- a/src/a.js', '+++ b/src/a.js', '@@ -0,0 +3,2 @@', `+const k = "${FAKE_AWS}";`, '+const ok = 1;',
    'diff --git a/src/b.js b/src/b.js', '--- a/src/b.js', '+++ b/src/b.js', '@@ -1 +1 @@', '-old', `+t = "${FAKE_GITHUB}"`,
  ].join('\n');
  const findings = scanDiff(diff);
  assert.deepStrictEqual(findings, [
    { file: 'src/a.js', line: 3, rule: 'AWS access key' },
    { file: 'src/b.js', line: 1, rule: 'GitHub token' },
  ]);
  assert.ok(!JSON.stringify(findings).includes(FAKE_AWS));
});

test('a line marked adf-allow-secret is skipped', () => {
  assert.strictEqual(matchLine(`example ${FAKE_AWS} <!-- adf-allow-secret -->`), null);
  assert.strictEqual(matchLine(`key ${FAKE_AWS}`), 'AWS access key');
});

test('secret files are recognised, templates are not', () => {
  for (const file of ['.env', 'app/.env.local', 'certs/server.pem', 'id_ed25519', 'config/secrets.yml']) {
    assert.ok(isSecretFile(file), file);
  }
  for (const file of ['.env.example', '.env.local.example', 'app/.env.sample', 'id_ed25519.pub', 'src/env.js', 'keys.md']) {
    assert.ok(!isSecretFile(file), file);
  }
});

test('extractCommitMessage handles -m, repeated -m, -am, heredocs and -F', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'commit-msg-'));
  fs.writeFileSync(path.join(dir, 'msg.txt'), 'fix: from file\n');
  assert.strictEqual(extractCommitMessage(`git commit -m "feat: add x"`, dir), 'feat: add x');
  assert.strictEqual(extractCommitMessage(`git add . && git commit -am 'fix: y' -m "body"`, dir), 'fix: y\n\nbody');
  assert.strictEqual(extractCommitMessage(`git commit --message='docs: z'`, dir), 'docs: z');
  assert.strictEqual(extractCommitMessage(`git commit -m "$(cat <<'EOF'\nchore: heredoc\n\nbody line\nEOF\n)"`, dir), 'chore: heredoc\n\nbody line');
  assert.strictEqual(extractCommitMessage('git commit -F msg.txt', dir), 'fix: from file\n');
  assert.strictEqual(extractCommitMessage(`git commit -m "$(cat <<'EOF'\nfix: handle "a; b" case\nEOF\n)"`, dir), 'fix: handle "a; b" case');
  assert.strictEqual(extractCommitMessage(`git commit -m "$(generate-message)"`, dir), null, 'an unevaluable substitution is not judged');
  assert.strictEqual(extractCommitMessage('git commit', dir), null);
  assert.strictEqual(extractCommitMessage('git status', dir), null);
});

test('checkCommitMessage flags non-conventional subjects and AI attribution', () => {
  assert.deepStrictEqual(checkCommitMessage('feat(api)!: drop v1\n\nbody'), []);
  assert.deepStrictEqual(checkCommitMessage('Merge branch main'), []);
  assert.match(checkCommitMessage('Added stuff')[0], /not a conventional commit/);
  assert.match(checkCommitMessage('fix: x\n\nCo-Authored-By: Claude <noreply@anthropic.com>')[0], /AI attribution/);
  assert.deepStrictEqual(checkCommitMessage('docs: describe the Claude Code harness'), [], 'mentioning a product is not attribution');
});

test('hook asks before committing a staged secret and lists file:line only', () => {
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, 'config.js'), `const k = "${FAKE_AWS}";\n`);
  fs.writeFileSync(path.join(dir, '.env'), 'X=1\n');
  git('add', '-f', 'config.js', '.env');
  const out = runHook(dir, `git commit -m 'feat: config'`);
  assert.strictEqual(out.permissionDecision, 'ask');
  assert.match(out.permissionDecisionReason, /config\.js:1 \(AWS access key\)/);
  assert.match(out.permissionDecisionReason, /\.env \(secret file\)/);
  assert.ok(!out.permissionDecisionReason.includes(FAKE_AWS));
});

test('hook stays silent for clean commits and non-commit commands', () => {
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, 'a.js'), 'const a = 1;\n');
  git('add', 'a.js');
  assert.strictEqual(runHook(dir, `git commit -m 'feat: a'`), null);
  fs.writeFileSync(path.join(dir, 'b.js'), `const k = "${FAKE_AWS}";\n`);
  git('add', 'b.js');
  assert.strictEqual(runHook(dir, 'git status'), null);
  assert.strictEqual(runHook(dir, 'echo "git commit later"'), null, 'a quoted mention is not a commit');
});

test('a credential embedded in a manifest URL asks, naming file:line and the rule but not the value', () => {
  const { dir, git } = makeRepo();
  const cargo = (userinfo) => `[dependencies.vdax_libs]\ngit = "https://${userinfo}@github.com/acme/vdax-libs"\ntag = "v1"\n`;
  fs.writeFileSync(path.join(dir, 'Cargo.toml'), cargo(FAKE_GITHUB));
  git('add', 'Cargo.toml');
  const out = runHook(dir, `git commit -m 'feat: cargo'`);
  assert.strictEqual(out.permissionDecision, 'ask');
  assert.match(out.permissionDecisionReason, /Cargo\.toml:2 \(credential in URL\)/);
  assert.ok(!out.permissionDecisionReason.includes(FAKE_GITHUB));

  // A long bare userinfo is a credential too
  const bare = 'q'.repeat(52);
  fs.writeFileSync(path.join(dir, 'package.json'), `{"dependencies":{"x":"git+https://${bare}@github.com/acme/x.git"}}\n`);
  git('add', 'package.json');
  const second = runHook(dir, `git commit -m 'feat: pkg'`);
  assert.match(second.permissionDecisionReason, /package\.json:1 \(credential in URL\)/);
  assert.ok(!second.permissionDecisionReason.includes(bare));
});

test('placeholders and plain URLs in manifests do not trip the credential check', () => {
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, 'Cargo.toml'), 'git = "https://${TOKEN}@github.com/acme/x"\nb = "https://<user>:<token>@h.io"\nc = "https://github.com/acme/y"\nd = "git@github.com:acme/z.git"\n');
  git('add', 'Cargo.toml');
  assert.strictEqual(runHook(dir, `git commit -m 'feat: cargo'`), null);
  assert.deepStrictEqual(scanDiff(['diff --git a/a b/a', '--- a/a', '+++ b/a', '@@ -0,0 +1 @@', `+x = "https://${FAKE_GITHUB}@h.io" # adf-allow-secret`].join('\n')), []);
});

test('scanning many lines does not skip any because of regex state', () => {
  const line = `url = "https://${FAKE_GITHUB}@github.com/a/b"`;
  const diff = ['diff --git a/c b/c', '--- a/c', '+++ b/c', '@@ -0,0 +1,3 @@', `+${line}`, `+${line}`, `+${line}`].join('\n');
  assert.deepStrictEqual(scanDiff(diff).map((f) => f.line), [1, 2, 3]);
});

test('git add && git commit scans untracked files before they are staged', () => {
  const { dir } = makeRepo();
  fs.writeFileSync(path.join(dir, 'token.js'), `t = "${FAKE_GITHUB}"\n`);
  const out = runHook(dir, `git add . && git commit -m 'feat: token'`);
  assert.strictEqual(out.permissionDecision, 'ask');
  assert.match(out.permissionDecisionReason, /token\.js:1 \(GitHub token\)/);
});

test('message format follows git.enforcement, and the older messageFormat still decides when set', () => {
  assert.strictEqual(runHook(makeRepo().dir, `git commit -m 'Added stuff'`).permissionDecision, 'ask');
  assert.strictEqual(runHook(makeRepo({ git: { enforcement: 'off' } }).dir, `git commit -m 'Added stuff'`), null);
  assert.strictEqual(runHook(makeRepo({ commitGuard: { messageFormat: false } }).dir, `git commit -m 'Added stuff'`), null);
  assert.strictEqual(runHook(makeRepo({ git: { enforcement: 'deny' } }).dir, `git commit -m 'Added stuff'`).permissionDecision, 'deny');
  const on = makeRepo({ commitGuard: { messageFormat: true } });
  const out = runHook(on.dir, `git commit -m 'Added stuff'`);
  assert.strictEqual(out.permissionDecision, 'deny');
  assert.match(out.permissionDecisionReason, /not a conventional commit/);
  assert.strictEqual(runHook(on.dir, `git commit -m 'feat: added stuff'`), null);
});

test('hooks.commit-guard=false and commitGuard.secrets=false turn the checks off', () => {
  for (const config of [{ hooks: { 'commit-guard': false } }, { commitGuard: { secrets: false } }]) {
    const { dir, git } = makeRepo(config);
    fs.writeFileSync(path.join(dir, 'k.js'), `k = "${FAKE_AWS}"\n`);
    git('add', 'k.js');
    assert.strictEqual(runHook(dir, `git commit -m 'feat: k'`), null, JSON.stringify(config));
  }
});

test('an added line starting with "++" is content, not a file header', () => {
  const diff = ['diff --git a/a.txt b/a.txt', '--- a/a.txt', '+++ b/a.txt', '@@ -0,0 +1,2 @@', '+++ counter', `+k = "${FAKE_AWS}"`].join('\n');
  assert.deepStrictEqual(scanDiff(diff), [{ file: 'a.txt', line: 2, rule: 'AWS access key' }]);
});

test('secrets are found whatever the diff prefix and path quoting settings', () => {
  const { dir, git } = makeRepo();
  git('config', 'diff.noprefix', 'true');
  git('config', 'diff.mnemonicPrefix', 'true');
  fs.writeFileSync(path.join(dir, 'café.js'), `k = "${FAKE_AWS}"\n`);
  git('add', 'café.js');
  const out = runHook(dir, `git commit -m 'feat: x'`);
  assert.match(out.permissionDecisionReason, /café\.js:1 \(AWS access key\)/);
});

test('git add <paths> scans only those paths, not every untracked file', () => {
  const { dir } = makeRepo();
  fs.writeFileSync(path.join(dir, 'clean.js'), 'const a = 1;\n');
  fs.writeFileSync(path.join(dir, 'fixture.js'), `k = "${FAKE_AWS}"\n`);
  assert.strictEqual(runHook(dir, `git add clean.js && git commit -m 'feat: clean'`), null);
  assert.strictEqual(runHook(dir, `git add fixture.js && git commit -m 'feat: f'`).permissionDecision, 'ask');
});

test('the message check accepts heredoc messages with quotes when enabled', () => {
  const { dir } = makeRepo({ commitGuard: { messageFormat: true } });
  assert.strictEqual(runHook(dir, `git commit -m "$(cat <<'EOF'\nRevert "feat: x"\n\nbody\nEOF\n)"`), null);
});

test('git add -f scans ignored files the force-add records', () => {
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, '.gitignore'), '.env\n');
  git('add', '.gitignore');
  git('commit', '-m', 'ignore env');
  fs.writeFileSync(path.join(dir, '.env'), 'X=1\n');
  assert.strictEqual(runHook(dir, `git add .env && git commit -m 'feat: env'`), null, 'git add without -f refuses an ignored file');
  assert.match(runHook(dir, `git add -f .env && git commit -m 'feat: env'`).permissionDecisionReason, /\.env \(secret file\)/);
});

test('git commit <paths> scans the unstaged changes of those paths', () => {
  const { dir } = makeRepo();
  fs.appendFileSync(path.join(dir, 'README.md'), `k = "${FAKE_AWS}"\n`);
  for (const command of [`git commit README.md -m 'docs: x'`, `git commit -m 'docs: x' -- README.md`]) {
    assert.match(runHook(dir, command).permissionDecisionReason, /README\.md:2 \(AWS access key\)/, command);
  }
  assert.strictEqual(runHook(dir, `git commit -m 'docs: README.md'`), null, 'the message is not a path');
});

test('stagingScopes skips option values when reading commit paths', () => {
  const { stagingScopes } = require('../commit-guard.cjs');
  const cwd = path.resolve('/tmp/repo');
  assert.deepStrictEqual(stagingScopes(`git commit --author 'A <a@b.c>' -m msg src/a.js`, cwd),
    [{ cwd, scope: { tracked: 'head', untracked: false, ignored: false, commitAll: false, bulkAdds: [], paths: ['src/a.js'] } }]);
  assert.deepStrictEqual(stagingScopes(`git commit -m msg`, cwd), [{ cwd, scope: { tracked: 'cached', untracked: false, ignored: false, commitAll: false, bulkAdds: [], paths: null } }]);
  assert.deepStrictEqual(stagingScopes(`cd pkg && git add a.js && git commit -m msg`, cwd).map((e) => e.cwd), [path.join(cwd, 'pkg')]);
  assert.deepStrictEqual(stagingScopes(`git add -A && git commit -m a && git add . && git commit -m b && git add :/`, cwd)[0].scope.bulkAdds, [['-A'], ['.']]);
});

test('file names with spaces are reported without git\'s trailing tab', () => {
  const diff = ['diff --git a/my file.js b/my file.js', '--- /dev/null', '+++ b/my file.js\t', '@@ -0,0 +1 @@', `+k = "${FAKE_AWS}"`].join('\n');
  assert.deepStrictEqual(scanDiff(diff), [{ file: 'my file.js', line: 1, rule: 'AWS access key' }]);
});

test('subject length, trailing period, path types, commit -a and direct commits on main', () => {
  const { dir, git } = makeRepo({ git: { commit: { pathTypes: { 'lib/': ['feat', 'fix'] } } } });
  const long = 'feat: ' + 'x'.repeat(80);
  assert.match(runHook(dir, `git commit -m '${long}'`).permissionDecisionReason, /86 characters; keep it within 72/);
  assert.match(runHook(dir, `git commit -m 'fix: a thing.'`).permissionDecisionReason, /ends with a period/);

  fs.mkdirSync(path.join(dir, 'lib'));
  fs.writeFileSync(path.join(dir, 'lib', 'x.js'), '1\n');
  git('add', 'lib/x.js');
  assert.match(runHook(dir, `git commit -m 'docs: x'`).permissionDecisionReason, /A docs commit may not touch lib\/ \(allowed there: feat, fix\): lib\/x\.js/);
  assert.strictEqual(runHook(dir, `git commit -m 'feat: x'`), null);

  fs.appendFileSync(path.join(dir, 'README.md'), 'more\n');
  assert.match(runHook(dir, `git commit -am 'feat: x'`).permissionDecisionReason, /"git commit -a" commits every tracked change/);

  git('checkout', '-q', 'main');
  const onMain = runHook(dir, `git commit -m 'feat: x'`);
  assert.strictEqual(onMain.permissionDecision, 'ask');
  assert.match(onMain.permissionDecisionReason, /commits on main[\s\S]*outside: lib\/x\.js/);
  git('reset', '-q');
  fs.mkdirSync(path.join(dir, 'docs'));
  fs.writeFileSync(path.join(dir, 'docs', 'a.md'), '# a\n');
  git('add', 'docs/a.md');
  assert.strictEqual(runHook(dir, `git commit -m 'chore(docs): add a'`), null);
});

test('an inline cd or git -C does not hide a secret from the scan', () => {
  const { dir } = makeRepo();
  fs.mkdirSync(path.join(dir, 'pkg', 'src'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'pkg', 'src', 'config.ts'), `const k = "${FAKE_AWS}";\n`);
  for (const command of [
    `git add pkg/src/config.ts && git commit -m 'feat: x'`,
    `cd pkg && git add src/config.ts && git commit -m 'feat: x'`,
    `git -C pkg add src/config.ts && git -C pkg commit -m 'feat: x'`,
    `(cd pkg && git add . && git commit -m 'feat: x')`,
  ]) {
    const out = runHook(dir, command);
    assert.ok(out, command);
    assert.strictEqual(out.permissionDecision, 'ask', command);
    assert.match(out.permissionDecisionReason, /config\.ts:1 \(AWS access key\)/, command);
  }
});

test('git -C commit still has its message checked', () => {
  const { dir } = makeRepo();
  const out = runHook(dir, `git -C ${dir} commit --allow-empty -m 'Added stuff'`);
  assert.match(out.permissionDecisionReason, /not a conventional commit/);
});

test('a cd target the guard cannot resolve still gets the commit checked', () => {
  const { dir } = makeRepo();
  fs.writeFileSync(path.join(dir, 'config.js'), `const k = "${FAKE_AWS}";\n`);
  require('node:child_process').execFileSync('git', ['add', 'config.js'], { cwd: dir });
  for (const command of [
    `cd "$(git rev-parse --show-toplevel)" && git commit -m 'feat: x'`,
    `cd "$PWD" && git commit -m 'feat: x'`,
    `cd ~ && cd - && git commit -m 'feat: x'`,
    `cd $SOME_DIR && git commit -m 'feat: x'`,
    `cd \`pwd\` && git commit -m 'feat: x'`,
  ]) {
    const out = runHook(dir, command);
    assert.ok(out, command);
    assert.strictEqual(out.permissionDecision, 'ask', command);
    assert.match(out.permissionDecisionReason, /config\.js:1 \(AWS access key\)/, command);
  }
});

test('~ and $HOME in a cd target move the scan to the home directory', () => {
  const os = require('node:os');
  const { parseCommands } = require('../lib/git-command-parser.cjs');
  assert.strictEqual(parseCommands('cd ~/repo && git commit -m x', '/w')[0].cwd, path.join(os.homedir(), 'repo'));
  assert.strictEqual(parseCommands('cd $HOME/repo && git commit -m x', '/w')[0].cwd, path.join(os.homedir(), 'repo'));
  assert.strictEqual(parseCommands('cd sub && cd $PWD/x && git commit -m x', '/w')[0].cwd, path.join('/w', 'sub', 'x'));
});

test('an unscannable commit directory asks instead of passing silently', () => {
  const missing = path.join(os.tmpdir(), 'commit-guard-missing-' + process.pid);
  const out = runHook(os.tmpdir(), `cd ${missing} && git commit -m 'feat: x'`);
  assert.ok(out);
  assert.strictEqual(out.permissionDecision, 'ask');
  assert.match(out.permissionDecisionReason, /not scanned for secrets/);
});

/** Stages a key line and over 32 MB of plain text, more than the scanner reads in one diff. */
function stageKeyAndHugeDiff(dir) {
  const git = (...args) => execFileSync('git', args, { cwd: dir, stdio: 'ignore' });
  fs.writeFileSync(path.join(dir, 'key.txt'), `aws = "${FAKE_AWS}"\n`);
  fs.writeFileSync(path.join(dir, 'dump.sql'), 'INSERT INTO t VALUES (1, \'filler filler filler\');\n'.repeat(700 * 1024));
  git('add', 'key.txt', 'dump.sql');
}

test('a repository whose scan fails is reported with the cause, at the secret level', () => {
  const { dir } = makeRepo({ commitGuard: { messageFormat: true } });
  cleanup.push(dir);
  stageKeyAndHugeDiff(dir);
  const ask = runHook(dir, `git commit -m 'feat: dump'`);
  assert.strictEqual(ask.permissionDecision, 'ask');
  assert.match(ask.permissionDecisionReason, /could not be scanned for secrets: the staged text changes are larger than the scanner can read at once \(32 MB\)/);
  assert.doesNotMatch(ask.permissionDecisionReason, /Could not work out which repository/);

  const deny = runHook(dir, `git commit -m 'feat: dump'`, { ADF_MODE: 'auto' });
  assert.strictEqual(deny.permissionDecision, 'deny');
  assert.match(deny.permissionDecisionReason, /^Stop and tell the user; the remedies are a person's/m);
  assert.doesNotMatch(deny.permissionDecisionReason, /approve/, 'Claude reads the deny reason: no remedy it could apply itself');

  const message = runHook(dir, `git commit -m 'Dump.'`);
  assert.strictEqual(message.permissionDecision, 'deny', 'the workflow checks still run when the scan fails');
  assert.match(message.permissionDecisionReason, /Commit message rejected/);
  assert.match(message.permissionDecisionReason, /could not be scanned for secrets/);
});

test('a nested repository whose scan fails is not swapped for the session repository', () => {
  const { dir: root } = makeRepo();
  cleanup.push(root);
  fs.writeFileSync(path.join(root, '.gitignore'), 'services/\n');
  const member = path.join(root, 'services', 'api');
  fs.mkdirSync(path.join(member, 'src'), { recursive: true });
  const git = (...args) => execFileSync('git', args, { cwd: member, stdio: 'ignore' });
  git('init', '--initial-branch=main');
  git('config', 'user.email', 'test@example.com');
  git('config', 'user.name', 'Test');
  git('checkout', '-q', '-b', 'feat/x');
  stageKeyAndHugeDiff(member);
  for (const command of [`git -C services/api commit -m 'feat: x'`, `cd services/api && git commit -m 'feat: x'`, `cd services/api/src && git commit -m 'feat: x'`]) {
    for (const [env, level] of [[{}, 'ask'], [{ ADF_MODE: 'auto' }, 'deny']]) {
      const out = runHook(root, command, env);
      assert.ok(out, `${command} ${level}: the clean session repo must not stand in for the member`);
      assert.strictEqual(out.permissionDecision, level, command);
      assert.match(out.permissionDecisionReason, new RegExp(`staged changes in ${member.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(/src)? could not be scanned`), command);
    }
  }
});

test('git -C with a quoted path that has spaces is still guarded', () => {
  const { dir } = makeRepo();
  const spaced = path.join(dir, 'my repo');
  fs.mkdirSync(spaced);
  const git = (...args) => execFileSync('git', args, { cwd: spaced, stdio: 'ignore' });
  git('init', '--initial-branch=main');
  git('config', 'user.email', 'test@example.com');
  git('config', 'user.name', 'Test');
  git('checkout', '-q', '-b', 'feat/x');
  fs.writeFileSync(path.join(spaced, 'k.js'), `k = "${FAKE_AWS}"\n`);
  git('add', 'k.js');
  const out = runHook(dir, `git -C "my repo" commit -m 'feat: x'`);
  assert.ok(out);
  assert.match(out.permissionDecisionReason, /k\.js:1 \(AWS access key\)/);
});

test('pushd and --git-dir move the scan to the repository they name', () => {
  const { dir } = makeRepo();
  try {
    const inner = path.join(dir, 'pkg');
    fs.mkdirSync(inner);
    const git = (...args) => execFileSync('git', args, { cwd: inner, stdio: 'ignore' });
    git('init', '--initial-branch=main');
    git('config', 'user.email', 'test@example.com');
    git('config', 'user.name', 'Test');
    git('checkout', '-q', '-b', 'feat/x');
    fs.writeFileSync(path.join(inner, 'k.js'), `k = "${FAKE_AWS}"\n`);
    git('add', 'k.js');
    for (const command of [
      `pushd pkg && git commit -m 'feat: x'`,
      `git --git-dir=pkg/.git commit -m 'feat: x'`,
      `git --git-dir pkg/.git --work-tree pkg commit -m 'feat: x'`,
    ]) {
      const out = runHook(dir, command);
      assert.ok(out, command);
      assert.match(out.permissionDecisionReason, /k\.js:1 \(AWS access key\)/, command);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('an earlier git add --all is reported as a bulk add, not as git commit -a', () => {
  const { dir } = makeRepo({ git: { commit: { pathTypes: { 'lib/': ['feat', 'fix'] } } } });
  try {
    fs.appendFileSync(path.join(dir, 'README.md'), 'more\n');
    for (const add of ['--all', '-A']) {
      const reason = runHook(dir, `git add ${add} && git commit -m 'feat: x'`).permissionDecisionReason;
      assert.match(reason, new RegExp(`^Git workflow \\(docs/conventions/git-workflow\\.md\\):\n"git add ${add}" stages everything`));
      assert.doesNotMatch(reason, /"git commit -a"/);
    }
    assert.match(runHook(dir, `git commit --all -m 'feat: x'`).permissionDecisionReason, /"git commit -a"/);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a bulk add before the commit shares one reason with the secret scan', () => {
  const { dir } = makeRepo();
  try {
    fs.writeFileSync(path.join(dir, 'k.js'), `const k = "${FAKE_AWS}";\n`);
    const out = runHook(dir, `git add -A && git commit -m 'feat: x'`);
    assert.strictEqual(out.permissionDecision, 'ask');
    assert.match(out.permissionDecisionReason, /"git add -A" stages everything/);
    assert.match(out.permissionDecisionReason, /This commit would record secrets:\n {2}- k\.js:1 \(AWS access key\)/);
    assert.ok(!out.permissionDecisionReason.includes(FAKE_AWS));
    assert.doesNotMatch(runHook(dir, `git commit -m 'feat: x' && git add -A`)?.permissionDecisionReason || '', /stages everything/, 'an add after the commit is git-flow-guard\'s');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('the bulk add follows the level in auto mode, and stays with git-flow-guard when that hook is off', () => {
  const cases = [
    [undefined, { ADF_MODE: 'auto' }, false], // auto turns the ask level off
    [{ git: { enforcement: 'deny' } }, { ADF_MODE: 'auto' }, true], // a deny stays, in the one reason
    [{ hooks: { 'git-flow-guard': false } }, {}, false],
  ];
  for (const [config, env, reported] of cases) {
    const { dir } = makeRepo(config);
    try {
      fs.writeFileSync(path.join(dir, 'k.js'), `const k = "${FAKE_AWS}";\n`);
      const out = runHook(dir, `git add -A && git commit -m 'feat: x'`, env);
      const label = JSON.stringify([config, env]);
      assert.strictEqual(out.permissionDecision, env.ADF_MODE ? 'deny' : 'ask', label);
      assert.match(out.permissionDecisionReason, /k\.js:1 \(AWS access key\)/);
      assert.strictEqual(/stages everything/.test(out.permissionDecisionReason), reported, label);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
});

const cleanup = [];
test.after(() => cleanup.forEach((d) => fs.rmSync(d, { recursive: true, force: true })));

test('--work-tree does not move the scan away from the repository git finds', () => {
  const { dir, git } = makeRepo();
  try {
    fs.writeFileSync(path.join(dir, 'config.js'), `k = "${FAKE_AWS}"\n`);
    git('add', 'config.js');
    const elsewhere = fs.mkdtempSync(path.join(os.tmpdir(), 'commit-guard-tree-'));
    cleanup.push(elsewhere);
    execFileSync('git', ['init', '-q', elsewhere]); // another repository, which git does not consult here
    for (const command of [
      `git --work-tree=${elsewhere} commit -m 'feat: x'`,
      `git --work-tree ${elsewhere} commit -m 'feat: x'`,
    ]) {
      const out = runHook(dir, command);
      assert.ok(out, command);
      assert.match(out.permissionDecisionReason, /config\.js:1 \(AWS access key\)/, command);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

// A commit in a workspace member follows the member's rules, whichever directory the session started in
test('a commit in a workspace member follows the member rules, not the workspace rules', () => {
  const { memberGitWorkspace, setManifestMember, writeAdfConfig } = require('./fixtures/member-git-fixtures.cjs');
  const t = { after: (fn) => process.on('exit', fn) };
  const ws = memberGitWorkspace(t);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'commit-guard-home-'));
  process.on('exit', () => fs.rmSync(home, { recursive: true, force: true }));
  const run = (cwd, command, projectDir = ws.root) => {
    const result = spawnSync('node', [HOOK], {
      input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command }, cwd }),
      encoding: 'utf8', cwd, env: { ...process.env, HOME: home, CLAUDE_PROJECT_DIR: projectDir },
    });
    assert.strictEqual(result.status, 0, result.stderr);
    return result.stdout.trim() ? JSON.parse(result.stdout).hookSpecificOutput : null;
  };
  const order = ws.members.order;
  const stage = (rel, content) => {
    fs.mkdirSync(path.dirname(path.join(order, rel)), { recursive: true });
    fs.writeFileSync(path.join(order, rel), content);
    execFileSync('git', ['add', rel], { cwd: order, stdio: 'ignore' });
  };
  // The workspace turns the commit checks off; the member (no config, manifest flow off, enforcement ask) keeps them
  writeAdfConfig(ws.root, { git: { flow: 'trunk', enforcement: 'off' } });

  const all = run(ws.root, `git -C services/order commit -a -m 'feat: x'`);
  assert.strictEqual(all.permissionDecision, 'ask');
  assert.match(all.permissionDecisionReason, /"git commit -a" commits every tracked change/);
  assert.strictEqual(run(order, `git commit -a -m 'feat: x'`, order).permissionDecision, 'ask', 'same rules from a session launched in the member');
  const bulk = run(ws.root, `git -C services/order add -A && git -C services/order commit -m 'feat: x'`);
  assert.match(bulk.permissionDecisionReason, /^Git workflow \(member order: [^\n]*\):\n"git add -A" stages everything/m, 'the member rules label');

  stage('deploy.pem', '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n'); // adf-allow-secret
  const secret = run(ws.root, `git -C services/order commit -m 'feat: x'`);
  assert.strictEqual(secret.permissionDecision, 'ask');
  assert.match(secret.permissionDecisionReason, /deploy\.pem \(secret file\)/);
  execFileSync('git', ['restore', '--staged', 'deploy.pem'], { cwd: order, stdio: 'ignore' });

  // Member config with a release-train: commits on main only go through on the member's direct-push paths
  writeAdfConfig(order, { git: { flow: 'release-train', mainBranch: 'main', directPush: { paths: ['notes/**'] } } });
  stage('notes/a.md', '# a\n');
  assert.strictEqual(run(ws.root, `git -C services/order commit -m 'chore: add notes'`), null);
  execFileSync('git', ['restore', '--staged', 'notes/a.md'], { cwd: order, stdio: 'ignore' });
  stage('README.md', '# order\n');
  const outside = run(ws.root, `git -C services/order commit -m 'chore: readme'`);
  assert.strictEqual(outside.permissionDecision, 'ask');
  assert.match(outside.permissionDecisionReason, /commits on main[\s\S]*outside: README\.md/);

  // Manifest rules are used when the member has no config of its own
  fs.rmSync(path.join(order, '.claude'), { recursive: true });
  setManifestMember(ws.root, 'order', { git: { flow: 'trunk', enforcement: 'ask', mainBranch: 'main' } });
  stage('src/app.js', 'x\n');
  assert.match(run(ws.root, `git -C services/order commit -m 'chore: app'`).permissionDecisionReason, /commits on main[\s\S]*outside: src\/app\.js/);
});

test('commitGuard.secrets of the repo being committed in decides, not the session project', () => {
  const { memberGitWorkspace, writeAdfConfig } = require('./fixtures/member-git-fixtures.cjs');
  const t = { after: (fn) => process.on('exit', fn) };
  const ws = memberGitWorkspace(t);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'commit-guard-home-'));
  process.on('exit', () => fs.rmSync(home, { recursive: true, force: true }));
  const run = (cwd, command, projectDir) => {
    const result = spawnSync('node', [HOOK], {
      input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command }, cwd }),
      encoding: 'utf8', cwd, env: { ...process.env, HOME: home, CLAUDE_PROJECT_DIR: projectDir },
    });
    assert.strictEqual(result.status, 0, result.stderr);
    return result.stdout.trim() ? JSON.parse(result.stdout).hookSpecificOutput : null;
  };
  const order = ws.members.order;
  fs.writeFileSync(path.join(order, 'deploy.pem'), '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n'); // adf-allow-secret
  execFileSync('git', ['add', 'deploy.pem'], { cwd: order, stdio: 'ignore' });
  const commit = `git -C services/order commit -m 'feat: x'`;

  writeAdfConfig(ws.root, { commitGuard: { secrets: false } });
  assert.match(run(ws.root, commit, ws.root).permissionDecisionReason, /deploy\.pem \(secret file\)/, 'the workspace setting does not switch off a member scan');
  writeAdfConfig(ws.root, {});
  writeAdfConfig(order, { commitGuard: { secrets: false } });
  assert.strictEqual(run(ws.root, commit, ws.root), null, "the member's own setting applies from a workspace session");
});

test('files under commitGuard.allowSecretFiles are skipped, names and lines, staged or untracked', () => {
  const { dir, git } = makeRepo({ commitGuard: { allowSecretFiles: ['test/fixtures/**', 'certs/dev.pem'] } });
  fs.mkdirSync(path.join(dir, 'test', 'fixtures'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'certs'));
  fs.writeFileSync(path.join(dir, 'test', 'fixtures', 'keys.js'), `k = "${FAKE_AWS}"\n`);
  fs.writeFileSync(path.join(dir, 'test', 'fixtures', '.env'), 'X=1\n');
  fs.writeFileSync(path.join(dir, 'certs', 'dev.pem'), 'pem\n');
  git('add', '-f', 'test', 'certs');
  assert.strictEqual(runHook(dir, `git commit -m 'test: fixtures'`), null);
  fs.writeFileSync(path.join(dir, 'test', 'fixtures', 'more.js'), `k = "${FAKE_GITHUB}"\n`);
  assert.strictEqual(runHook(dir, `git add test/fixtures/more.js && git commit -m 'test: more'`), null, 'untracked files under the allowlist pass too');
  fs.writeFileSync(path.join(dir, 'real.js'), `k = "${FAKE_AWS}"\n`);
  git('add', 'real.js');
  assert.match(runHook(dir, `git commit -m 'feat: real'`).permissionDecisionReason, /real\.js:1 \(AWS access key\)/);
});

test('a -diff file and a type change are scanned, a binary gets the name check only', () => {
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, '.gitattributes'), '*.dat -diff\n');
  fs.writeFileSync(path.join(dir, 'blob.dat'), `k = "${FAKE_AWS}"\n`);
  fs.writeFileSync(path.join(dir, 'real.bin'), Buffer.concat([Buffer.from([0, 1, 2]), Buffer.from(`k = "${FAKE_AWS}"\n`)]));
  fs.writeFileSync(path.join(dir, 'server.pem'), Buffer.from([0, 1, 2, 3]));
  git('add', '.gitattributes', 'blob.dat', 'real.bin', 'server.pem');
  const out = runHook(dir, `git commit -m 'feat: blobs'`);
  assert.match(out.permissionDecisionReason, /blob\.dat:1 \(AWS access key\)/, 'found from the staged blob');
  assert.match(out.permissionDecisionReason, /server\.pem \(secret file\)/);
  assert.doesNotMatch(out.permissionDecisionReason, /real\.bin/);

  git('reset', '-q');
  for (const file of ['blob.dat', 'real.bin', 'server.pem', '.gitattributes']) fs.rmSync(path.join(dir, file));
  fs.symlinkSync('README.md', path.join(dir, 'link'));
  git('add', 'link');
  git('commit', '-q', '-m', 'add link');
  fs.rmSync(path.join(dir, 'link'));
  fs.writeFileSync(path.join(dir, 'link'), `k = "${FAKE_GITHUB}"\n`);
  git('add', 'link');
  assert.match(runHook(dir, `git commit -m 'fix: link'`).permissionDecisionReason, /link:1 \(GitHub token\)/, 'symlink to file is a type change');
});

test('a staged binary over the diff buffer does not make auto mode deny', () => {
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, 'big.bin'), Buffer.alloc(40 * 1024 * 1024));
  git('add', 'big.bin');
  assert.strictEqual(runHook(dir, `git commit -m 'feat: big'`, { ADF_MODE: 'auto' }), null);
  assert.strictEqual(runHook(dir, `git commit -m 'feat: big'`), null);
});

test('a name no scan covered is listed as not scanned, and git add of a new file is not', () => {
  const { hidingGitEnv } = require('./fixtures/diff-header-hiding-git.cjs');
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, 'hidden.js'), 'const a = 1;\n');
  git('add', '-A');
  const hide = hidingGitEnv('hidden.js');
  const ask = runHook(dir, `git commit -m 'feat: odd'`, hide);
  assert.strictEqual(ask.permissionDecision, 'ask');
  assert.match(ask.permissionDecisionReason, /could not be scanned for secrets/);
  assert.match(ask.permissionDecisionReason, /adf-allow-secret/, 'the user reads the remedies at ask');

  const deny = runHook(dir, `git commit -m 'feat: odd'`, { ...hide, ADF_MODE: 'auto' });
  assert.strictEqual(deny.permissionDecision, 'deny');
  assert.match(deny.permissionDecisionReason, /could not be scanned for secrets/);
  assert.match(deny.permissionDecisionReason, /^Stop and tell the user; the remedies are a person's/m);
  assert.doesNotMatch(deny.permissionDecisionReason, /adf-allow-secret|commitGuard|--no-verify/, 'Claude reads the deny reason: no remedy it could apply itself');

  git('reset', '-q');
  fs.rmSync(path.join(dir, 'hidden.js'));
  fs.writeFileSync(path.join(dir, 'fresh.js'), 'const b = 2;\n');
  assert.strictEqual(runHook(dir, `git add fresh.js && git commit -m 'feat: fresh'`), null, 'untracked names are read from disk, never unscanned');
});

test('a secret reason at deny level lists findings and names no remedy', () => {
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, 'k.js'), `k = "${FAKE_AWS}"\n`);
  git('add', 'k.js');
  const deny = runHook(dir, `git commit -m 'feat: k'`, { ADF_MODE: 'auto' });
  assert.match(deny.permissionDecisionReason, /k\.js:1 \(AWS access key\)/);
  assert.doesNotMatch(deny.permissionDecisionReason, /adf-allow-secret|commitGuard|--no-verify|uninstall/);
  assert.match(deny.permissionDecisionReason, /Stop and tell the user/);
  const ask = runHook(dir, `git commit -m 'feat: k'`);
  assert.match(ask.permissionDecisionReason, /adf-allow-secret/);
  assert.match(ask.permissionDecisionReason, /commitGuard\.allowSecretFiles/);
});

test('a -diff file is read from its first megabyte of the staged blob', () => {
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, '.gitattributes'), '*.dat -diff\n');
  const filler = 'x'.repeat(99) + '\n';
  fs.writeFileSync(path.join(dir, 'head.dat'), `k = "${FAKE_AWS}"\n${filler.repeat(30000)}`);
  fs.writeFileSync(path.join(dir, 'tail.dat'), `${filler.repeat(30000)}k = "${FAKE_GITHUB}"\n`);
  git('add', '.gitattributes', 'head.dat', 'tail.dat');
  const reason = runHook(dir, `git commit -m 'feat: dat'`).permissionDecisionReason;
  assert.match(reason, /head\.dat:1 \(AWS access key\)/, 'the partial read keeps the first megabyte');
  assert.doesNotMatch(reason, /tail\.dat/, 'a value past the first megabyte is outside the limit untracked files have');
});

test('the scan holds when git reads pathspecs literally, and from a subdirectory with diff.relative', () => {
  const { dir, git } = makeRepo();
  fs.writeFileSync(path.join(dir, 'k.js'), `k = "${FAKE_AWS}"\n`);
  git('add', 'k.js');
  for (const name of ['GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS']) {
    const out = runHook(dir, `git commit -m 'feat: k'`, { [name]: '1' });
    assert.match(out.permissionDecisionReason, /k\.js:1 \(AWS access key\)/, name);
  }
  git('reset', '-q');
  git('config', 'diff.relative', 'true');
  fs.mkdirSync(path.join(dir, 'sub'));
  fs.writeFileSync(path.join(dir, 'sub', 'b.js'), `k = "${FAKE_GITHUB}"\n`);
  git('add', 'k.js', 'sub/b.js');
  const reason = runHook(dir, `cd sub && git commit -m 'feat: k'`).permissionDecisionReason;
  assert.match(reason, /k\.js:1 \(AWS access key\)/, 'a file above the directory is scanned');
  assert.match(reason, /sub\/b\.js:1 \(GitHub token\)/, 'names are relative to the top level');
});

test('work-tree files over a megabyte are read as far as the cap, never skipped', () => {
  const { dir, git } = makeRepo();
  const filler = 'x'.repeat(99) + '\n';
  fs.writeFileSync(path.join(dir, '.gitattributes'), '*.dat -diff\n');
  fs.writeFileSync(path.join(dir, 'f.dat'), 'clean\n');
  git('add', '.gitattributes', 'f.dat');
  git('commit', '-q', '-m', 'add dat');
  fs.writeFileSync(path.join(dir, 'f.dat'), `k = "${FAKE_AWS}"\n${filler.repeat(12000)}`);
  assert.match(runHook(dir, `git commit -am 'fix: dat'`).permissionDecisionReason, /f\.dat:1 \(AWS access key\)/, 'a tracked -diff file, unstaged');
  const auto = runHook(dir, `git commit -am 'fix: dat'`, { ADF_MODE: 'auto' });
  assert.strictEqual(auto.permissionDecision, 'deny', 'auto mode refuses it');
  assert.match(auto.permissionDecisionReason, /f\.dat:1 \(AWS access key\)/);
  git('checkout', '--', 'f.dat');
  fs.writeFileSync(path.join(dir, 'big-new.txt'), `k = "${FAKE_GITHUB}"\n${filler.repeat(12000)}`);
  assert.match(runHook(dir, `git add big-new.txt && git commit -m 'feat: big'`).permissionDecisionReason, /big-new\.txt:1 \(GitHub token\)/, 'a new file');
  assert.strictEqual(runHook(dir, `git add big-new.txt && git commit -m 'feat: big'`, { ADF_MODE: 'auto' }).permissionDecision, 'deny');
});

test('hundreds of clean untracked files are allowed, in auto mode too', () => {
  const { dir } = makeRepo();
  fs.mkdirSync(path.join(dir, 'gen'));
  for (let i = 0; i < 300; i++) fs.writeFileSync(path.join(dir, 'gen', `f${i}.txt`), `${i}\n`);
  assert.strictEqual(runHook(dir, `git add gen/ && git commit -m 'feat: gen'`), null);
  assert.strictEqual(runHook(dir, `git add gen/ && git commit -m 'feat: gen'`, { ADF_MODE: 'auto' }), null);
  fs.writeFileSync(path.join(dir, 'gen', 'k.txt'), `k = "${FAKE_AWS}"\n`);
  assert.match(runHook(dir, `git add gen/ && git commit -m 'feat: gen'`).permissionDecisionReason, /gen\/k\.txt:1 \(AWS access key\)/);
});

test('several -diff files of different sizes are read in one pass and each found', () => {
  const { dir, git } = makeRepo();
  const filler = 'x'.repeat(99) + '\n';
  fs.writeFileSync(path.join(dir, '.gitattributes'), '*.dat -diff\n');
  fs.writeFileSync(path.join(dir, 'a.dat'), `k = "${FAKE_AWS}"\n`);
  fs.writeFileSync(path.join(dir, 'b.dat'), `k = "${FAKE_GITHUB}"\n${filler.repeat(30000)}`);
  fs.writeFileSync(path.join(dir, 'c.dat'), 'clean\n');
  fs.writeFileSync(path.join(dir, 'd.dat'), '');
  fs.writeFileSync(path.join(dir, 'e with space.dat'), `k = "${FAKE_AWS}"\n`);
  git('add', '.gitattributes', 'a.dat', 'b.dat', 'c.dat', 'd.dat', 'e with space.dat');
  const reason = runHook(dir, `git commit -m 'feat: dat'`).permissionDecisionReason;
  assert.match(reason, /a\.dat:1 \(AWS access key\)/);
  assert.match(reason, /b\.dat:1 \(GitHub token\)/);
  assert.match(reason, /e with space\.dat:1 \(AWS access key\)/);
  assert.doesNotMatch(reason, /c\.dat|d\.dat|could not be scanned/);
});

test('a textconv driver neither hides staged lines nor makes a clean commit fail', () => {
  const { dir, git } = makeRepo();
  // A driver that prints nothing would hide every staged line from a converted diff
  fs.mkdirSync(path.join(dir, '.git', 'info'), { recursive: true });
  fs.writeFileSync(path.join(dir, '.git', 'info', 'attributes'), '* diff=nul\n*.sec diff=crypt\n');
  git('config', 'diff.nul.textconv', 'true');
  fs.writeFileSync(path.join(dir, 'k.js'), `k = "${FAKE_AWS}"\n`);
  git('add', 'k.js');
  assert.match(runHook(dir, `git commit -m 'feat: k'`).permissionDecisionReason, /k\.js:1 \(AWS access key\)/, 'the staged line is scanned, not the driver output');
  git('reset', '-q');
  fs.rmSync(path.join(dir, 'k.js'));
  // A driver that cannot decrypt a clean file would make git diff fail
  git('config', 'diff.crypt.textconv', 'false');
  fs.writeFileSync(path.join(dir, 'a.sec'), 'clean\n');
  git('add', 'a.sec');
  assert.strictEqual(runHook(dir, `git commit -m 'feat: a'`), null);
});

