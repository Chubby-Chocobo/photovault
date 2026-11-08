'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  DOCS_FOLDERS, LEGACY_MOVES, normalizeDocsRoot, renderableText, designSystemDocsSource, detectDocSite, resolveLocation, describeMarkdown, listConventions, formatConventionsIndex, detectLegacyLayout, formatLegacyNotice,
} = require('../docs-layout.cjs');

function project(t, files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'adf-docs-layout-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.join(dir, path.dirname(rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), content);
  }
  return dir;
}

describe('docs-layout', () => {
  it('every legacy move lands in a known folder or outside docs/', () => {
    for (const { to } of LEGACY_MOVES) {
      const target = resolveLocation(to);
      if (!target.startsWith('docs/')) continue;
      assert.ok(DOCS_FOLDERS.includes(target.split('/')[1]), `${to} is not in a known docs folder`);
    }
  });

  it('resolves locations against the configured roots', () => {
    assert.equal(resolveLocation('docs:requirements/srs.md', { docs: 'handbook' }), 'handbook/requirements/srs.md');
    assert.equal(resolveLocation('plans:journals', { plans: 'work' }), 'work/journals');
    assert.equal(resolveLocation('repo:CHANGELOG.md'), 'CHANGELOG.md');
  });

  it('describes a file by its front-matter description, else its first heading', () => {
    assert.equal(describeMarkdown('---\ndescription: "Branch and release rules"\n---\n# Git\n'), 'Branch and release rules');
    assert.equal(describeMarkdown('---\nadf-template: x@1\n---\n# Code standards\n'), 'Code standards');
    assert.equal(describeMarkdown('plain text'), '');
  });

  it('lists conventions sorted, skipping README and subfolders, and caps the index', (t) => {
    const dir = project(t, {
      'docs/conventions/git-workflow.md': '---\ndescription: Branch model\n---\n',
      'docs/conventions/code-standards.md': '# Code standards\n',
      'docs/conventions/README.md': '# index\n',
      'docs/conventions/old/x.md': '# nested\n',
    });
    const entries = listConventions(path.join(dir, 'docs'));
    assert.deepEqual(entries, [
      { file: 'code-standards.md', description: 'Code standards' },
      { file: 'git-workflow.md', description: 'Branch model' },
    ]);
    assert.deepEqual(formatConventionsIndex(entries, 'docs'), [
      'Project conventions in docs/conventions/ (read the file a task needs before doing it):',
      '- code-standards.md — Code standards',
      '- git-workflow.md — Branch model',
    ]);
    assert.deepEqual(formatConventionsIndex([], 'docs'), []);
    const many = Array.from({ length: 25 }, (_, i) => ({ file: `f${i}.md`, description: '' }));
    const lines = formatConventionsIndex(many, 'docs');
    assert.equal(lines.length, 22);
    assert.equal(lines.at(-1), '- … 5 more in docs/conventions/');
  });

  it('detects an old layout, project rules, and nothing on the current layout', (t) => {
    const legacy = project(t, {
      'docs/project-fsd.md': '# FSD\n',
      'docs/usecases/pay/uc-1.md': '# UC\n',
      'docs/testcases/test-summary.md': '# summary\n',
      'docs/testcases/pay/tc.md': '# tc\n',
      'design-system/MASTER.md': '# master\n',
      'journals/2026-01-01.md': '# j\n',
      '.claude/rules/project-migrations.md': '# rule\n',
    });
    assert.deepEqual(detectLegacyLayout(legacy), [
      { from: 'docs/project-fsd.md', to: 'docs/requirements/srs.md' },
      { from: 'docs/usecases', to: 'docs/requirements/usecases' },
      { from: 'design-system', to: 'docs/design/design-system' },
      { from: 'docs/testcases/test-summary.md', to: 'docs/testing/test-summary.md' },
      { from: 'docs/testcases', to: 'docs/testing/testcases' },
      { from: 'journals', to: 'plans/journals' },
      { from: '.claude/rules/project-migrations.md', to: 'docs/conventions/migrations.md' },
    ]);
    const notice = formatLegacyNotice(detectLegacyLayout(legacy));
    assert.match(notice[0], /old docs layout/);
    assert.match(notice.at(-1), /\/docs migrate/);

    const current = project(t, { 'docs/requirements/srs.md': '# SRS\n', 'plans/journals/x.md': '# j\n' });
    assert.deepEqual(detectLegacyLayout(current), []);
    assert.deepEqual(formatLegacyNotice([]), []);
  });

  it('honours custom docs and plans roots', (t) => {
    const dir = project(t, { 'handbook/project-fsd.md': '# FSD\n', 'journals/a.md': '# j\n' });
    assert.deepEqual(detectLegacyLayout(dir, { docs: 'handbook', plans: 'work' }), [
      { from: 'handbook/project-fsd.md', to: 'handbook/requirements/srs.md' },
      { from: 'journals', to: 'work/journals' },
    ]);
  });

  it('normalizes a docs root to a relative folder inside the project', () => {
    assert.equal(normalizeDocsRoot(' project-docs/ '), 'project-docs');
    assert.equal(normalizeDocsRoot('./a//b'), 'a/b');
    for (const bad of [undefined, '', '.', '/abs', 'C:/x', '../x', 'a/../b', '.git', '.GIT/x', '.claude', '.Claude/docs', 'a\\b']) {
      assert.equal(normalizeDocsRoot(bad), null, String(bad));
    }
  });

  it('renders a docs root into Markdown only when it holds no backtick, $, control character or marker text', () => {
    for (const ok of ['docs', '.docs', '_docs', 'docs--internal', 'site/docs', 'a b']) assert.equal(renderableText(ok), true, ok);
    for (const bad of ['', 'a\nb', 'a\rb', 'a\u0000b', 'a`b', 'a\u0085b', 'a\u2028b', 'a\u2029b', 'a\u202eb', 'a\u2066b', 'a\u2069b', "a$'b", 'a$&b', 'a<!--b', 'a-->b', 'a>>> ADF b', 'a<<< ADF', undefined, null, 7]) {
      assert.equal(renderableText(bad), false, JSON.stringify(bad));
    }
  });

  it('treats a root design-system/ as old docs only when it is Markdown with a MASTER.md', (t) => {
    assert.equal(designSystemDocsSource(project(t, { 'design-system/package.json': '{}', 'design-system/MASTER.md': '# m\n' })), null);
    assert.equal(designSystemDocsSource(project(t, { 'design-system/notes.md': '# n\n' })), null);
    assert.deepEqual(designSystemDocsSource(project(t, { 'design-system/MASTER.md': '# m\n' })), { from: 'design-system' });
    assert.deepEqual(designSystemDocsSource(project(t, { 'design-system/acme/MASTER.md': '# m\n', 'design-system/acme/pages/a.md': '# a\n' })), { from: 'design-system/acme' });
    assert.deepEqual(designSystemDocsSource(project(t, { 'design-system/a/MASTER.md': '# a\n', 'design-system/b/MASTER.md': '# b\n' })), { from: 'design-system' });
    assert.deepEqual(detectLegacyLayout(project(t, { 'design-system/src/index.ts': 'x', 'design-system/README.md': '# pkg\n' })), []);
  });

  it('recognizes a documentation site, keeps its assets out, and advises a separate docs root', (t) => {
    const dir = project(t, { 'mkdocs.yml': 'site_name: x\n', 'docs/assets/logo.png': 'png', 'docs/deployment.md': '# d\n' });
    assert.equal(detectDocSite(dir), 'mkdocs.yml');
    const found = detectLegacyLayout(dir);
    assert.deepEqual(found.map((f) => f.from), ['docs/deployment.md']);
    const notice = formatLegacyNotice(found, { docSite: 'mkdocs.yml' });
    assert.match(notice[0], /documentation site \(mkdocs\.yml\)/);
    assert.match(notice.join('\n'), /"legacyLayoutNotice": false/);
  });

  it('caps a long convention description', (t) => {
    const dir = project(t, { 'docs/conventions/x.md': `---\ndescription: ${'a'.repeat(400)}\n---\n` });
    assert.equal(listConventions(path.join(dir, 'docs'))[0].description.length, 200);
  });
});
