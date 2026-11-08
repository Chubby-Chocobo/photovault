'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { run, buildMigrationPlan, readRoots } = require('./migrate-docs-layout.cjs');
const { rewriteLinks } = require('./lib/markdown-link-rewriter.cjs');

const SCRIPT = path.join(__dirname, 'migrate-docs-layout.cjs');

function makeProject(t, files, { git = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-migrate-docs-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.join(root, path.dirname(rel)), { recursive: true });
    fs.writeFileSync(path.join(root, rel), content);
  }
  if (git) {
    const g = (...args) => spawnSync('git', args, { cwd: root, encoding: 'utf8' });
    g('init', '--quiet');
    g('-c', 'user.name=t', '-c', 'user.email=t@t', 'add', '-A');
    g('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '--quiet', '-m', 'init');
  }
  return root;
}

const read = (root, rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const exists = (root, rel) => fs.existsSync(path.join(root, rel));

const LEGACY_PROJECT = {
  'docs/project-overview-pdr.md': '# PDR\nSee [the FSD](./project-fsd.md) and [arch](system-architecture.md#data).\n',
  'docs/project-fsd.md': '# FSD\nUse cases: [pay](usecases/pay/uc-1.md). Code: [src](../src/app.ts).\n',
  'docs/project-roadmap.md': '# Roadmap\nA longer roadmap with more content in it.\n',
  'docs/development-roadmap.md': '# Dev roadmap\n',
  'docs/usecases/pay/uc-1.md': '# UC\nBack to [SRS](../../project-fsd.md).\n',
  'docs/system-architecture.md': '# Arch\n',
  'docs/codebase-summary.md': '# Summary\n',
  'docs/decisions/001-db.md': '# ADR\n',
  'docs/code-standards.md': '# Standards\n',
  'docs/deployment-guide.md': '# Deploy\n',
  'docs/testcases/test-summary.md': '# Summary\n[tc](pay/tc-1.md)\n',
  'docs/testcases/pay/tc-1.md': '# TC\n',
  'docs/testcases/export/all.csv': 'id\n',
  'docs/design-system/tokens.json': '{}',
  'docs/wireframes/home.html': '<html></html>',
  'docs/project-changelog.md': '# Changelog\n',
  'docs/assets/logo.png': 'png',
  'journals/2026-01-01-outage.md': '# Outage\n',
  'src/app.ts': 'export {};\n',
  'README.md': 'Docs: [arch](docs/system-architecture.md), [site](https://example.com/docs/project-fsd.md).\n',
};

describe('migrate-docs-layout', () => {
  it('moves every old path to its new place, keeps duplicates for a manual merge, and rewrites links', (t) => {
    const root = makeProject(t, LEGACY_PROJECT);
    const r = run({ project: root });

    for (const rel of [
      'docs/requirements/prd.md', 'docs/requirements/srs.md', 'docs/requirements/roadmap.md', 'docs/requirements/usecases/pay/uc-1.md',
      'docs/architecture/system-architecture.md', 'docs/architecture/codebase-summary.md', 'docs/architecture/decisions/001-db.md',
      'docs/conventions/code-standards.md', 'docs/conventions/deployment.md',
      'docs/testing/test-summary.md', 'docs/testing/testcases/pay/tc-1.md', 'docs/testing/exports/all.csv',
      'docs/design/design-system/tokens.json', 'docs/design/wireframes/home.html', 'CHANGELOG.md', 'assets/logo.png',
      'plans/journals/2026-01-01-outage.md',
    ]) assert.ok(exists(root, rel), `${rel} missing`);
    assert.ok(!exists(root, 'journals') && !exists(root, 'docs/testcases'));

    // The larger roadmap moved; the other stays for a manual merge
    assert.match(read(root, 'docs/requirements/roadmap.md'), /longer roadmap/);
    assert.ok(exists(root, 'docs/development-roadmap.md'));
    assert.deepEqual(r.mergeByHand.map((m) => m.from), ['docs/development-roadmap.md']);

    // Links follow both the moved file and its target; anchors, URLs and code links survive
    assert.equal(read(root, 'docs/requirements/prd.md'), '# PDR\nSee [the FSD](./srs.md) and [arch](../architecture/system-architecture.md#data).\n');
    assert.equal(read(root, 'docs/requirements/srs.md'), '# FSD\nUse cases: [pay](usecases/pay/uc-1.md). Code: [src](../../src/app.ts).\n');
    assert.equal(read(root, 'docs/requirements/usecases/pay/uc-1.md'), '# UC\nBack to [SRS](../../srs.md).\n');
    assert.equal(read(root, 'docs/testing/test-summary.md'), '# Summary\n[tc](testcases/pay/tc-1.md)\n');
    assert.equal(read(root, 'README.md'), 'Docs: [arch](docs/architecture/system-architecture.md), [site](https://example.com/docs/project-fsd.md).\n');

    // git history follows tracked files
    const status = spawnSync('git', ['status', '--porcelain'], { cwd: root, encoding: 'utf8' }).stdout;
    assert.match(status, /^R {2}docs\/code-standards\.md -> docs\/conventions\/code-standards\.md$/m);
    assert.match(status, /^RM docs\/project-fsd\.md -> docs\/requirements\/srs\.md$/m, 'renamed, then its links rewritten');

    // A second run changes nothing
    const again = run({ project: root });
    assert.deepEqual(again.moves, []);
    assert.deepEqual(again.rewrites, []);
  });

  it('--dry-run prints the plan and changes nothing', (t) => {
    const root = makeProject(t, LEGACY_PROJECT);
    const r = spawnSync(process.execPath, [SCRIPT, '--dry-run'], { cwd: root, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, /^Would move:\n {2}docs\/project-overview-pdr\.md -> docs\/requirements\/prd\.md$/m);
    assert.match(r.stdout, /Merge by hand:\n {2}docs\/development-roadmap\.md \(left in place\) into docs\/requirements\/roadmap\.md: duplicate of docs\/project-roadmap\.md/);
    assert.ok(exists(root, 'docs/project-fsd.md') && !exists(root, 'docs/requirements'));
  });

  it('refuses uncommitted changes in files it would move unless --allow-dirty', (t) => {
    const root = makeProject(t, { 'docs/project-fsd.md': '# FSD\n' });
    fs.appendFileSync(path.join(root, 'docs/project-fsd.md'), 'edit\n');
    assert.throws(() => run({ project: root }), (err) => err.code === 'EDIRTY' && /docs\/project-fsd\.md/.test(err.message));
    assert.ok(exists(root, 'docs/project-fsd.md'));
    run({ project: root, allowDirty: true });
    assert.equal(read(root, 'docs/requirements/srs.md'), '# FSD\nedit\n');
  });

  it('works without git, honours paths.docs and paths.plans, and leaves an existing target alone', (t) => {
    const root = makeProject(t, {
      '.claude/config/adf-config.json': JSON.stringify({ paths: { docs: 'handbook', plans: 'work' } }),
      'handbook/project-fsd.md': '# FSD\n',
      'handbook/code-standards.md': '# old\n',
      'handbook/conventions/code-standards.md': '# new\n',
      'journals/a.md': '# j\n',
    }, { git: false });
    assert.deepEqual(readRoots(root), { docs: 'handbook', plans: 'work' });
    assert.throws(() => run({ project: root }), (err) => err.code === 'ENOGIT');
    assert.ok(exists(root, 'handbook/project-fsd.md'), 'nothing moved without git');
    const r = run({ project: root, allowNoGit: true });
    assert.ok(exists(root, 'handbook/requirements/srs.md') && exists(root, 'work/journals/a.md'));
    assert.equal(read(root, 'handbook/conventions/code-standards.md'), '# new\n');
    assert.deepEqual(r.mergeByHand, [{ from: 'handbook/code-standards.md', to: 'handbook/conventions/code-standards.md', reason: 'handbook/conventions/code-standards.md already exists' }]);
  });

  it('moves project rules only with --include-rules', (t) => {
    const root = makeProject(t, { '.claude/rules/project-migrations.md': '# Migrations\n' });
    assert.deepEqual(buildMigrationPlan(root, { docs: 'docs', plans: 'plans' }).rulesSkipped, ['.claude/rules/project-migrations.md']);
    run({ project: root, includeRules: true });
    assert.equal(read(root, 'docs/conventions/migrations.md'), '# Migrations\n');
  });

  it('moves a root design-system/ only when it is old Markdown output, flattening a single project folder', (t) => {
    const code = makeProject(t, { 'design-system/package.json': '{}', 'design-system/src/index.ts': 'export {};\n', 'design-system/README.md': '# pkg\n' });
    assert.deepEqual(buildMigrationPlan(code, { docs: 'docs', plans: 'plans' }).moves, [], 'a code package is not docs');

    const single = makeProject(t, { 'design-system/acme/MASTER.md': '# master\n', 'design-system/acme/pages/home.md': '# home\n' });
    run({ project: single });
    assert.ok(exists(single, 'docs/design/design-system/MASTER.md') && exists(single, 'docs/design/design-system/pages/home.md'));
    assert.ok(!exists(single, 'design-system'), 'the emptied root folder is removed');

    const several = makeProject(t, { 'design-system/a/MASTER.md': '# a\n', 'design-system/b/MASTER.md': '# b\n' });
    assert.deepEqual(buildMigrationPlan(several, { docs: 'docs', plans: 'plans' }).moves, [{ from: 'design-system', to: 'docs/design/design-system' }]);
  });

  it('checks every move first: a blocked target moves nothing and says why', (t) => {
    const root = makeProject(t, { 'docs/project-fsd.md': '# FSD\n', 'docs/design-system/tokens.json': '{}', 'docs/design': 'a file in the way\n', 'README.md': '[srs](docs/project-fsd.md)\n' });
    assert.throws(() => run({ project: root }), (err) => err.code === 'EPREFLIGHT' && /docs\/design is a file/.test(err.message));
    assert.ok(exists(root, 'docs/project-fsd.md') && !exists(root, 'docs/requirements'));
    assert.equal(read(root, 'README.md'), '[srs](docs/project-fsd.md)\n');
  });

  it('reports where a duplicate inside a moving folder really ends up', (t) => {
    const root = makeProject(t, { 'docs/testcases/test-summary.md': '# old\n', 'docs/testcases/pay/tc.md': '# tc\n', 'docs/testing/test-summary.md': '# new\n' });
    const r = run({ project: root });
    assert.deepEqual(r.mergeByHand, [{ from: 'docs/testcases/test-summary.md', to: 'docs/testing/test-summary.md', reason: 'docs/testing/test-summary.md already exists', movesTo: 'docs/testing/testcases/test-summary.md' }]);
    assert.ok(exists(root, 'docs/testing/testcases/test-summary.md'));
  });

  it('refuses uncommitted edits in files whose links it would rewrite, and a symlinked docs folder', (t) => {
    const root = makeProject(t, { 'docs/project-fsd.md': '# FSD\n', 'README.md': '[srs](docs/project-fsd.md)\n' });
    fs.appendFileSync(path.join(root, 'README.md'), 'my edit\n');
    assert.throws(() => run({ project: root }), (err) => err.code === 'EDIRTY' && /README\.md/.test(err.message));

    const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-migrate-outside-'));
    t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
    fs.writeFileSync(path.join(outside, 'project-fsd.md'), '# FSD\n');
    const linked = makeProject(t, {});
    fs.symlinkSync(outside, path.join(linked, 'docs'));
    assert.throws(() => run({ project: linked }), (err) => err.code === 'EPREFLIGHT' && /docs is a symlink/.test(err.message));
    assert.ok(fs.existsSync(path.join(outside, 'project-fsd.md')));
  });

  it('leaves code blocks alone and fixes links in other tracked Markdown files', (t) => {
    const root = makeProject(t, {
      'docs/project-fsd.md': '# FSD\n',
      'README.md': '[srs](docs/project-fsd.md)\n\n```md\n[example](docs/project-fsd.md)\n```\nInline `[x](docs/project-fsd.md)`\n',
      'packages/api/README.md': 'See [SRS](../../docs/project-fsd.md).\n',
    });
    run({ project: root });
    assert.equal(read(root, 'README.md'), '[srs](docs/requirements/srs.md)\n\n```md\n[example](docs/project-fsd.md)\n```\nInline `[x](docs/project-fsd.md)`\n');
    assert.equal(read(root, 'packages/api/README.md'), 'See [SRS](../../docs/requirements/srs.md).\n');
  });

  it('will not reorganize a documentation site unless asked', (t) => {
    const root = makeProject(t, { 'mkdocs.yml': 'site_name: x\n', 'docs/deployment.md': '# Deploy\n', 'docs/assets/logo.png': 'png' });
    const plan = run({ project: root, dryRun: true });
    assert.equal(plan.docSite, 'mkdocs.yml');
    assert.ok(!plan.moves.some((m) => m.from === 'docs/assets'), 'site assets stay');
    assert.throws(() => run({ project: root }), (err) => err.code === 'EDOCSITE');
  });

  it('does not rewrite a file outside the project through a tracked symlink', (t) => {
    const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-migrate-outside-'));
    t.after(() => fs.rmSync(outside, { recursive: true, force: true }));
    const shared = path.join(outside, 'shared.md');
    const original = 'Read [the FSD](docs/project-fsd.md).\n';
    fs.writeFileSync(shared, original);
    const root = makeProject(t, { 'docs/project-fsd.md': '# FSD\n', 'docs/other.md': '[fsd](project-fsd.md)\n' }, { git: false });
    fs.symlinkSync(shared, path.join(root, 'notes.md'));
    fs.symlinkSync(outside, path.join(root, 'linked-dir'));
    const g = (...args) => spawnSync('git', args, { cwd: root, encoding: 'utf8' });
    g('init', '--quiet');
    g('-c', 'user.name=t', '-c', 'user.email=t@t', 'add', '-A');
    g('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '--quiet', '-m', 'init');
    run({ project: root });
    assert.equal(fs.readFileSync(shared, 'utf8'), original, 'file behind the symlink is untouched');
    assert.ok(fs.lstatSync(path.join(root, 'notes.md')).isSymbolicLink(), 'the link itself is kept');
    assert.equal(read(root, 'docs/other.md'), '[fsd](requirements/srs.md)\n', 'project files are still rewritten');
  });

  it('rewriteLinks handles reference links and href, and leaves templates and absolute paths alone', () => {
    const map = (rel) => (rel === 'docs/a.md' ? 'docs/x/a.md' : rel);
    const { text, changes } = rewriteLinks('[r]: a.md\n<a href="a.md">a</a>\n[t]({slug}.md) [abs](/a.md) [m](mailto:x@y)\n', {
      fileOld: 'docs/b.md', fileNew: 'docs/b.md', mapPath: map,
    });
    assert.equal(text, '[r]: x/a.md\n<a href="x/a.md">a</a>\n[t]({slug}.md) [abs](/a.md) [m](mailto:x@y)\n');
    assert.equal(changes.length, 2);
  });
});
