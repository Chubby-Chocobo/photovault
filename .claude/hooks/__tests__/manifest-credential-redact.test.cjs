#!/usr/bin/env node
/**
 * Tests for manifest-credential-redact.cjs (PostToolUse). The tool_response shapes are the ones
 * Claude Code 2.1.312 sends (plans/.../reports/platform-checks-report.md).
 * Run: node --test .claude/hooks/__tests__/manifest-credential-redact.test.cjs
 */

'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { makeTcxWorkspace } = require('./fixtures/workspace-fixtures.cjs');

const HOOK = path.resolve(__dirname, '..', 'manifest-credential-redact.cjs');
// Spawned hooks log to a private dir, so this file's notes never mix with the repo's shared hook log
const LOG_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'redact-hook-log-'));
process.on('exit', () => fs.rmSync(LOG_DIR, { recursive: true, force: true }));
const LOG_FILE = path.join(LOG_DIR, 'hook-log.jsonl');
const HOOK_NAME = 'manifest-credential-redact';

function tempDir(t, prefix) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

/** A project (has .claude/) plus a Claude config dir; the hook runs with both. */
function setup(t, { config } = {}) {
  const project = tempDir(t, 'redact-project-');
  fs.mkdirSync(path.join(project, '.claude', 'config'), { recursive: true });
  if (config) fs.writeFileSync(path.join(project, '.claude', 'config', 'adf-config.json'), JSON.stringify(config));
  const configDir = tempDir(t, 'redact-claude-');
  fs.mkdirSync(path.join(configDir, 'projects', 'p', 's', 'tool-results'), { recursive: true });
  const run = (payload) => {
    const input = typeof payload === 'string' ? payload : JSON.stringify({ hook_event_name: 'PostToolUse', cwd: project, ...payload });
    return spawnSync('node', [HOOK], {
      input, encoding: 'utf8', cwd: project,
      env: { ...process.env, CLAUDE_PROJECT_DIR: project, CLAUDE_CONFIG_DIR: configDir, ADF_HOOK_LOG_DIR: LOG_DIR },
    });
  };
  return { project, configDir, run, persistedDir: path.join(configDir, 'projects', 'p', 's', 'tool-results') };
}

const parse = (r) => JSON.parse(r.stdout).hookSpecificOutput;

/** Log entries of this hook, so a test can tell which branch ran without reading the hook's internals. */
const hookLog = () => {
  try {
    return fs.readFileSync(LOG_FILE, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line)).filter((e) => e.hook === HOOK_NAME);
  } catch { return []; }
};

function assertSilent(r, label = '') {
  assert.strictEqual(r.status, 0, `${label} ${r.stderr}`);
  assert.strictEqual(r.stdout, '', label);
}

describe('manifest-credential-redact hook', () => {
  const read = (file, content) => ({
    tool_name: 'Read', tool_input: { file_path: file },
    tool_response: { type: 'text', file: { filePath: file, content, numLines: content.split('\n').length, startLine: 1, totalLines: content.split('\n').length } },
  });

  it('redacts a Read of a member manifest and keeps the response shape', (t) => {
    const { members, token } = makeTcxWorkspace(t, { credentialUrl: true });
    const { run } = setup(t);
    const file = path.join(members.market, 'Cargo.toml');
    const payload = read(file, fs.readFileSync(file, 'utf8'));
    const r = run(payload);
    assert.strictEqual(r.status, 0, r.stderr);
    const out = parse(r);
    assert.strictEqual(out.hookEventName, 'PostToolUse');
    assert.match(out.additionalContext, /^1 credential\(s\) were redacted\. Replace them with a deploy key or a CI credential helper; do not ask the user to paste them\.$/);
    assert.deepStrictEqual(Object.keys(out.updatedToolOutput), Object.keys(payload.tool_response));
    assert.deepStrictEqual(Object.keys(out.updatedToolOutput.file), Object.keys(payload.tool_response.file));
    assert.strictEqual(out.updatedToolOutput.file.numLines, payload.tool_response.file.numLines);
    assert.match(out.updatedToolOutput.file.content, /git = "https:\/\/\*\*\*@github\.com\/acme\/vdax-libs"/);
    assert.ok(!r.stdout.includes(token) && !r.stderr.includes(token));
  });

  it('redacts by content, so a persisted tool-results copy is covered too', (t) => {
    const token = `${'ghp_'}${'B'.repeat(36)}`;
    const { run } = setup(t);
    const file = '/home/u/.claude/projects/p/s/tool-results/x.txt';
    const r = run(read(file, `remote = https://${token}@github.com/acme/x.git\n`));
    assert.strictEqual(parse(r).updatedToolOutput.file.content, 'remote = https://***@github.com/acme/x.git\n');
    assert.ok(!r.stdout.includes(token));
  });

  it('redacts a Grep content result', (t) => {
    const { members, token } = makeTcxWorkspace(t, { credentialUrl: true });
    const { run } = setup(t);
    const content = `${members.market}/Cargo.toml:6:git = "https://${token}@github.com/acme/vdax-libs"`;
    const payload = {
      tool_name: 'Grep', tool_input: { pattern: 'vdax', output_mode: 'content' },
      tool_response: { mode: 'content', numFiles: 1, filenames: [`${members.market}/Cargo.toml`], content, numLines: 1, totalLines: 1 },
    };
    const r = run(payload);
    const out = parse(r).updatedToolOutput;
    assert.deepStrictEqual(Object.keys(out), Object.keys(payload.tool_response));
    assert.strictEqual(out.content, `${members.market}/Cargo.toml:6:git = "https://***@github.com/acme/vdax-libs"`);
    assert.deepStrictEqual(out.filenames, payload.tool_response.filenames);
    assert.ok(!r.stdout.includes(token));
  });

  for (const tool of ['Edit', 'MultiEdit']) {
    it(`redacts an ${tool} result (originalFile and structuredPatch lines)`, (t) => {
      const token = `${'ghp_'}${'C'.repeat(36)}`;
      const { run } = setup(t);
      const line = `git = "https://${token}@github.com/acme/vdax-libs"`;
      const payload = {
        tool_name: tool, tool_input: { file_path: '/w/services/market/Cargo.toml', old_string: 'v1', new_string: 'v2' },
        tool_response: {
          filePath: '/w/services/market/Cargo.toml', oldString: 'v1', newString: 'v2', originalFile: `[package]\n${line}\ntag = "v1"\n`,
          structuredPatch: [{ oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [' [package]', ` ${line}`, '-tag = "v1"', '+tag = "v2"'] }],
          userModified: false, replaceAll: false,
        },
      };
      const r = run(payload);
      const out = parse(r);
      assert.deepStrictEqual(Object.keys(out.updatedToolOutput), Object.keys(payload.tool_response));
      assert.ok(!JSON.stringify(out.updatedToolOutput).includes(token));
      assert.strictEqual(out.updatedToolOutput.structuredPatch[0].lines[1], ' git = "https://***@github.com/acme/vdax-libs"');
      assert.strictEqual(out.updatedToolOutput.structuredPatch[0].lines.length, 4);
      assert.strictEqual(out.updatedToolOutput.userModified, false);
      assert.match(out.additionalContext, /^2 credential\(s\)/);
    });
  }

  const bash = (command, stdout, extra = {}) => ({
    tool_name: 'Bash', tool_input: { command },
    tool_response: { stdout, stderr: '', interrupted: false, isImage: false, noOutputExpected: false, ...extra },
  });

  it('redacts Bash output of a command that names a manifest or git remotes', (t) => {
    const { members, token } = makeTcxWorkspace(t, { credentialUrl: true });
    const { run } = setup(t);
    const cargo = fs.readFileSync(path.join(members.market, 'Cargo.toml'), 'utf8');
    const gitConfig = fs.readFileSync(path.join(members.market, '.git', 'config'), 'utf8');
    for (const [command, stdout] of [['cat services/market/Cargo.toml', cargo], ['cat services/market/.git/config', gitConfig],
      ['git -C services/market remote -v', `origin\thttps://${token}@github.com/acme/tcx-market.git (fetch)\n`]]) {
      const r = run(bash(command, stdout));
      const out = parse(r).updatedToolOutput;
      assert.deepStrictEqual(Object.keys(out), ['stdout', 'stderr', 'interrupted', 'isImage', 'noOutputExpected'], command);
      assert.match(out.stdout, /https:\/\/\*\*\*@github\.com\/acme\//, command);
      assert.ok(!r.stdout.includes(token), command);
    }
  });

  it('rewrites a persisted Bash output file in place and redacts the inline preview', (t) => {
    const token = `${'ghp_'}${'D'.repeat(36)}`;
    const { run, persistedDir } = setup(t);
    const file = path.join(persistedDir, 'b1.txt');
    const original = `${'x'.repeat(40)}\nurl = https://${token}@github.com/acme/x.git\ntail\n`;
    fs.writeFileSync(file, original);
    const r = run(bash('cat services/market/Cargo.toml', original.slice(0, original.indexOf('tail')), { persistedOutputPath: file, persistedOutputSize: original.length }));
    const out = parse(r);
    assert.strictEqual(out.updatedToolOutput.persistedOutputPath, file);
    assert.strictEqual(out.updatedToolOutput.persistedOutputSize, original.length);
    assert.ok(!out.updatedToolOutput.stdout.includes(token));
    assert.strictEqual(fs.readFileSync(file, 'utf8'), `${'x'.repeat(40)}\nurl = https://***@github.com/acme/x.git\ntail\n`);
    assert.match(out.additionalContext, /^2 credential\(s\)/);
    assert.ok(!r.stdout.includes(token));
  });

  it('counts a credential found only in the persisted file and returns no updated output', (t) => {
    const token = `${'ghp_'}${'E'.repeat(36)}`;
    const { run, persistedDir } = setup(t);
    const file = path.join(persistedDir, 'b2.txt');
    fs.writeFileSync(file, `late line https://${token}@github.com/acme/x.git\n`);
    const out = parse(run(bash('cat Cargo.lock', 'first 30000 characters, clean', { persistedOutputPath: file })));
    assert.strictEqual(out.updatedToolOutput, undefined);
    assert.match(out.additionalContext, /^1 credential\(s\)/);
    assert.ok(!fs.readFileSync(file, 'utf8').includes(token));
  });

  it('leaves files outside the Claude projects tree alone and survives a missing persisted file', (t) => {
    const token = `${'ghp_'}${'F'.repeat(36)}`;
    const { run, persistedDir, project } = setup(t);
    const outside = path.join(project, 'outside.txt');
    fs.writeFileSync(outside, `https://${token}@github.com/acme/x.git\n`);
    const inline = `https://${token}@github.com/acme/y.git`;
    for (const persistedOutputPath of [outside, path.join(persistedDir, 'missing.txt'), 'relative/x.txt', 42]) {
      const r = run(bash('cat Cargo.toml', inline, { persistedOutputPath }));
      assert.strictEqual(r.status, 0, r.stderr);
      assert.strictEqual(parse(r).updatedToolOutput.stdout, 'https://***@github.com/acme/y.git', String(persistedOutputPath));
    }
    assert.ok(fs.readFileSync(outside, 'utf8').includes(token), 'a path outside the projects tree is never rewritten');
  });

  it('does not follow a symlink out of the projects tree', (t) => {
    const token = `${'ghp_'}${'G'.repeat(36)}`;
    const { run, persistedDir, project } = setup(t);
    const target = path.join(project, 'target.txt');
    fs.writeFileSync(target, `https://${token}@github.com/acme/x.git\n`);
    const link = path.join(persistedDir, 'link.txt');
    fs.symlinkSync(target, link);
    parse(run(bash('cat Cargo.toml', `https://${token}@github.com/acme/y.git`, { persistedOutputPath: link })));
    assert.ok(fs.readFileSync(target, 'utf8').includes(token));
  });

  it('keeps non-UTF-8 bytes in the persisted file and touches only Bash tool-results files', (t) => {
    const token = `${'ghp_'}${'J'.repeat(36)}`;
    const { run, persistedDir, configDir } = setup(t);
    const file = path.join(persistedDir, 'b3.txt');
    fs.writeFileSync(file, Buffer.concat([Buffer.from([0xff, 0xfe, 0x80]), Buffer.from(`https://${token}@github.com/acme/x.git\n`)]));
    parse(run(bash('cat Cargo.toml', `https://${token}@github.com/acme/y.git`, { persistedOutputPath: file })));
    const after = fs.readFileSync(file);
    assert.deepStrictEqual([...after.subarray(0, 3)], [0xff, 0xfe, 0x80]);
    assert.ok(!after.toString('latin1').includes(token));
    assert.ok(after.toString('latin1').includes('https://***@github.com/acme/x.git'));

    const memory = path.join(configDir, 'projects', 'p', 'memory.md');
    fs.writeFileSync(memory, `https://${token}@github.com/acme/x.git\n`);
    parse(run(bash('cat Cargo.toml', `https://${token}@github.com/acme/y.git`, { persistedOutputPath: memory })));
    assert.ok(fs.readFileSync(memory, 'utf8').includes(token), 'a file outside tool-results is never rewritten');

    const viaRead = path.join(persistedDir, 'b4.txt');
    fs.writeFileSync(viaRead, `https://${token}@github.com/acme/x.git\n`);
    const r = run({ tool_name: 'Read', tool_input: { file_path: '/w/Cargo.toml' }, tool_response: { type: 'text', file: { filePath: '/w/Cargo.toml', content: `https://${token}@github.com/acme/y.git`, numLines: 1, startLine: 1, totalLines: 1 }, persistedOutputPath: viaRead } });
    assert.strictEqual(r.status, 0, r.stderr);
    assert.ok(fs.readFileSync(viaRead, 'utf8').includes(token), 'only Bash outputs are persisted, so other tools never rewrite');
  });

  it('ignores Bash output of commands that name nothing redact-worthy', (t) => {
    const token = `${'ghp_'}${'H'.repeat(36)}`;
    const { run } = setup(t);
    assertSilent(run(bash('npm test', `fixture url https://${token}@github.com/acme/x.git`)), 'npm test');
  });

  it('prints nothing for clean output', (t) => {
    const { run } = setup(t);
    assertSilent(run(read('/w/Cargo.toml', '[package]\nname = "x"\ngit = "https://github.com/acme/y"\nssh = "git@github.com:a/b.git"\n')));
    assertSilent(run(bash('cat Cargo.toml', 'mail a@b.io https://x.io')));
  });

  it('masks npmrc auth lines that hold no URL, but only for a call that names the file', (t) => {
    const { run } = setup(t);
    const text = '//registry.npmjs.org/:_authToken=npm_realvalue\nregistry=https://registry.npmjs.org/\n';
    const named = parse(run(read('/home/u/.npmrc', text)));
    assert.strictEqual(named.updatedToolOutput.file.content, '//registry.npmjs.org/:_authToken=***\nregistry=https://registry.npmjs.org/\n');
    assertSilent(run(read('/home/u/notes.txt', text)));
  });

  it('never writes the original value to stdout, stderr or the hook log', (t) => {
    const token = `${'ghp_'}${'J'.repeat(36)}`;
    const { run } = setup(t);
    const before = hookLog().length;
    const results = [
      run(read('/w/Cargo.toml', `https://${token}@github.com/a/b`)),
      run(`{"tool_name":"Read", "tool_response": https://${token}@github.com broken`),
      run(bash('npm test', `https://${token}@github.com/a/b`)),
    ];
    for (const r of results) assert.ok(!r.stdout.includes(token) && !r.stderr.includes(token));
    const added = hookLog().slice(before);
    assert.ok(added.length >= 3);
    assert.ok(!JSON.stringify(added).includes(token));
    assert.ok(added.some((e) => e.note === 'redacted:1'));
  });

  it('fails open on invalid JSON, a crash-shaped payload and tools it does not handle', (t) => {
    const { run } = setup(t);
    const cred = `https://${'x:y'}@c.io`; // built, so the source holds no credential URL
    assertSilent(run(`not json at all, but ${cred}`), 'invalid json');
    assertSilent(run(''), 'empty input');
    assertSilent(run(`{"tool_name": "Read", "tool_input": null, "tool_response": null, "x": "${cred}"}`), 'null response');
    assertSilent(run({ tool_name: 'Write', tool_input: {}, tool_response: { content: cred } }), 'unhandled tool');
    assertSilent(run(`[1, "${cred}"]`), 'array payload');
  });

  it('exits before parsing when the payload has no URL or no @, and logs nothing', (t) => {
    const { run } = setup(t);
    const before = hookLog().length;
    assertSilent(run(read('/w/Cargo.toml', 'name = "x"\nhttps://example.com/path\n')), 'no @');
    assertSilent(run(read('/w/Cargo.toml', 'mail me@example.com')), 'no ://');
    assert.deepStrictEqual(hookLog().slice(before), []);
  });

  it('skips a response above 1 MB', (t) => {
    const token = `${'ghp_'}${'K'.repeat(36)}`;
    const { run } = setup(t);
    const before = hookLog().length;
    const content = `https://${token}@github.com/a/b\n${'y'.repeat(1024 * 1024 + 10)}`;
    assertSilent(run(read('/w/Cargo.lock', content)));
    assert.ok(hookLog().slice(before).some((e) => e.note === 'too-large'));
  });

  describe('toggle hooks.manifest-credential-redact', () => {
    const token = `${'ghp_'}${'L'.repeat(36)}`;
    const payload = read('/w/Cargo.toml', `https://${token}@github.com/a/b`);

    it('false turns the hook into a no-op', (t) => {
      const { run } = setup(t, { config: { hooks: { 'manifest-credential-redact': false } } });
      assertSilent(run(payload));
    });

    it('is on when the key is absent, whether or not a config file exists', (t) => {
      for (const config of [undefined, {}, { hooks: { 'scout-block': false } }]) {
        const { run } = setup(t, { config });
        assert.match(parse(run(payload)).updatedToolOutput.file.content, /https:\/\/\*\*\*@github\.com/);
      }
    });

    it('true keeps it on', (t) => {
      const { run } = setup(t, { config: { hooks: { 'manifest-credential-redact': true } } });
      assert.ok(parse(run(payload)).updatedToolOutput);
    });
  });
});
