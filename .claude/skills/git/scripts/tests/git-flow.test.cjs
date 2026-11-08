'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { sh, flow, failingGh, makeRepo, write, read, commit, squashInto, mergeInto } = require('./git-flow-test-repo.cjs');
const { newestVersion, compare } = require('../lib/semver.cjs');
const { writeVersionToText, readVersionFromText, effectiveVersionFiles } = require('../lib/version-files.cjs');
const { headFromSubject } = require('../lib/release-tagger.cjs');
const { checkPushUpdates } = require('../lib/native-pre-push-check.cjs');
const { getGitConfig } = require('../../../../hooks/lib/git-flow-config.cjs');

const version = (work) => JSON.parse(read(work, 'package.json')).version;

describe('git-flow building blocks', () => {
  it('sorts tags by semver and ignores pre-releases and foreign tags', () => {
    assert.equal(newestVersion(['v1.9.0', 'v1.10.0', 'v2.0.0-rc.1', 'other', 'v1.2'], 'v'), '1.10.0');
    assert.equal(newestVersion(['1.0.0', 'v3.0.0'], ''), '1.0.0');
    assert.ok(compare('1.10.0', '1.9.0') > 0);
  });

  it('reads and writes JSON and regex version files, keeping the lockfile root in step', () => {
    const lock = JSON.stringify({ name: 'x', version: '1.0.0', packages: { '': { version: '1.0.0' } } }, null, 2);
    const out = JSON.parse(writeVersionToText({ path: 'package-lock.json', json: 'version' }, lock, '1.1.0'));
    assert.equal(out.packages[''].version, '1.1.0');
    const toml = '[project]\nname = "x"\nversion = "0.3.0"\n';
    const entry = { path: 'pyproject.toml', regex: '^version = "([^"]+)"' };
    assert.equal(readVersionFromText(entry, writeVersionToText(entry, toml, '0.4.0')), '0.4.0');
    assert.equal(readVersionFromText({ path: 'm.json', json: 'meta.version' }, '{"meta":{"version":"2.0.0"}}'), '2.0.0');
  });

  it('names the manifest to configure when a project has no package.json', (t) => {
    const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'adf-vf-'));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    fs.writeFileSync(path.join(dir, 'pyproject.toml'), 'version = "1.0.0"\n');
    const config = { versionFiles: [{ path: 'package.json', json: 'version' }], versionFilesConfigured: false };
    assert.throws(() => effectiveVersionFiles(config, dir), /"versionFiles": \[\{"path":"pyproject\.toml"/);
  });

  it('reads the head branch from merge subjects', () => {
    assert.equal(headFromSubject('Merge pull request #12 from acme/release/1.2.0'), 'release/1.2.0');
    assert.equal(headFromSubject("Merge branch 'hotfix/crash' into main"), 'hotfix/crash');
    assert.equal(headFromSubject('feat: add x (#4)'), null);
  });
});

describe('git-flow release-train', () => {
  it('cuts a release, guards PRs, tags a hotfix, back-merges and tags the release', (t) => {
    const { work } = makeRepo(t);

    let r = flow(work, 'cut-release', '1.1.0');
    assert.equal(r.code, 0, r.err);
    sh(work, 'git', 'fetch', '--quiet');
    assert.equal(JSON.parse(sh(work, 'git', 'show', 'origin/release/1.1.0:package.json')).version, '1.1.0');
    assert.equal(sh(work, 'git', 'log', '-1', '--format=%s', 'origin/release/1.1.0'), 'chore(release): 1.1.0');
    assert.match(flow(work, 'cut-release', '1.1.0').out, /already existed, version already set/, 'a second run changes nothing');
    assert.match(flow(work, 'cut-release', '1.2.0').err, /release\/1\.1\.0 is still open/);
    assert.match(flow(work, 'cut-release', '1.0.0').err, /v1\.0\.0 already exists/);
    assert.equal(flow(work, 'active-release').out, 'release/1.1.0');

    // A feature goes into the release, never into main
    sh(work, 'git', 'checkout', '--quiet', '-b', 'feat/search', 'origin/release/1.1.0');
    write(work, 'src/search.js', 'module.exports = 2;\n');
    commit(work, 'feat(search): add search');
    sh(work, 'git', 'push', '--quiet', '-u', 'origin', 'feat/search');
    r = flow(work, 'status', '--json');
    assert.deepEqual([r.json.target, r.json.strategy], ['release/1.1.0', 'squash']);
    assert.equal(flow(work, 'check-pr', '--base', 'release/1.1.0', '--head', 'feat/search').code, 0);
    r = flow(work, 'check-pr', '--base', 'main', '--head', 'feat/search');
    assert.equal(r.code, 1);
    assert.match(r.err, /open this PR into release\/1\.1\.0/);
    sh(work, 'git', 'checkout', '--quiet', '-b', 'release/1.1.0', 'origin/release/1.1.0');
    squashInto(work, 'release/1.1.0', 'feat/search', 'feat(search): add search (#2)');

    // A hotfix while the release is open
    sh(work, 'git', 'checkout', '--quiet', '-b', 'hotfix/crash', 'origin/main');
    assert.equal(flow(work, 'bump-version', '--branch').code, 0);
    assert.equal(version(work), '1.0.1');
    write(work, 'src/app.js', 'module.exports = 3;\n');
    write(work, 'CHANGELOG.md', read(work, 'CHANGELOG.md').replace('## [1.0.0]', '## [1.0.1] - 2026-02-01\n\n- crash fix\n\n## [1.0.0]'));
    commit(work, 'fix: stop the crash');
    sh(work, 'git', 'push', '--quiet', '-u', 'origin', 'hotfix/crash');
    r = flow(work, 'check-pr', '--base', 'main', '--head', 'hotfix/crash', '--json');
    assert.equal(r.json.ok, true, r.out);
    assert.equal(r.json.version, '1.0.1');
    const hotfixSha = squashInto(work, 'main', 'hotfix/crash', 'fix: stop the crash (#3)');
    r = flow(work, 'tag-release', '--sha', hotfixSha, '--head', 'hotfix/crash', '--no-gh');
    assert.equal(r.code, 0, r.err);
    assert.match(sh(work, 'git', 'ls-remote', '--tags', 'origin'), /refs\/tags\/v1\.0\.1/);

    // The release is now behind main until it takes the hotfix
    r = flow(work, 'check-pr', '--base', 'main', '--head', 'release/1.1.0');
    assert.match(r.err, /behind main; merge main into it first/);
    sh(work, 'git', 'checkout', '--quiet', 'release/1.1.0');
    r = flow(work, 'back-merge');
    assert.equal(r.code, 0, r.err);
    assert.equal(version(work), '1.1.0', 'the release keeps its version');
    assert.match(read(work, 'CHANGELOG.md'), /crash fix/);
    sh(work, 'git', 'push', '--quiet', 'origin', 'release/1.1.0');
    assert.match(flow(work, 'check-pr', '--base', 'main', '--head', 'release/1.1.0').err, /CHANGELOG\.md on release\/1\.1\.0 has no section for 1\.1\.0/);

    // The changelog lists the feature once and leaves out the back-merged hotfix
    r = flow(work, 'changelog');
    assert.match(r.out, /## \[1\.1\.0\]/);
    assert.match(r.out, /\*\*search:\*\* add search/);
    assert.doesNotMatch(r.out, /stop the crash/);
    assert.equal(flow(work, 'changelog', '--write').code, 0);
    commit(work, 'chore(release): changelog for 1.1.0');
    sh(work, 'git', 'push', '--quiet', 'origin', 'release/1.1.0');
    assert.equal(flow(work, 'check-pr', '--base', 'main', '--head', 'release/1.1.0').code, 0);

    const releaseSha = mergeInto(work, 'main', 'release/1.1.0', 'Merge pull request #4 from acme/release/1.1.0');
    r = flow(work, 'tag-release', '--sha', releaseSha, '--no-gh');
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /tagged v1\.1\.0/);
    assert.match(flow(work, 'tag-release', '--sha', releaseSha, '--no-gh').out, /already points at this merge/);
    assert.equal(flow(work, 'active-release').out, '');
  });

  it('back-merge keeps a hotfix change to a version file and the release version', (t) => {
    const { work } = makeRepo(t);
    assert.equal(flow(work, 'cut-release', '1.1.0').code, 0);
    sh(work, 'git', 'fetch', '--quiet');
    sh(work, 'git', 'checkout', '--quiet', '-b', 'hotfix/dep', 'origin/main');
    const pkg = JSON.parse(read(work, 'package.json'));
    write(work, 'package.json', `${JSON.stringify({ ...pkg, dependencies: { leftpad: '1.0.0' } }, null, 2)}\n`);
    assert.equal(flow(work, 'bump-version', '--branch').code, 0);
    commit(work, 'fix: pin leftpad');
    squashInto(work, 'main', 'hotfix/dep', 'fix: pin leftpad (#5)');
    sh(work, 'git', 'checkout', '--quiet', '-b', 'release/1.1.0', 'origin/release/1.1.0');
    const r = flow(work, 'back-merge');
    assert.equal(r.code, 0, r.err);
    const merged = JSON.parse(read(work, 'package.json'));
    assert.equal(merged.version, '1.1.0');
    assert.deepEqual(merged.dependencies, { leftpad: '1.0.0' }, 'the hotfix change survives');
  });

  it('fails instead of skipping the tag when the PR lookup fails on a squash merge', (t) => {
    const { work } = makeRepo(t);
    sh(work, 'git', 'checkout', '--quiet', '-b', 'hotfix/x');
    assert.equal(flow(work, 'bump-version', '--branch').code, 0);
    commit(work, 'fix: x');
    const sha = squashInto(work, 'main', 'hotfix/x', 'fix: x (#7)');
    const r = flow(work, 'tag-release', '--sha', sha, { env: { PATH: `${failingGh()}${path.delimiter}${process.env.PATH}` } });
    assert.equal(r.code, 1);
    assert.match(r.err, /could not look up the pull request .*HTTP 403/);
    assert.doesNotMatch(sh(work, 'git', 'ls-remote', '--tags', 'origin'), /v1\.0\.1/);
  });

  it('refuses to tag a merge that broke the flow', (t) => {
    const { work } = makeRepo(t);
    sh(work, 'git', 'checkout', '--quiet', '-b', 'feat/x');
    write(work, 'src/x.js', 'x\n');
    commit(work, 'feat: x');
    const featSha = squashInto(work, 'main', 'feat/x', 'feat: x (#5)');
    let r = flow(work, 'tag-release', '--sha', featSha, '--head', 'feat/x', '--no-gh');
    assert.equal(r.code, 1);
    assert.match(r.err, /feat\/x was merged straight into main/);

    sh(work, 'git', 'checkout', '--quiet', '-b', 'release/1.1.0');
    write(work, 'src/y.js', 'y\n');
    commit(work, 'chore: no version bump');
    const squashed = squashInto(work, 'main', 'release/1.1.0', 'chore(release): 1.1.0 (#6)');
    r = flow(work, 'tag-release', '--sha', squashed, '--head', 'release/1.1.0', '--no-gh');
    assert.equal(r.code, 1);
    assert.match(r.err, /must reach main with a merge commit/);
    assert.match(r.err, /package\.json has 1\.0\.0, expected 1\.1\.0/);
    assert.doesNotMatch(sh(work, 'git', 'ls-remote', '--tags', 'origin'), /v1\.1\.0/);
  });
});

describe('git-flow trunk and off', () => {
  it('trunk: features squash into main and a short release branch carries bump and changelog', (t) => {
    const { work } = makeRepo(t, { git: { flow: 'trunk' } });
    sh(work, 'git', 'checkout', '--quiet', '-b', 'feat/a');
    write(work, 'src/a.js', 'a\n');
    commit(work, 'feat: add a');
    assert.equal(flow(work, 'check-pr', '--base', 'main', '--head', 'feat/a', '--json').json.strategy, 'squash');
    squashInto(work, 'main', 'feat/a', 'feat: add a (#1)');

    assert.equal(flow(work, 'cut-release', '1.1.0').code, 0);
    sh(work, 'git', 'fetch', '--quiet');
    assert.match(sh(work, 'git', 'show', 'origin/release/1.1.0:CHANGELOG.md'), /## \[1\.1\.0\][\s\S]*add a[\s\S]*## \[1\.0\.0\]/);
    sh(work, 'git', 'checkout', '--quiet', '-b', 'release/1.1.0', 'origin/release/1.1.0');
    const sha = squashInto(work, 'main', 'release/1.1.0', 'chore(release): 1.1.0 (#2)');
    const r = flow(work, 'tag-release', '--sha', sha, '--head', 'release/1.1.0', '--no-gh');
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /tagged v1\.1\.0/);
  });

  it('off: no branch-model checks and no tags', (t) => {
    const { work } = makeRepo(t, { git: { flow: 'off' } });
    assert.equal(flow(work, 'check-pr', '--base', 'main', '--head', 'anything').code, 0);
    assert.match(flow(work, 'tag-release', '--no-gh').out, /no tag: git.flow is off/);
  });
});

describe('git-flow pushes', () => {
  it('check-push lets chore commits on allow-listed paths straight into main', (t) => {
    const { work } = makeRepo(t);
    const start = sh(work, 'git', 'rev-parse', 'HEAD');
    write(work, 'docs/guide.md', '# Guide\n');
    commit(work, 'chore(docs): add the guide');
    assert.equal(flow(work, 'check-push', '--range', `${start}..HEAD`).code, 0);
    write(work, 'src/app.js', 'module.exports = 9;\n');
    commit(work, 'feat: sneak a feature');
    const r = flow(work, 'check-push', '--range', `${start}..HEAD`);
    assert.equal(r.code, 1);
    assert.match(r.err, /src\/app\.js is not in git\.directPush\.paths/);
    assert.match(r.err, /"feat: sneak a feature" is not a chore commit/);
  });

  it('pre-push refuses force pushes, deletes and hand-made release tags on protected refs', (t) => {
    const { work } = makeRepo(t);
    const config = getGitConfig(work);
    const old = sh(work, 'git', 'rev-parse', 'HEAD');
    sh(work, 'git', 'commit', '--quiet', '--amend', '-m', 'chore: rewritten');
    const rewritten = sh(work, 'git', 'rev-parse', 'HEAD');
    const zero = '0'.repeat(40);
    const problems = checkPushUpdates(config, { cwd: work, remote: 'origin', lines: [
      `refs/heads/main ${rewritten} refs/heads/main ${old}`,
      `(delete) ${zero} refs/heads/release/1.1.0 ${old}`,
      `refs/tags/v9.9.9 ${rewritten} refs/tags/v9.9.9 ${zero}`,
      `refs/heads/feat/x ${rewritten} refs/heads/feat/x ${old}`,
    ] });
    assert.deepEqual(problems, ['force-pushing main is not allowed', 'deleting release/1.1.0 is not allowed', 'v9.9.9 is a release tag; CI creates release tags when a release merges']);
  });

  it('active-release refuses two open releases', (t) => {
    const { work } = makeRepo(t);
    sh(work, 'git', 'push', '--quiet', 'origin', 'main:refs/heads/release/1.1.0', 'main:refs/heads/release/1.2.0', 'main:refs/heads/release/next');
    const r = flow(work, 'active-release');
    assert.equal(r.code, 1);
    assert.match(r.err, /more than one open release: release\/1\.1\.0, release\/1\.2\.0/);
  });
});

describe('git-flow CI', () => {
  it('setup-ci writes the workflow once with the main branch filled in, and --check reports drift', (t) => {
    const { work } = makeRepo(t, { git: { mainBranch: 'trunk-main' } });
    assert.match(flow(work, 'setup-ci', '--check').out, /not set up/);
    assert.match(flow(work, 'setup-ci').out, /created/);
    const yml = read(work, '.github/workflows/adf-git-guards.yml');
    assert.match(yml.split('\n')[1], /^# adf-template: adf-git-guards\.yml@[0-9a-f]{16}$/);
    assert.match(yml, /branches: \[trunk-main\]/);
    assert.doesNotMatch(yml, /__MAIN_BRANCH__/);
    assert.match(flow(work, 'setup-ci').out, /already exists, left alone/);
    assert.match(flow(work, 'setup-ci', '--check').out, /matches ADF's template/);
    write(work, '.github/workflows/adf-git-guards.yml', yml.replace(/@[0-9a-f]{16}/, '@0000000000000000'));
    assert.match(flow(work, 'setup-ci', '--check').out, /ADF's template changed since the copy/);
  });

  it('release-notes prints the committed changelog section of a tag', (t) => {
    const { work } = makeRepo(t);
    write(work, 'CHANGELOG.md', '# Changelog\n\n## [1.1.0] - 2026-03-01\n\n### Features\n\n- add x (abc)\n\n## [1.0.0] - 2026-01-01\n\n- first\n');
    commit(work, 'chore(release): 1.1.0');
    sh(work, 'git', 'tag', '-a', 'v1.1.0', '-m', 'v1.1.0');
    assert.equal(flow(work, 'release-notes', '--tag', 'v1.1.0').out, '### Features\n\n- add x (abc)');
  });

  it('release-notes falls back to the release line of a merge when the changelog has no section', (t) => {
    const { work } = makeRepo(t);
    sh(work, 'git', 'checkout', '--quiet', '-b', 'release/1.1.0');
    write(work, 'src/n.js', 'n\n');
    commit(work, 'feat(notes): add n');
    mergeInto(work, 'main', 'release/1.1.0', 'Merge pull request #8 from acme/release/1.1.0');
    sh(work, 'git', 'tag', '-a', 'v1.1.0', '-m', 'v1.1.0');
    assert.match(flow(work, 'release-notes', '--tag', 'v1.1.0').out, /\*\*notes:\*\* add n/);
  });

  it('check-push --skip-merged-pr skips a push made by merging a PR', (t) => {
    const { work } = makeRepo(t);
    const start = sh(work, 'git', 'rev-parse', 'HEAD');
    sh(work, 'git', 'checkout', '--quiet', '-b', 'release/1.1.0');
    write(work, 'src/b.js', 'b\n');
    commit(work, 'feat: b');
    mergeInto(work, 'main', 'release/1.1.0', 'Merge pull request #9 from acme/release/1.1.0');
    assert.equal(flow(work, 'check-push', '--range', `${start}..HEAD`).code, 1);
    const r = flow(work, 'check-push', '--range', `${start}..HEAD`, '--skip-merged-pr');
    assert.equal(r.code, 0, r.err);
    assert.match(r.out, /merged release\/1\.1\.0 through a PR/);
  });
});

describe('git-flow in a workspace member', () => {
  const { memberGitWorkspace, setManifestMember, localOrigin } = require('../../../../hooks/__tests__/fixtures/member-git-fixtures.cjs');

  it('status --cwd <member> reports the member flow, whatever directory the command starts in', (t) => {
    const ws = memberGitWorkspace(t);
    localOrigin(t, ws.members.order);
    localOrigin(t, ws.root);
    write(ws.root, '.claude/config/adf-config.json', JSON.stringify({ git: { flow: 'release-train', enforcement: 'deny' } }));
    const fromWorkspace = flow(ws.root, 'status', '--cwd', ws.members.order, '--json').json;
    assert.deepEqual([fromWorkspace.flow, fromWorkspace.enforcement, fromWorkspace.mainBranch], ['off', 'ask', 'main']);
    setManifestMember(ws.root, 'order', { git: { flow: 'trunk', enforcement: 'deny', mainBranch: 'main' } });
    const fromMember = flow(ws.members.order, 'status', '--json').json;
    assert.deepEqual([fromMember.flow, fromMember.enforcement, fromMember.target], ['trunk', 'deny', null]);
    assert.equal(flow(ws.root, 'status', '--cwd', ws.members.order, '--json').json.flow, 'trunk');
    assert.equal(flow(ws.root, 'status', '--json').json.flow, 'release-train', 'the workspace keeps its own flow');
  });

  it('pr-target gives the member trunk for a feature branch', (t) => {
    const ws = memberGitWorkspace(t);
    localOrigin(t, ws.members.order);
    setManifestMember(ws.root, 'order', { git: { flow: 'trunk', enforcement: 'ask', mainBranch: 'develop' } });
    assert.equal(flow(ws.root, 'pr-target', '--cwd', ws.members.order, '--head', 'feat/login').out, 'develop');
  });
});
