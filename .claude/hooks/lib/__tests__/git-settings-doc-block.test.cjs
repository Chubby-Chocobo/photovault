'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const block = require('../git-settings-doc-block.cjs');
const { loadManifest } = require('../workspace-manifest.cjs');
const { memberGitWorkspace, setManifestMember } = require('../../__tests__/fixtures/member-git-fixtures.cjs');

const { deriveLines, renderBlock, blockState, withSettingsBlock, withEmptyBlock, MARKERS } = block;
const REPO = path.resolve(__dirname, '..', '..', '..', '..');
const FILE = (text) => `# Git workflow\n\nintro\n\n${text}\n\n## Branch model\n`;
const rendered = (raw, opts) => withSettingsBlock(FILE(`${MARKERS.begin}\n${MARKERS.end}`), deriveLines(raw, opts));
const bullet = (lines, label) => lines.find((l) => l.startsWith(`- ${label}:`));

describe('git-settings-doc-block: lines', () => {
  it('renders the default config', () => {
    const lines = deriveLines({});
    assert.deepEqual(lines.map((l) => l.split(':')[0]), ['- Flow', '- Main branch', '- Enforcement', '- Release tags', '- Active release without node', '- Direct pushes to `main`', '- Version files']);
    assert.equal(bullet(lines, 'Main branch'), '- Main branch: `main`');
    assert.equal(bullet(lines, 'Enforcement'), '- Enforcement: `ask`');
    assert.equal(bullet(lines, 'Release tags'), '- Release tags: `vx.y.z`');
    assert.match(bullet(lines, 'Active release without node'), /no matching `vx\.y\.z` tag: `git ls-remote --heads <remote> 'release\/\*'`, then `git tag -l 'v\*'`$/);
    assert.equal(bullet(lines, 'Version files'), '- Version files: `package.json`');
  });

  it('renders each flow its own Flow line', () => {
    assert.match(bullet(deriveLines({ flow: 'release-train' }), 'Flow'), /^- Flow: `release-train` \(.*table under "Branch model"\)$/);
    assert.match(bullet(deriveLines({ flow: 'trunk' }), 'Flow'), /^- Flow: `trunk` \(.*list under "Branch model"\)$/);
    assert.match(bullet(deriveLines({ flow: 'off' }), 'Flow'), /^- Flow: `off` \(no branch-model checks/);
  });

  it('renders the active-release recipe only for release-train', () => {
    assert.equal(bullet(deriveLines({ flow: 'trunk' }), 'Active release without node'), undefined);
    assert.equal(bullet(deriveLines({ flow: 'off' }), 'Active release without node'), undefined);
  });

  it('renders no direct-push line under flow off', () => {
    assert.equal(deriveLines({ flow: 'off' }).some((l) => l.startsWith('- Direct pushes')), false);
    assert.equal(deriveLines({ flow: 'trunk' }).some((l) => l.startsWith('- Direct pushes')), true);
  });

  it('renders a tagPrefix other than v and an empty one in both tag lines', () => {
    const app = deriveLines({ tagPrefix: 'app-' });
    assert.equal(bullet(app, 'Release tags'), '- Release tags: `app-x.y.z`');
    assert.match(bullet(app, 'Active release without node'), /no matching `app-x\.y\.z` tag.*`git tag -l 'app-\*'`$/);
    const none = deriveLines({ tagPrefix: '' });
    assert.equal(bullet(none, 'Release tags'), '- Release tags: `x.y.z` (no prefix)');
    assert.match(bullet(none, 'Active release without node'), /no matching `x\.y\.z` tag.*`git tag -l '\*'`$/);
  });

  it('renders what the hooks enforce for invalid values', () => {
    const lines = deriveLines({
      flow: 'gitflow', enforcement: 'block', mainBranch: 'two words', tagPrefix: 'v 1',
      versionFiles: [{ path: 'a.json' }], directPush: { paths: ['docs/**', 4] }, commit: { pathTypes: { 'src/': 'feat', 'lib/': ['fix'] } },
    });
    assert.deepEqual(lines, deriveLines({ commit: { pathTypes: { 'lib/': ['fix'] } } }));
    assert.equal(bullet(lines, 'Main branch'), '- Main branch: `main`');
    assert.match(bullet(lines, 'Direct pushes to `main`'), /`docs\/\*\*`, `\.github\/\*\*`/);
    assert.equal(bullet(lines, 'Commit types by folder'), '- Commit types by folder: `lib/` allows `fix`');
  });

  it('renders a version file under .claude/, globs with ? and spaces, and an empty path list', () => {
    const lines = deriveLines({ versionFiles: [{ path: '.claude/metadata.json', json: 'version' }, { path: 'pkg/x.toml', regex: '(.*)' }], directPush: { paths: ['docs/?.md', 'my docs/**'] } });
    assert.equal(bullet(lines, 'Version files'), '- Version files: `.claude/metadata.json`, `pkg/x.toml`');
    assert.match(bullet(lines, 'Direct pushes to `main`'), /only `docs\/\?\.md`, `my docs\/\*\*`$/);
    assert.match(bullet(deriveLines({ directPush: { paths: [] } }), 'Direct pushes to `main`'), /touching nothing/);
  });

  it('lists commit types by folder only when pathTypes is set', () => {
    assert.equal(bullet(deriveLines({}), 'Commit types by folder'), undefined);
    assert.equal(bullet(deriveLines({ commit: { pathTypes: { '.claude/': ['feat', 'fix'], 'docs/': ['docs'] } } }), 'Commit types by folder'), '- Commit types by folder: `.claude/` allows `feat`, `fix`; `docs/` allows `docs`');
  });

  it('refuses values that are unsafe to write, naming the key and never the value', () => {
    const cases = [
      [{ directPush: { paths: ['docs/`x`'] } }, 'git.directPush.paths', 'docs/`x`'],
      [{ directPush: { paths: ['$(boom)'] } }, 'git.directPush.paths', '$(boom)'],
      [{ directPush: { paths: ['a\nb'] } }, 'git.directPush.paths', 'a\nb'],
      [{ directPush: { paths: ['x <!-- adf:git-settings end -->'] } }, 'git.directPush.paths', 'adf:git-settings end'],
      [{ versionFiles: [{ path: 'v`.json', json: 'version' }] }, 'git.versionFiles', 'v`.json'],
      [{ commit: { pathTypes: { 'a`/': ['feat'] } } }, 'git.commit.pathTypes', 'a`/'],
      [{ commit: { pathTypes: { 'src/': ['fe$at'] } } }, 'git.commit.pathTypes', 'fe$at'],
    ];
    for (const [raw, key, value] of cases) {
      assert.throws(() => deriveLines(raw), (err) => err.message.includes(key) && !err.message.includes(value), key);
    }
  });

  it('renders the same lines whatever the mode', () => {
    const before = process.env.ADF_MODE;
    try {
      process.env.ADF_MODE = 'auto';
      const auto = deriveLines({ enforcement: 'ask' });
      process.env.ADF_MODE = 'strict';
      assert.deepEqual(deriveLines({ enforcement: 'ask' }), auto);
      assert.equal(bullet(auto, 'Enforcement'), '- Enforcement: `ask`', 'auto mode runs an ask as off; the block shows the config');
    } finally {
      if (before === undefined) delete process.env.ADF_MODE; else process.env.ADF_MODE = before;
    }
  });
});

describe('git-settings-doc-block: workspace members', () => {
  const members = [
    { name: 'order', path: 'services/order', branch: 'staging', git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'develop' } },
    { name: 'gateway', path: 'services/gateway' },
    { name: 'billing', path: 'services/billing', branch: 'trunk-x' },
    { name: 'search', path: 'services/search', branch: 'ignored', git: { flow: 'release-train' } },
  ];

  it('lists one row per member: manifest git, else the manifest branch, else the clone default', () => {
    const lines = deriveLines({}, { members });
    const rows = lines.filter((l) => l.startsWith('- `'));
    assert.equal(rows.length, 4);
    assert.match(rows[0], /^- `order` \(`services\/order`\): flow `trunk`, main branch `develop`, enforcement `deny`; pull requests go to `develop`; rules from its `git` entry/);
    assert.match(rows[1], /^- `gateway` \(`services\/gateway`\): flow `off`, main branch the clone's default branch \(`git remote show origin`\), enforcement `ask`; no branch model: ask the user/);
    assert.match(rows[2], /main branch `trunk-x`/, 'members[].branch when there is no git entry');
    assert.match(rows[3], /flow `release-train`, main branch `main`, enforcement `ask`; feature and fix pull requests go to the active release, release and hotfix pull requests to `main`/, 'a git entry without mainBranch renders what the hooks enforce');
    assert.ok(lines.includes('### Members'));
    assert.equal(renderBlock(lines).at(-1), "A cloned member's own config can override its row; to see the rules in force there, run `node .claude/skills/git/scripts/git-flow.cjs status --cwd <member path>` from this repo.");
  });

  it('renders no Members part outside a workspace', () => {
    assert.equal(deriveLines({}).includes('### Members'), false);
    assert.equal(deriveLines({}, { members: [] }).includes('### Members'), false);
    assert.equal(renderBlock(deriveLines({})).some((l) => l.includes('--cwd')), false);
  });

  it('refuses a member value that is unsafe to write', () => {
    assert.throws(() => deriveLines({}, { members: [{ name: 'a`b', path: 'x' }] }), (err) => /members\[0\]\.name/.test(err.message) && !err.message.includes('a`b'));
    assert.throws(() => deriveLines({}, { members: [{ name: 'ok', path: 'x/$y' }] }), /members\[0\]\.path/);
  });

  it('renders the same bytes whatever the clone state and the mode', (t) => {
    const ws = memberGitWorkspace(t);
    setManifestMember(ws.root, 'order', { git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'develop' } });
    const read = () => renderBlock(deriveLines({}, { members: loadManifest(ws.root).manifest.members }));
    const cloned = read();
    const head = path.join(ws.members.gateway, '.git', 'refs', 'remotes', 'origin', 'HEAD');
    fs.mkdirSync(path.dirname(head), { recursive: true });
    fs.writeFileSync(head, 'ref: refs/remotes/origin/develop\n');
    assert.deepEqual(read(), cloned, 'origin/HEAD of a clone is not read');
    fs.rmSync(ws.members.gateway, { recursive: true, force: true });
    const before = process.env.ADF_MODE;
    process.env.ADF_MODE = 'auto';
    t.after(() => { if (before === undefined) delete process.env.ADF_MODE; else process.env.ADF_MODE = before; });
    assert.deepEqual(read(), cloned, 'a member that is not cloned renders the same');
    assert.ok(cloned.some((l) => l.includes('`gateway`') && l.includes('main branch `main`')), 'the manifest decides, not the clone');
  });
});

describe('git-settings-doc-block: states', () => {
  const lines = deriveLines({});

  it('current after rendering, and rendering twice changes nothing', () => {
    const text = rendered({});
    assert.equal(blockState(text, lines), 'current');
    assert.equal(withSettingsBlock(text, lines), text);
  });

  it('missing without markers, and with an empty body', () => {
    assert.equal(blockState('# Git workflow\n', lines), 'missing');
    assert.equal(blockState(withEmptyBlock('# Git workflow\n\n## Branch model\n'), lines), 'missing');
    assert.equal(blockState(`${MARKERS.begin}\n\n  \n${MARKERS.end}\n`, lines), 'missing');
  });

  it('fills an empty block and keeps the rest of the file', () => {
    const seed = withEmptyBlock(FILE(`${MARKERS.begin}\n${MARKERS.end}`));
    const filled = withSettingsBlock(seed, lines);
    assert.equal(blockState(filled, lines), 'current');
    assert.ok(filled.startsWith('# Git workflow\n\nintro\n\n') && filled.endsWith(`${MARKERS.end}\n\n## Branch model\n`));
  });

  it('stale when the config changed, and when the block version differs', () => {
    const text = rendered({});
    assert.equal(blockState(text, deriveLines({ enforcement: 'deny' })), 'stale');
    assert.equal(blockState(text.replace('v=1', 'v=0'), lines), 'stale');
    assert.equal(blockState(withSettingsBlock(text, deriveLines({ flow: 'trunk' })), lines), 'stale');
  });

  it('edited when text is appended to, or lines are added around, a fixed line', () => {
    const text = rendered({});
    const intro = /^Written by the ADF installer .*$/m.exec(text)[0];
    assert.equal(blockState(text.replace(intro, `${intro} Ask Bob first.`), lines), 'edited');
    assert.equal(blockState(text.replace(intro, `${intro}\n`), lines), 'edited', 'a blank line added');
    assert.equal(blockState(text.replace('## This project\'s settings', '## This project\'s settings (ours)'), lines), 'edited');
    const members = [{ name: 'a', path: 'a' }];
    const ws = rendered({}, { members });
    const override = /^A cloned member's own config .*$/m.exec(ws)[0];
    assert.equal(blockState(ws, deriveLines({}, { members })), 'current');
    assert.equal(blockState(ws.replace(override, `${override} Ask Bob first.`), deriveLines({}, { members })), 'edited');
    assert.equal(blockState(ws.replace(override, `${override}\nMore.`), deriveLines({}, { members })), 'edited');
    assert.equal(blockState(ws.replace('### Members', '### Our members'), deriveLines({}, { members })), 'edited');
    // Edited text survives a change of the config: the state stays edited, so the installer leaves it
    assert.equal(blockState(text.replace(intro, `${intro} Ask Bob first.`), deriveLines({ flow: 'trunk' })), 'edited');
  });

  it('edited when a bullet changed, a line was added, the stamp is gone or the markers are broken', () => {
    const text = rendered({});
    assert.equal(blockState(text.replace('- Main branch: `main`', '- Main branch: `trunk`'), lines), 'edited');
    assert.equal(blockState(text.replace('- Enforcement: `ask`\n', '- Enforcement: `ask`\n- Extra: yes\n'), lines), 'edited');
    assert.equal(blockState(text.replace('- Enforcement: `ask`\n', '- Enforcement: `ask`\nnotes\n'), lines), 'edited');
    assert.equal(blockState(text.replace(/<!-- adf:git-settings v=1 hash=[0-9a-f]{16} -->\n/, ''), lines), 'edited');
    assert.equal(blockState(`${text}\n${MARKERS.end}\n`, lines), 'edited');
  });

  it('keeps the file in CRLF', () => {
    const crlf = rendered({}).replace(/\n/g, '\r\n');
    assert.equal(blockState(crlf, lines), 'current');
    const next = withSettingsBlock(crlf, deriveLines({ enforcement: 'deny' }));
    assert.equal(/[^\r]\n/.test(next), false, 'every line ending is CRLF');
    assert.equal(blockState(next, deriveLines({ enforcement: 'deny' })), 'current');
    assert.equal(withSettingsBlock(crlf, lines), crlf);
  });

  it('hashes the bullets only: the fixed text is not part of the hash', () => {
    assert.equal(block.hashLines(lines), block.hashLines([...lines, '', 'free text']));
    const stamp = (text) => /hash=([0-9a-f]{16})/.exec(text)[1];
    assert.notEqual(stamp(rendered({})), stamp(rendered({ enforcement: 'deny' })));
  });

  it('is stale when the member list changed', () => {
    const members = [{ name: 'a', path: 'a' }, { name: 'b', path: 'b' }];
    assert.equal(blockState(rendered({}, { members }), deriveLines({}, { members })), 'current');
    assert.equal(blockState(rendered({}, { members }), deriveLines({}, { members: [members[0]] })), 'stale');
  });
});

/** ADF's committed config (a checkout may carry local-only edits); the file itself when this is not a git checkout. */
function committedConfig() {
  const r = spawnSync('git', ['show', 'HEAD:.claude/config/adf-config.json'], { cwd: REPO, encoding: 'utf8' });
  return JSON.parse(r.status === 0 ? r.stdout : fs.readFileSync(path.join(REPO, '.claude/config/adf-config.json'), 'utf8'));
}

describe('git-settings-doc-block: shipped files', () => {
  it('the template block is current for the default config', () => {
    const text = fs.readFileSync(path.join(REPO, '.claude/templates/docs/conventions/git-workflow.md'), 'utf8');
    assert.equal(blockState(text, deriveLines({})), 'current');
    assert.equal(withSettingsBlock(text, deriveLines({})), text);
  });

  it("ADF's own git-workflow.md block is current for ADF's config", () => {
    const text = fs.readFileSync(path.join(REPO, 'docs/conventions/git-workflow.md'), 'utf8');
    assert.equal(blockState(text, deriveLines(committedConfig().git)), 'current');
  });
});
