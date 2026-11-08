#!/usr/bin/env node
/**
 * The mega workspace through scaffold, sync, repos, per-member git rules and credential redaction.
 * The tests run in order on one fixture, as the walkthrough does.
 * Run: node --test .claude/skills/workspace/scripts/tests/mega-workspace-sync-git.test.cjs
 */

'use strict';

const { describe, it, before } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { resolveMemberGitSource } = require('../../../../hooks/lib/workspace-manifest.cjs');
const { buildWorkspaceContext } = require('../../../../hooks/lib/workspace-session-context.cjs');
const { megaWorkspace, isolateTmpdir, commitMemberFiles, cliJson, editManifest } = require('./mega-workspace-test-helpers.cjs');

const REDACT_HOOK = path.join(__dirname, '..', '..', '..', '..', 'hooks', 'manifest-credential-redact.cjs');
const CONFIG = { paths: { docs: 'docs', plans: 'plans' } };
let ws;
before((t) => {
  isolateTmpdir(t);
  ws = megaWorkspace(t);
});

const byKind = (files, kind, status) => files.filter((f) => f.kind === kind && f.status === status);
const readMember = (name, rel) => fs.readFileSync(path.join(ws.members[name], rel), 'utf8');

describe('mega workspace: scaffold and sync', () => {
  it('scaffold writes an AGENTS.md starter and a CLAUDE.md import stub in every cloned component but identity, and a service doc for every component', () => {
    const { code, json } = cliJson(ws.root, ['scaffold']);
    assert.strictEqual(code, 0, JSON.stringify(json).slice(0, 500));
    assert.strictEqual(byKind(json.files, 'agents-md', 'written').length, 60, '59 starters and the pointer stub for identity');
    assert.strictEqual(byKind(json.files, 'claude-md', 'written').length, 59);
    assert.deepStrictEqual(byKind(json.files, 'claude-md', 'kept').map((f) => f.component), ['identity']);
    assert.ok(!json.files.some((f) => f.component === 'tax' && f.kind !== 'service-doc' && f.status === 'written'), 'nothing is written into a member that is not cloned');
    assert.strictEqual(byKind(json.files, 'service-doc', 'written').length, 69);
    assert.ok(readMember('wallet', 'AGENTS.md').includes('role: unknown'));
    assert.ok(readMember('wallet', 'CLAUDE.md').startsWith('@AGENTS.md'));
    assert.match(readMember('identity', 'AGENTS.md'), /Component notes are in `CLAUDE.md`/);
  });

  it('sync right after scaffold finds every AGENTS.md block current and skips nobody for uncommitted changes: it writes the markers, and the block into identity CLAUDE.md', () => {
    const { code, json } = cliJson(ws.root, ['sync', '--yes']);
    assert.strictEqual(code, 0);
    assert.strictEqual(json.counts.written, 60);
    assert.ok(!json.rows.some((r) => r.reason === 'uncommitted changes'));
    assert.deepStrictEqual(json.rows.find((r) => r.member === 'order').files, ['services/order/.adf-workspace.json']);
    assert.deepStrictEqual(json.rows.find((r) => r.member === 'identity').files, ['services/identity/CLAUDE.md', 'services/identity/.adf-workspace.json']);
    assert.strictEqual(json.rows.find((r) => r.member === 'tax').reason, 'not cloned');
    assert.strictEqual(json.rows.find((r) => r.member === 'nova-proto').reason, 'no component in the system map');
  });

  it('after the files are committed by name, a second sync writes nothing, --check passes, and hand-written text survives', () => {
    assert.strictEqual(commitMemberFiles(ws), 60);
    const { json } = cliJson(ws.root, ['sync', '--yes']);
    assert.strictEqual(json.counts.written, 0, JSON.stringify(json.counts));
    assert.strictEqual(json.counts.unchanged, 60);
    assert.strictEqual(cliJson(ws.root, ['sync', '--check']).code, 0);
    const identity = readMember('identity', 'CLAUDE.md');
    assert.ok(identity.includes('Hand-written notes for the identity service.'));
    assert.ok(identity.includes('<!-- adf:system-context begin'), identity);
    assert.ok(fs.existsSync(path.join(ws.members['matching-engine'], '.adf-workspace.json')));
    const gatewayBlock = readMember('gateway', 'AGENTS.md');
    assert.ok(gatewayBlock.includes('order') && gatewayBlock.includes('nova-proto'), 'the block names what gateway calls and consumes');
    assert.ok(!readMember('gateway', 'CLAUDE.md').includes('adf:system-context'), 'the importing CLAUDE.md holds no second block');
  });

  it('a product rename makes every block stale: the session checks all 60, names 8 and counts the rest, sync --check fails until synced again', () => {
    editManifest(ws.root, (m) => { m.product = 'nova-exchange'; });
    const lines = buildWorkspaceContext({ baseDir: ws.root, config: CONFIG, shapeType: 'workspace', resolvedPlan: { path: null, resolvedBy: null }, cwd: ws.root }).lines;
    const stale = lines.find((l) => l.startsWith('System context:'));
    assert.match(stale, /^System context: 60 member blocks stale \(([a-z0-9-]+, ){7}[a-z0-9-]+ \+52 more\); run workspace\.cjs sync$/, stale);
    assert.strictEqual(cliJson(ws.root, ['sync', '--check']).code, 1);
    assert.strictEqual(cliJson(ws.root, ['sync', '--yes']).json.counts.written, 60, 'every block carries the product name');
  });
});

describe('mega workspace: repos, git rules and secrets', () => {
  it('repos --changed lists the 60 members sync touched, flags the one with its own ADF, and names the nine not cloned', () => {
    const { code, json } = cliJson(ws.root, ['repos', '--changed']);
    assert.strictEqual(code, 0);
    assert.strictEqual(json.repos.length, 61, 'sixty members plus the workspace repo itself');
    assert.ok(json.repos.some((r) => r.name === 'workspace'));
    const identity = json.repos.find((r) => r.name === 'identity');
    assert.strictEqual(identity.hasOwnAdf, true);
    assert.strictEqual(identity.prBase, 'master', 'from its own adf-config.json');
    assert.strictEqual(json.repos.find((r) => r.name === 'order').prBase, 'main');
    assert.strictEqual(json.notCloned.length, 9);
    assert.ok(json.repos.every((r) => r.unstaged + r.untracked + r.staged > 0));
  });

  it('inside a member the git rules come from its own config, else the manifest; launch directory does not matter', () => {
    const identity = resolveMemberGitSource(path.join(ws.members.identity, 'plans'));
    assert.deepStrictEqual([identity.source, identity.git], ['member config', { flow: 'trunk', enforcement: 'deny', mainBranch: 'master' }]);
    const order = resolveMemberGitSource(ws.members.order);
    assert.deepStrictEqual([order.source, order.git, order.member], ['manifest', { flow: 'off', enforcement: 'ask', mainBranch: 'main' }, 'order']);
    assert.strictEqual(resolveMemberGitSource(ws.root), null, 'the workspace root is not a member');
  });

  it('the redaction hook masks the token in a Read of market/Cargo.toml and in Bash output', () => {
    const run = (tool, toolInput, toolResponse) => spawnSync(process.execPath, [REDACT_HOOK], {
      cwd: ws.root, encoding: 'utf8', env: { ...process.env, CLAUDE_PROJECT_DIR: ws.root },
      input: JSON.stringify({ hook_event_name: 'PostToolUse', tool_name: tool, tool_input: toolInput, tool_response: toolResponse }),
    });
    const cargo = readMember('market', 'Cargo.toml');
    assert.ok(cargo.includes(ws.token), 'the fixture really holds the token on disk');
    const read = run('Read', { file_path: path.join(ws.members.market, 'Cargo.toml') }, { file: { content: cargo } });
    assert.strictEqual(read.status, 0, read.stderr);
    const updated = JSON.parse(read.stdout).hookSpecificOutput.updatedToolOutput.file.content;
    assert.ok(!updated.includes(ws.token) && updated.includes('https://***@github.com/acme/nova-proto'), updated);
    const remote = spawnSync('git', ['remote', 'get-url', 'origin'], { cwd: ws.members.market, encoding: 'utf8' }).stdout;
    const bash = run('Bash', { command: 'git remote get-url origin' }, { stdout: remote, stderr: '' });
    assert.ok(!bash.stdout.includes(ws.token) && bash.stdout.includes('***@github.com/acme/nova-market.git'), bash.stdout);
  });
});
