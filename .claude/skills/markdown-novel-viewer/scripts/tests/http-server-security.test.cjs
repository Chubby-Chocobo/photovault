/**
 * Security tests for the markdown-novel-viewer (used by /preview) HTTP server:
 * dotfiles, prefix-sibling dirs, Host header, project-root exposure, happy path.
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

const { createHttpServer } = require('../lib/http-server.cjs');
const { isPathAllowed, isHostHeaderAllowed, isLoopbackBind } = require('../lib/path-guard.cjs');

const assetsDir = path.join(__dirname, '..', '..', 'assets');

function request(port, reqPath, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path: reqPath, headers }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

test('path-guard unit checks', () => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'guard-')));
  try {
    fs.mkdirSync(path.join(root, 'proj'));
    fs.mkdirSync(path.join(root, 'proj-other'));
    assert.strictEqual(isPathAllowed(path.join(root, 'proj-other', 'a.md'), [path.join(root, 'proj')]), false);
    assert.strictEqual(isPathAllowed(path.join(root, 'proj', 'a.md'), [path.join(root, 'proj')]), true);
    assert.strictEqual(isPathAllowed(path.join(root, 'proj', '.git', 'config'), [path.join(root, 'proj')]), false);
    assert.strictEqual(isPathAllowed(path.join(root, 'proj', 'a.md'), []), false);
    assert.strictEqual(isHostHeaderAllowed('evil.com', '127.0.0.1'), false);
    assert.strictEqual(isHostHeaderAllowed('localhost:3456', '127.0.0.1'), true);
    assert.strictEqual(isHostHeaderAllowed('evil.com', '0.0.0.0'), true);
    assert.strictEqual(isLoopbackBind('0.0.0.0'), false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('markdown-novel-viewer server file exposure guards', async (t) => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'mdv-sec-')));
  const plansDir = path.join(root, 'plans', 'p1');
  const siblingDir = path.join(root, 'plans-other');
  fs.mkdirSync(plansDir, { recursive: true });
  fs.mkdirSync(siblingDir);
  fs.writeFileSync(path.join(root, '.env'), 'SECRET=1');
  fs.writeFileSync(path.join(root, 'config.json'), '{"secret":true}');
  fs.writeFileSync(path.join(plansDir, '.env'), 'SECRET=2');
  fs.writeFileSync(path.join(siblingDir, 'secret.md'), '# sibling secret');
  fs.writeFileSync(path.join(plansDir, 'plan.md'), '# Allowed plan');
  fs.writeFileSync(path.join(plansDir, 'logo.png'), 'png');
  fs.writeFileSync(path.join(root, 'README.md'), '# Readme');
  fs.writeFileSync(path.join(root, 'logo.png'), 'png');
  fs.writeFileSync(path.join(root, 'notes.md'), '# notes');
  fs.mkdirSync(path.join(root, 'docs'));
  fs.writeFileSync(path.join(root, 'docs', 'd.png'), 'png');

  // Same allow-list the CLI builds when previewing a file inside plansDir
  const server = createHttpServer({
    assetsDir,
    renderMarkdown: (fp) => `<html>${fs.readFileSync(fp, 'utf8')}</html>`,
    allowedDirs: [assetsDir, plansDir],
    bindHost: '127.0.0.1'
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  t.after(() => {
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  });

  await t.test('.env is refused on /file, /view and /browse', async () => {
    for (const p of [
      '/file/' + encodeURIComponent(path.join(root, '.env')),
      '/file/' + encodeURIComponent(path.join(plansDir, '.env')),
      '/view?file=' + encodeURIComponent(path.join(plansDir, '.env')),
      '/browse?dir=' + encodeURIComponent(root)
    ]) {
      const r = await request(port, p);
      assert.ok([403, 404].includes(r.status), p);
      assert.ok(!r.body.includes('SECRET'), p);
    }
  });

  await t.test('project root files outside the allow-list are refused', async () => {
    const r = await request(port, '/file/' + encodeURIComponent(path.join(root, 'config.json')));
    assert.strictEqual(r.status, 403);
  });

  await t.test('prefix sibling dir is refused', async () => {
    const r = await request(port, '/view?file=' + encodeURIComponent(path.join(siblingDir, 'secret.md')));
    assert.strictEqual(r.status, 403);
    assert.ok(!r.body.includes('sibling secret'));
  });

  await t.test('bad Host header is refused', async () => {
    const r = await request(port, '/', { Host: 'evil.example.com' });
    assert.strictEqual(r.status, 403);
    const ok = await request(port, '/', { Host: `localhost:${port}` });
    assert.strictEqual(ok.status, 200);
  });

  await t.test('allowed plan file is served', async () => {
    const r = await request(port, '/view?file=' + encodeURIComponent(path.join(plansDir, 'plan.md')));
    assert.strictEqual(r.status, 200);
    assert.ok(r.body.includes('Allowed plan'));
  });

  await t.test('exact-file allow-list serves only that file', async () => {
    const only = createHttpServer({
      assetsDir,
      renderMarkdown: (fp) => fs.readFileSync(fp, 'utf8'),
      allowedDirs: [assetsDir],
      allowedFiles: [path.join(plansDir, 'plan.md')],
      bindHost: '127.0.0.1'
    });
    await new Promise((r) => only.listen(0, '127.0.0.1', r));
    try {
      const p2 = only.address().port;
      const ok = await request(p2, '/view?file=' + encodeURIComponent(path.join(plansDir, 'plan.md')));
      assert.strictEqual(ok.status, 200);
      const no = await request(p2, '/view?file=' + encodeURIComponent(path.join(siblingDir, 'secret.md')));
      assert.strictEqual(no.status, 403);
    } finally {
      only.close();
    }
  });

  await t.test('allowed image is served via the real /file/ URL form; symlink to non-image refused', async () => {
    const ok = await request(port, '/file/' + encodeURIComponent(path.join(plansDir, 'logo.png')));
    assert.strictEqual(ok.status, 200);
    const link = path.join(plansDir, 'conf.png');
    fs.symlinkSync(path.join(root, 'config.json'), link);
    const bad = await request(port, '/file/' + encodeURIComponent(link));
    assert.strictEqual(bad.status, 403);
  });

  await t.test('file in project root: sibling images only', async () => {
    const readme = path.join(root, 'README.md');
    const srv = createHttpServer({
      assetsDir,
      renderMarkdown: (fp) => fs.readFileSync(fp, 'utf8'),
      allowedDirs: [assetsDir],
      allowedFiles: [readme],
      mediaDirs: [root],
      bindHost: '127.0.0.1'
    });
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    try {
      const p = srv.address().port;
      const f = (x) => request(p, '/file/' + encodeURIComponent(path.join(root, x)));
      assert.strictEqual((await f('logo.png')).status, 200);
      assert.strictEqual((await f('.env')).status, 403);
      assert.strictEqual((await f('notes.md')).status, 403);
      assert.strictEqual((await f('config.json')).status, 403);
      assert.strictEqual((await f('docs/d.png')).status, 403);
      assert.strictEqual((await request(p, '/view?file=' + encodeURIComponent(readme))).status, 200);
    } finally {
      srv.close();
    }
  });
});

// ---------------------------------------------------------------------------
// Script injection: sanitizer, escaping, embedded JSON and Content-Security-Policy
// ---------------------------------------------------------------------------

const { sanitizeHtml, safeJson, escapeHtml, buildCsp } = require('../lib/html-safety.cjs');
const { renderMarkdownFile, renderTOCHtml } = require('../lib/markdown-renderer.cjs');
const { buildReaderPage, renderHeaderNav, renderBackButton } = require('../lib/page-builder.cjs');
const processMgr = require('../lib/process-mgr.cjs');

function requestFull(port, reqPath) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path: reqPath }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    }).on('error', reject);
  });
}

test('sanitizeHtml removes script-capable markup and keeps normal formatting', () => {
  const vectors = [
    '<script>alert(1)</script>after',
    '<SCRIPT SRC=//evil/x.js></SCRIPT>',
    '<img src=x onerror=alert(1)>',
    '<img src="x" ONERROR="alert(1)">',
    '<a href="javascript:alert(1)">x</a>',
    '<a href="  JaVa\tScRiPt:alert(1)">x</a>',
    '<a href="&#106;avascript:alert(1)">x</a>',
    '<a href="javascript&colon;alert(1)">x</a>',
    '<a href="data:text/html,<script>alert(1)</script>">x</a>',
    '<iframe src="https://evil.example"></iframe>',
    '<object data="x"></object><embed src="x">',
    '<svg><script>alert(1)</script></svg>',
    '<svg onload=alert(1)>',
    '<style>body{display:none}</style>',
    '<form action="/x"><input name=a></form>',
    '<img src="data:image/svg+xml;base64,PHN2Zz4=">',
    '<div onclick="alert(1)" style="position:fixed">x</div>',
    '<a href="x" title="a" onmouseover=alert(1)>x</a>',
    '<img src=x onerror=alert(1)//',
    '<a title="x><script>alert(1)</script>'
  ];
  for (const v of vectors) {
    const out = sanitizeHtml(v);
    assert.ok(!/<script|<iframe|<object|<embed|<svg|<style|<form/i.test(out), `tag survived: ${v} -> ${out}`);
    assert.ok(!/<[^>]*\son\w+\s*=/i.test(out), `handler survived: ${v} -> ${out}`);
    assert.ok(!/javascript:/i.test(out.replace(/&[#a-z0-9]+;/gi, '')), `js url survived: ${v} -> ${out}`);
    assert.ok(!/data:text|data:image\/svg|style=/i.test(out), `unsafe attr value survived: ${v} -> ${out}`);
  }

  const kept = sanitizeHtml(
    '<h2 class="x">T</h2><p><a href="https://ok.example/p?a=1&amp;b=2">l</a> <a href="#sec">s</a> <a href="/view?file=a">v</a>' +
    '<img src="/file/a.png" alt="a"><img src="data:image/png;base64,AAAA"></p>' +
    '<table><tr><td align="left">c</td></tr></table><pre><code class="hljs language-js"><span class="hljs-keyword">const</span></code></pre>' +
    '<input disabled="" type="checkbox"><details><summary>s</summary>b</details>'
  );
  assert.ok(kept.includes('<a href="https://ok.example/p?a=1&amp;b=2">'));
  assert.ok(kept.includes('<a href="#sec">') && kept.includes('<a href="/view?file=a">'));
  assert.ok(kept.includes('<img src="/file/a.png" alt="a">'));
  assert.ok(kept.includes('<img src="data:image/png;base64,AAAA">'));
  assert.ok(kept.includes('<td align="left">'));
  assert.ok(kept.includes('<span class="hljs-keyword">const</span>'));
  assert.ok(kept.includes('<input disabled="" type="checkbox">'));
  assert.ok(kept.includes('<details><summary>s</summary>'));
});

test('safeJson cannot close a script block or break a JS string literal', () => {
  const out = safeJson({ a: '</script><script>alert(1)</script>', b: '\u2028\u2029&<>' });
  assert.ok(!/[<>&\u2028\u2029]/.test(out));
  assert.deepStrictEqual(JSON.parse(out), { a: '</script><script>alert(1)</script>', b: '\u2028\u2029&<>' });
});

test('buildCsp pins script sources to self, the nonce and the mermaid CDN', () => {
  const csp = buildCsp('abc123');
  assert.match(csp, /script-src 'self' 'nonce-abc123' https:\/\/cdn\.jsdelivr\.net(;|$)/);
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /connect-src 'self'/);
  assert.match(csp, /object-src 'none'/);
  assert.doesNotMatch(csp, /script-src[^;]*unsafe-inline/);
  assert.match(buildCsp(null), /script-src 'none'/);
});

test('viewer pages escape every data field and send a CSP', async (t) => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'mdv-xss-')));
  const evilName = '<img src=x onerror=alert(4)>.md';
  fs.writeFileSync(path.join(root, evilName), '# ok\n');
  fs.writeFileSync(path.join(root, 'body.md'), [
    '---',
    'title: "<img src=x onerror=alert(2)>"',
    'note: "</script><script>alert(3)</script>"',
    'sep: "a\u2028b"',
    '---',
    '# Heading',
    '',
    '<script>alert(1)</script>',
    '',
    '<img src=x onerror=alert(5)> and [bad](javascript:alert(6)) and $` dollar $& text',
    '',
    '```mermaid',
    'graph TD; A-->B',
    '```'
  ].join('\n'));

  const renderMarkdown = (filePath) => {
    const { html, toc, frontmatter, title } = renderMarkdownFile(filePath);
    return buildReaderPage(path.join(assetsDir, 'template.html'), {
      title, toc: renderTOCHtml(toc), navSidebar: '', navFooter: '', content: html, isPlan: false,
      frontmatter, backButton: renderBackButton('/browse?dir=x', 'Back'), headerNav: renderHeaderNav({})
    });
  };
  const server = createHttpServer({ assetsDir, renderMarkdown, allowedDirs: [root], bindHost: '127.0.0.1' });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  t.after(() => {
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  });

  await t.test('markdown page: no injected script, handler or javascript: link', async () => {
    const r = await requestFull(port, '/view?file=' + encodeURIComponent(path.join(root, 'body.md')));
    assert.strictEqual(r.status, 200);
    assert.ok(!r.body.includes('alert(1)'));
    assert.ok(!/<[^>]*\sonerror=/i.test(r.body));
    assert.ok(!/javascript:/i.test(r.body));
    assert.ok(!r.body.includes('<img src=x'));
    assert.ok(r.body.includes('&lt;img src=x onerror=alert(2)&gt;'), 'title is escaped');
    assert.ok(r.body.includes('class="mermaid"'), 'mermaid block still rendered');
    assert.ok(r.body.includes('$` dollar $&amp; text'), 'dollar sequences stay literal');
  });

  await t.test('embedded front matter cannot leave its script block', async () => {
    const r = await requestFull(port, '/view?file=' + encodeURIComponent(path.join(root, 'body.md')));
    const marker = 'window.__frontmatter = ';
    const start = r.body.indexOf(marker) + marker.length;
    const end = r.body.indexOf(';\n  </script>', start);
    const literal = r.body.slice(start, end);
    assert.ok(!/[<>\u2028\u2029]/.test(literal));
    assert.strictEqual(JSON.parse(literal).note, '</script><script>alert(3)</script>');
    assert.strictEqual((r.body.match(/<script/g) || []).length, (r.body.match(/<script nonce="/g) || []).length,
      'every script tag carries the nonce');
  });

  await t.test('HTML responses carry a CSP whose nonce matches the page', async () => {
    const r = await requestFull(port, '/view?file=' + encodeURIComponent(path.join(root, 'body.md')));
    const csp = r.headers['content-security-policy'];
    assert.ok(csp, 'CSP header present');
    const nonce = /<script nonce="([^"]+)"/.exec(r.body)[1];
    assert.ok(csp.includes(`'nonce-${nonce}'`));
    assert.match(csp, /script-src [^;]*cdn\.jsdelivr\.net/);
    for (const route of ['/', '/browse?dir=' + encodeURIComponent(root), '/missing']) {
      const p = await requestFull(port, route);
      assert.ok(p.headers['content-security-policy'], `CSP on ${route}`);
      assert.match(p.headers['content-security-policy'], /script-src 'none'/);
    }
  });

  await t.test('directory browser escapes file names', async () => {
    const r = await requestFull(port, '/browse?dir=' + encodeURIComponent(root));
    assert.strictEqual(r.status, 200);
    assert.ok(!r.body.includes('<img src=x'));
    assert.ok(r.body.includes('&lt;img src=x onerror=alert(4)&gt;.md'));
  });
});

test('escapeHtml escapes quotes and angle brackets', () => {
  assert.strictEqual(escapeHtml('"><img src=x onerror=1>'), '&quot;&gt;&lt;img src=x onerror=1&gt;');
});

test('PID files live in a private per-user directory under the OS temp dir', () => {
  const port = 59871;
  processMgr.writePidFile(port, process.pid);
  try {
    const file = processMgr.getPidFilePath(port);
    assert.ok(file.startsWith(fs.realpathSync(os.tmpdir())) || file.startsWith(os.tmpdir()));
    assert.notStrictEqual(path.dirname(file), '/tmp');
    assert.strictEqual(processMgr.readPidFile(port), process.pid);
    if (process.platform !== 'win32') {
      assert.strictEqual(fs.statSync(file).mode & 0o077, 0, 'file is owner-only');
      assert.strictEqual(fs.statSync(path.dirname(file)).mode & 0o077, 0, 'dir is owner-only');
    }
  } finally {
    processMgr.removePidFile(port);
  }
  assert.strictEqual(processMgr.readPidFile(port), null);
});

test('PID file is not written through a planted symlink', { skip: process.platform === 'win32' }, () => {
  const port = 59872;
  const victim = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'pid-victim-')), 'victim.txt');
  fs.writeFileSync(victim, 'keep');
  processMgr.writePidFile(port, process.pid);
  const file = processMgr.getPidFilePath(port);
  try {
    fs.rmSync(file);
    fs.symlinkSync(victim, file);
    processMgr.writePidFile(port, process.pid);
    assert.strictEqual(fs.readFileSync(victim, 'utf8'), 'keep');
  } finally {
    processMgr.removePidFile(port);
    fs.rmSync(path.dirname(victim), { recursive: true, force: true });
  }
});
