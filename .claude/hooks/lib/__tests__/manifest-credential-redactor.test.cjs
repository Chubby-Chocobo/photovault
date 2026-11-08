'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const {
  CREDENTIAL_URL_SOURCE, CREDENTIAL_URL, CONFIG_SECRET_LINE, REDACT_BASENAMES,
  redactText, redactLeaves, stringLength, bashNamesRedactTarget, namesConfigFile, shouldInspect,
} = require('../manifest-credential-redactor.cjs');

// Samples are assembled at runtime so no file in the repo holds a credential-shaped literal
const TOKEN = 'ghp_' + 'A'.repeat(36);
const BARE = 'q'.repeat(52);
const url = (userinfo, rest = 'github.com/acme/x.git') => `https://${userinfo}@${rest}`;
const masked = (rest = 'github.com/acme/x.git') => `https://***@${rest}`;

test('masks every credential form and keeps scheme and host', () => {
  const forms = [
    TOKEN, `x-access-token:${TOKEN}`, `user:${'p4' + 'ss'}`, `oauth2:glpat-${'b'.repeat(20)}`, BARE,
    `github_pat_${'C'.repeat(30)}`, `glpat-${'d'.repeat(20)}`, `xoxb-${'1'.repeat(12)}-abc`, `gldt-${'e'.repeat(20)}`,
  ];
  for (const userinfo of forms) {
    assert.deepStrictEqual(redactText(url(userinfo)), { text: masked(), count: 1 }, userinfo.slice(0, 6));
  }
  assert.strictEqual(redactText(`git+${url(TOKEN)}`).text, `git+${masked()}`);
  assert.strictEqual(redactText(url(TOKEN, 'h.io/x').replace('https', 'http')).text, 'http://***@h.io/x');
});

test('counts and masks several URLs in one text, including a password that holds an @', () => {
  const text = `a = "${url(TOKEN)}"\nb = "${url('u:' + 'pw@x')}"\nc = "${url(BARE)}"`;
  const out = redactText(text);
  assert.strictEqual(out.count, 3);
  assert.ok(!out.text.includes(TOKEN) && !out.text.includes(BARE) && !out.text.includes('pw@x'));
  assert.strictEqual(out.text.split('\n').length, 3);
});

test('placeholders, ssh remotes, short usernames and plain URLs are untouched', () => {
  for (const text of [
    'https://${TOKEN}@github.com/a/b', 'https://<user>:<token>@h.io', 'https://{token}@h.io', 'https://user:${PASSWORD}@h.io',
    'git@github.com:acme/x.git', 'ssh://git@github.com/acme/x.git', 'https://user@h.io', 'https://user:@h.io',
    'https://github.com/acme/x.git', 'https://example.com:8080/a@b', 'mail me at a@b.io or visit https://h.io/x',
    'https://registry.npmjs.org/@scope/pkg', 'xox', '',
  ]) {
    assert.deepStrictEqual(redactText(text), { text, count: 0 }, text);
  }
});

test('redaction is idempotent', () => {
  const once = redactText(`${url(TOKEN)} ${url('u:' + 'pw')}`);
  assert.deepStrictEqual(redactText(once.text), { text: once.text, count: 0 });
  const config = '//r.io/:_authToken=abc\npassword = hunter2\n';
  const first = redactText(config, { configLines: true });
  assert.strictEqual(first.count, 2);
  assert.deepStrictEqual(redactText(first.text, { configLines: true }), { text: first.text, count: 0 });
});

test('the exported global regex and the source string agree', () => {
  assert.strictEqual(CREDENTIAL_URL.source, new RegExp(CREDENTIAL_URL_SOURCE).source);
  assert.ok(CREDENTIAL_URL.global);
  // gitleaks uses RE2: no lookaround, no backreferences
  assert.ok(!/\(\?(?:=|!|<=|<!|<[A-Za-z])|\\[1-9]/.test(CREDENTIAL_URL_SOURCE));
});

test('config auth lines are masked only with configLines', () => {
  const text = [
    '//registry.npmjs.org/:_authToken=npm_secretvalue', '_auth=Zm9vYmFy', '//h.io/:_password=cGFzcw==',
    '_authToken=${NPM_TOKEN}', 'machine h.io login me password s3cret', '[pypi]', 'username = me', 'password = hunter2',
  ].join('\n');
  assert.deepStrictEqual(redactText(text), { text, count: 0 });
  const out = redactText(text, { configLines: true });
  assert.strictEqual(out.count, 5);
  assert.strictEqual(out.text, [
    '//registry.npmjs.org/:_authToken=***', '_auth=***', '//h.io/:_password=***', '_authToken=${NPM_TOKEN}',
    'machine h.io login me password ***', '[pypi]', 'username = me', 'password = ***',
  ].join('\n'));
  assert.ok(CONFIG_SECRET_LINE.global);
});

test('redactLeaves keeps keys, array lengths and non-string values', () => {
  const input = {
    type: 'text', file: { filePath: '/x/Cargo.toml', content: `git = "${url(TOKEN)}"`, numLines: 3 },
    lines: [`+ ${url(BARE)}`, 'plain', 7, null, true], nested: [{ deep: [{ s: url(TOKEN) }] }], empty: {},
  };
  const snapshot = JSON.stringify(input);
  const { value, count } = redactLeaves(input);
  assert.strictEqual(count, 3);
  assert.strictEqual(JSON.stringify(input), snapshot, 'input is not modified');
  assert.deepStrictEqual(Object.keys(value), Object.keys(input));
  assert.strictEqual(value.file.numLines, 3);
  assert.deepStrictEqual(value.lines.slice(1), ['plain', 7, null, true]);
  assert.strictEqual(value.lines[0], `+ ${masked()}`);
  assert.strictEqual(value.nested[0].deep[0].s, masked());
  assert.ok(!JSON.stringify(value).includes(TOKEN) && !JSON.stringify(value).includes(BARE));
});

test('redactLeaves keeps an own "__proto__" key as data and passes scalars through', () => {
  const parsed = JSON.parse(`{"__proto__":"${url(TOKEN)}","n":1}`);
  const { value, count } = redactLeaves(parsed);
  assert.strictEqual(count, 1);
  assert.deepStrictEqual(Object.keys(value), ['__proto__', 'n']);
  assert.deepStrictEqual(redactLeaves(42), { value: 42, count: 0 });
  assert.deepStrictEqual(redactLeaves(null), { value: null, count: 0 });
  assert.deepStrictEqual(redactLeaves(url(TOKEN)), { value: masked(), count: 1 });
});

test('configLines reaches nested leaves', () => {
  const { value, count } = redactLeaves({ a: ['password = x1'] }, { configLines: true });
  assert.deepStrictEqual([value, count], [{ a: ['password = ***'] }, 1]);
});

test('stringLength sums every string leaf', () => {
  assert.strictEqual(stringLength({ a: 'abc', b: ['de', { c: 'f' }], d: 12345, e: null }), 6);
});

test('bashNamesRedactTarget accepts manifest reads and git remote subcommands', () => {
  for (const command of [
    'cat services/*/Cargo.toml', 'git -C services/market remote -v', 'cat .git/config', 'cat services/market/.git/config',
    'cat .git/modules/protos/config', 'git config --get remote.origin.url', 'git submodule status', 'git ls-remote origin',
    'cd services/market && git remote get-url origin', 'git show HEAD:services/core/package.json', 'grep -n git Cargo.lock',
    'head -20 pnpm-lock.yaml', 'cat .gitmodules', 'cat ~/.git-credentials', 'cat ~/.npmrc', 'cat "apps/web/package-lock.json"',
    'cat go.mod pom.xml', 'FILE=requirements.txt; cat $FILE',
  ]) {
    assert.strictEqual(bashNamesRedactTarget(command, process.cwd()), true, command);
  }
});

test('bashNamesRedactTarget rejects commands that name nothing redact-worthy', () => {
  for (const command of ['npm test', 'ls -la', 'git status', 'git log --oneline', 'cat README.md', 'echo Cargo', '', undefined, 42]) {
    assert.strictEqual(bashNamesRedactTarget(command, process.cwd()), false, String(command));
  }
  assert.ok(REDACT_BASENAMES.has('Cargo.toml') && REDACT_BASENAMES.has('.pypirc'));
});

test('namesConfigFile looks at paths, globs and command words', () => {
  assert.strictEqual(namesConfigFile({ file_path: '/home/me/.npmrc' }), true);
  assert.strictEqual(namesConfigFile({ pattern: 'x', glob: '**/.netrc' }), true);
  assert.strictEqual(namesConfigFile({ command: 'cat ~/.pypirc' }), true);
  assert.strictEqual(namesConfigFile({ file_path: 'services/market/Cargo.toml' }), false);
  assert.strictEqual(namesConfigFile(undefined), false);
});

test('shouldInspect narrows Bash only', () => {
  assert.strictEqual(shouldInspect('Read', { file_path: 'a' }, '/'), true);
  assert.strictEqual(shouldInspect('Grep', {}, '/'), true);
  assert.strictEqual(shouldInspect('Bash', { command: 'npm test' }, '/'), false);
  assert.strictEqual(shouldInspect('Bash', { command: 'cat Cargo.toml' }, '/'), true);
});

test('no file written for this module holds a credential literal', () => {
  const root = path.resolve(__dirname, '..', '..', '..', '..');
  const files = [
    '.claude/hooks/lib/manifest-credential-redactor.cjs', '.claude/hooks/manifest-credential-redact.cjs',
    '.claude/hooks/lib/__tests__/manifest-credential-redactor.test.cjs', '.claude/hooks/__tests__/manifest-credential-redact.test.cjs',
    '.claude/skills/quality-gates/tests/gitleaks-url-credential-rule.test.cjs',
  ];
  const literal = /gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|glpat-[A-Za-z0-9_-]{20}/;
  for (const file of files) {
    const text = fs.readFileSync(path.join(root, file), 'utf8');
    assert.ok(!literal.test(text), `${file} holds a token literal`);
    assert.ok(!redactText(text).count, `${file} holds a credential URL`);
  }
});
