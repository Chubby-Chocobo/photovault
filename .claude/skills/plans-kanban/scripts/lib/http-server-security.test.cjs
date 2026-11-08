/**
 * Security tests for the plans-kanban HTTP server:
 * dotfiles, prefix-sibling dirs, Host header, and the allowed-plan happy path.
 */
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');

const { createHttpServer } = require('./http-server.cjs');

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

test('plans-kanban server file exposure guards', async (t) => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kanban-sec-')));
  const plansDir = path.join(root, 'plans');
  const siblingDir = path.join(root, 'plans-other');
  fs.mkdirSync(path.join(plansDir, 'p1'), { recursive: true });
  fs.mkdirSync(siblingDir);
  fs.writeFileSync(path.join(root, '.env'), 'SECRET=1');
  fs.writeFileSync(path.join(plansDir, '.env'), 'SECRET=2');
  fs.writeFileSync(path.join(siblingDir, 'secret.md'), '# sibling secret');
  fs.writeFileSync(path.join(plansDir, 'p1', 'plan.md'), '---\ntitle: P1\nstatus: pending\n---\n# P1\n');
  fs.writeFileSync(path.join(plansDir, 'p1', 'img.png'), 'png');

  const server = createHttpServer({ assetsDir, allowedDirs: [assetsDir, plansDir], plansDir, bindHost: '127.0.0.1' });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  t.after(() => {
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  });

  await t.test('.env at project root is refused', async () => {
    const r = await request(port, '/file' + path.join(root, '.env'));
    assert.ok([403, 404].includes(r.status));
    assert.ok(!r.body.includes('SECRET'));
  });

  await t.test('.env inside plans dir is refused', async () => {
    const r = await request(port, '/file' + path.join(plansDir, '.env'));
    assert.ok([403, 404].includes(r.status));
    assert.ok(!r.body.includes('SECRET'));
  });

  await t.test('prefix sibling dir is refused', async () => {
    const r = await request(port, '/view?file=' + encodeURIComponent(path.join(siblingDir, 'secret.md')));
    assert.strictEqual(r.status, 403);
    assert.ok(!r.body.includes('sibling secret'));
    const d = await request(port, '/api/plans?dir=' + encodeURIComponent(siblingDir));
    assert.strictEqual(d.status, 403);
  });

  await t.test('bad Host header is refused', async () => {
    const r = await request(port, '/api/plans', { Host: 'evil.example.com' });
    assert.strictEqual(r.status, 403);
  });

  await t.test('loopback Host headers are accepted', async () => {
    for (const host of [`localhost:${port}`, `127.0.0.1:${port}`, `[::1]:${port}`]) {
      const r = await request(port, '/api/plans', { Host: host });
      assert.strictEqual(r.status, 200, host);
    }
  });

  await t.test('allowed plan file is served', async () => {
    const r = await request(port, '/view?file=' + encodeURIComponent(path.join(plansDir, 'p1', 'plan.md')));
    assert.strictEqual(r.status, 200);
    assert.ok(r.body.includes('P1'));
    const img = await request(port, '/file' + path.join(plansDir, 'p1', 'img.png'));
    assert.strictEqual(img.status, 200);
  });

  await t.test('symlink escaping the plans dir is refused', async () => {
    const link = path.join(plansDir, 'p1', 'link.md');
    fs.symlinkSync(path.join(siblingDir, 'secret.md'), link);
    const r = await request(port, '/view?file=' + encodeURIComponent(link));
    assert.strictEqual(r.status, 403);
  });

  await t.test('malformed percent-encoding does not crash the server', async () => {
    const r = await request(port, '/file/%E0%A4%A');
    assert.strictEqual(r.status, 400);
  });
});

test('allow-lists are per server (a second server does not widen or narrow the first)', async (t) => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kanban-iso-')));
  const a = path.join(root, 'a');
  const b = path.join(root, 'b');
  for (const d of [a, b]) {
    fs.mkdirSync(path.join(d, 'p'), { recursive: true });
    fs.writeFileSync(path.join(d, 'p', 'plan.md'), '---\ntitle: T\n---\n# T\n');
  }
  const sa = createHttpServer({ assetsDir, allowedDirs: [assetsDir, a], plansDir: a });
  const sb = createHttpServer({ assetsDir, allowedDirs: [assetsDir, b], plansDir: b });
  await Promise.all([sa, sb].map((s) => new Promise((r) => s.listen(0, '127.0.0.1', r))));
  t.after(() => {
    sa.close();
    sb.close();
    fs.rmSync(root, { recursive: true, force: true });
  });
  const view = (srv, d) => request(srv.address().port, '/view?file=' + encodeURIComponent(path.join(d, 'p', 'plan.md')));
  assert.strictEqual((await view(sa, a)).status, 200);
  assert.strictEqual((await view(sa, b)).status, 403);
  assert.strictEqual((await view(sb, b)).status, 200);
  assert.strictEqual((await view(sb, a)).status, 403);
});

// ---------------------------------------------------------------------------
// Script injection: escaped plan data, safe embedded JSON, Content-Security-Policy
// ---------------------------------------------------------------------------

function requestFull(port, reqPath) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path: reqPath }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    }).on('error', reject);
  });
}

// Event-handler attribute on a real tag (quoted attribute values are skipped: escaped text may mention one)
function hasLiveHandler(html) {
  return /<[a-z][^>]*\son[a-z]+\s*=/i.test(html.replace(/"[^"]*"/g, '""'));
}

test('kanban pages escape plan data, embed JSON safely and send a CSP', async (t) => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kanban-xss-')));
  const plansDir = path.join(root, 'plans');
  const planDir = path.join(plansDir, 'p1');
  fs.mkdirSync(planDir, { recursive: true });
  fs.writeFileSync(path.join(planDir, 'plan.md'), [
    '---',
    'title: "<img src=x onerror=alert(1)>"',
    'status: pending',
    `issue: '1"><img src=x onerror=alert(2)>'`,
    'description: "</script><script>alert(3)</script> $& $`"',
    'priority: \'P1"><b onmouseover=alert(4)>\'',
    '---',
    '# Plan',
    '',
    '| Phase | Name | Status |',
    '|---|---|---|',
    '| 1 | [<img src=x onerror=alert(5)>](phase-01.md) | Pending |',
    '',
    '<script>alert(6)</script>'
  ].join('\n'));
  fs.writeFileSync(path.join(planDir, 'phase-01.md'), '# Phase 01: <b onclick=alert(7)>x</b>\n');

  const server = createHttpServer({ assetsDir, allowedDirs: [assetsDir, plansDir], plansDir, bindHost: '127.0.0.1' });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  t.after(() => {
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  });

  await t.test('dashboard: no injected tag, attribute or script break-out', async () => {
    const r = await requestFull(port, '/kanban');
    assert.strictEqual(r.status, 200);
    assert.ok(!/<img src=x/i.test(r.body));
    assert.ok(!hasLiveHandler(r.body));
    assert.ok(!r.body.includes('<script>alert'));
    assert.ok(!r.body.includes('github.com/sotatek-dev/adf'), 'no link to a repo the project does not have');
    assert.ok(r.body.includes('class="meta-tag issue"'), 'issue renders as text without a git remote');
    const marker = 'window.__plans = ';
    const start = r.body.indexOf(marker) + marker.length;
    const end = r.body.indexOf(';</script>', start);
    const literal = r.body.slice(start, end);
    assert.ok(!/[<>&\u2028\u2029]/.test(literal));
    assert.strictEqual(JSON.parse(literal)[0].description, '</script><script>alert(3)</script> $& $`');
  });

  await t.test('dashboard: every script tag carries the nonce named in the CSP', async () => {
    const r = await requestFull(port, '/kanban');
    const csp = r.headers['content-security-policy'];
    assert.ok(csp, 'CSP header present');
    const tags = r.body.match(/<script\b[^>]*>/g) || [];
    assert.ok(tags.length >= 2);
    for (const tag of tags) {
      const nonce = /nonce="([^"]+)"/.exec(tag);
      assert.ok(nonce, `nonce on ${tag}`);
      assert.ok(csp.includes(`'nonce-${nonce[1]}'`));
    }
    assert.match(csp, /default-src 'self'/);
    assert.match(csp, /connect-src 'self'/);
    assert.doesNotMatch(csp.match(/script-src[^;]*/)[0], /unsafe-inline/);
  });

  await t.test('plan page: sanitized markdown, escaped title and phase names, CSP', async () => {
    const r = await requestFull(port, '/view?file=' + encodeURIComponent(path.join(planDir, 'plan.md')));
    assert.strictEqual(r.status, 200);
    assert.ok(!/<img src=x/i.test(r.body));
    assert.ok(!hasLiveHandler(r.body));
    assert.ok(!r.body.includes('alert(6)'));
    assert.ok(r.body.includes('&lt;img src=x onerror=alert(1)&gt;'));
    assert.ok(r.headers['content-security-policy']);
    const phase = await requestFull(port, '/view?file=' + encodeURIComponent(path.join(planDir, 'phase-01.md')));
    assert.ok(!hasLiveHandler(phase.body));
  });

  await t.test('error pages escape their message and deny scripts', async () => {
    const r = await requestFull(port, '/nope');
    assert.strictEqual(r.status, 404);
    assert.match(r.headers['content-security-policy'], /script-src 'none'/);
  });
});

test('kanban issue links follow the project git remote', () => {
  const { execFileSync } = require('child_process');
  const { issueBaseFromRemote, resolveIssueBase } = require('./issue-link.cjs');
  const { generateCardMeta } = require('./dashboard-renderer.cjs');

  assert.strictEqual(issueBaseFromRemote('https://github.com/acme/app.git'), 'https://github.com/acme/app/issues');
  assert.strictEqual(issueBaseFromRemote('git@github.com:acme/app.git\n'), 'https://github.com/acme/app/issues');
  assert.strictEqual(issueBaseFromRemote('ssh://git@github.com/acme/app'), 'https://github.com/acme/app/issues');
  assert.strictEqual(issueBaseFromRemote('https://gitlab.com/acme/app.git'), null);
  assert.strictEqual(issueBaseFromRemote(''), null);

  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'kanban-issue-')));
  try {
    const run = (...args) => execFileSync('git', args, { cwd: root, stdio: 'ignore' });
    run('init', '-q');
    assert.strictEqual(resolveIssueBase(root), null, 'no remote');
    run('remote', 'add', 'origin', 'git@github.com:acme/app.git');
    fs.mkdirSync(path.join(root, 'plans'));
    assert.strictEqual(resolveIssueBase(path.join(root, 'plans')), 'https://github.com/acme/app/issues');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }

  const linked = generateCardMeta({ issue: '12' }, 'https://github.com/acme/app/issues');
  assert.ok(linked.includes('href="https://github.com/acme/app/issues/12"'));
  const plain = generateCardMeta({ issue: '12' }, null);
  assert.ok(!plain.includes('<a '), 'plain text without a base');
  assert.ok(plain.includes('#12'));
});

test('kanban browser launcher gives Windows start an empty window title', () => {
  const { openBrowserCommand } = require('./open-browser.cjs');
  assert.strictEqual(openBrowserCommand('win32', 'http://localhost:1'), 'start "" "http://localhost:1"');
  assert.strictEqual(openBrowserCommand('darwin', 'http://localhost:1'), 'open "http://localhost:1"');
  assert.strictEqual(openBrowserCommand('linux', 'http://localhost:1'), 'xdg-open "http://localhost:1"');
});
