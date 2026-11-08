'use strict';

/**
 * Finds secrets that a `git commit` is about to record: secret-looking files and
 * added lines that match well-known credential formats. Patterns favour precision
 * over recall so the guard rarely asks for nothing. Values are never returned,
 * only the rule name and file:line, so a finding can be shown without leaking it.
 */

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');
const { CREDENTIAL_URL_SOURCE } = require('./manifest-credential-redactor.cjs');
const { matchesAny } = require('./git-flow-config.cjs');

const SECRET_PATTERNS = [
  // First, so a token inside a URL is reported as the URL credential it is. Non-global copy: a global
  // regex keeps lastIndex between .test calls and would skip lines.
  { name: 'credential in URL', re: new RegExp(CREDENTIAL_URL_SOURCE) },
  { name: 'private key', re: /-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----/ },
  { name: 'AWS access key', re: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { name: 'GitHub token', re: /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})\b/ },
  { name: 'Slack token', re: /\bxox[abposr]-[A-Za-z0-9-]{10,}/ },
  { name: 'Stripe live key', re: /\b[sr]k_live_[A-Za-z0-9]{20,}\b/ },
  { name: 'Google API key', re: /\bAIza[0-9A-Za-z_-]{35}\b/ },
  { name: 'Anthropic API key', re: /\bsk-ant-[A-Za-z0-9_-]{20,}/ },
  { name: 'OpenAI API key', re: /\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}/ },
  { name: 'npm token', re: /\bnpm_[A-Za-z0-9]{36}\b/ },
];

// A line containing this marker is skipped (test fixtures, documented fake keys)
const ALLOW_MARKER = 'adf-allow-secret';

const ENV_TEMPLATE = /^\.env(?:\.[\w-]+)*\.(?:example|sample|template|dist|defaults)$/i;
const SECRET_BASENAMES = new Set(['id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', 'secrets.yml', 'secrets.yaml']);
const SECRET_EXTENSIONS = new Set(['.pem', '.key', '.p12', '.pfx']);

const MAX_FILE_BYTES = 1024 * 1024;
// Untracked files are read (the first MAX_FILE_BYTES of each) until this many bytes are spent; later ones are reported as not scanned
const UNTRACKED_BYTE_BUDGET = 256 * 1024 * 1024;
// One git cat-file process holds at most about this many bytes of blobs, and each chunk is scanned and dropped
// before the next is read, so memory does not grow with the number of staged binaries (1200 staged 1 MB
// binaries peaked at about 245 MB resident with 16 MB chunks, 334 MB with 32 MB)
const BATCH_BYTE_BUDGET = 16 * 1024 * 1024;
// What a --batch header and its separators add to each blob
const BATCH_ENTRY_OVERHEAD = 128;

function isSecretFile(file) {
  const base = path.basename(file);
  if (ENV_TEMPLATE.test(base)) return false;
  if (base === '.env' || base.startsWith('.env.')) return true;
  return SECRET_BASENAMES.has(base) || SECRET_EXTENSIONS.has(path.extname(base).toLowerCase());
}

function matchLine(line) {
  if (line.includes(ALLOW_MARKER)) return null;
  const hit = SECRET_PATTERNS.find(({ re }) => re.test(line));
  return hit ? hit.name : null;
}

const C_ESCAPES = { a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13, '"': 34, '\\': 92 };

/**
 * The C-quoted name git prints for a path holding `"`, `\` or a control character (even with core.quotePath=false),
 * starting at `text[start]` (the opening quote). Returns the name and the index after the closing quote, or null.
 */
function readQuoted(text, start) {
  const bytes = [];
  for (let i = start + 1; i < text.length; i++) {
    const ch = text[i];
    if (ch === '"') return { name: Buffer.from(bytes).toString('utf8'), end: i + 1 };
    if (ch !== '\\') { bytes.push(...Buffer.from(ch, 'utf8')); continue; }
    const next = text[++i];
    const octal = /^[0-3][0-7]{2}/.exec(text.slice(i, i + 3));
    if (octal) { bytes.push(parseInt(octal[0], 8)); i += 2; } else if (next in C_ESCAPES) bytes.push(C_ESCAPES[next]); else return null;
  }
  return null;
}

/** The path after a `b/` prefix in a diff header, quoted or not; null for another prefix (`/dev/null`). */
function newSideName(text) {
  if (text.startsWith('"')) {
    const quoted = readQuoted(text, 0);
    return quoted && quoted.name.startsWith('b/') ? quoted.name.slice(2) : null;
  }
  return text.startsWith('b/') ? text.slice(2).replace(/\t$/, '') : null; // git appends a tab to names with spaces
}

/** Findings from a unified diff (`git diff -U0`): added lines only. */
function scanDiff(diff) {
  const findings = [];
  let file = null;
  let lineNo = 0;
  let inHeader = false;
  for (const line of diff.split('\n')) {
    if (line.startsWith('diff --git ')) { inHeader = true; file = null; continue; }
    if (inHeader) {
      // Header lines until the first hunk; "+++ b/<path>" names the new file
      if (line.startsWith('+++ ')) file = newSideName(line.slice(4));
      if (!line.startsWith('@@')) continue;
      inHeader = false;
    }
    const hunk = /^@@ -\d+(?:,\d+)? \+(\d+)/.exec(line);
    if (hunk) { lineNo = Number(hunk[1]); continue; }
    if (!file) continue;
    if (line.startsWith('+')) {
      const rule = matchLine(line.slice(1));
      if (rule) findings.push({ file, line: lineNo, rule });
      lineNo++;
    }
  }
  return findings;
}

function scanFileContent(file, content) {
  if (content.includes('\0')) return []; // binary
  const findings = [];
  content.split('\n').forEach((line, i) => {
    const rule = matchLine(line);
    if (rule) findings.push({ file, line: i + 1, rule });
  });
  return findings;
}

// Variables that change how git reads a pathspec. The scanner's own pathspecs must mean what they say
// whatever the shell that started git set (git --literal-pathspecs exports GIT_LITERAL_PATHSPECS to hooks).
const PATHSPEC_ENV = ['GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS'];

function gitEnv() {
  const env = { ...process.env };
  for (const key of PATHSPEC_ENV) delete env[key];
  return env;
}

function git(args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'], env: gitEnv() });
}

/** Why a scan threw, in words for the person reading the refusal. */
function scanFailureCause(err) {
  if (err && err.code === 'ENOBUFS') return 'the staged text changes are larger than the scanner can read at once (32 MB)';
  const message = String((err && err.message) || err).split('\n')[0];
  return `git failed (${message.length > 200 ? `${message.slice(0, 200)}...` : message})`;
}

function hasHead(cwd) {
  try { git(['rev-parse', '--verify', '--quiet', 'HEAD'], cwd); return true; } catch { return false; }
}

const DIFF_FILTER = '--diff-filter=ACMRT';
// Fixed prefixes and unquoted paths whatever the user's diff.noprefix / mnemonicPrefix / quotePath settings; staged
// bytes, not a textconv driver's output (a driver can print nothing, or fail on a clean file); a submodule bump as its
// commit ids whatever diff.submodule says (`log` prints no header, `diff` prints the submodule's own history)
const DIFF_FLAGS = ['-U0', '--no-color', '--no-ext-diff', '--no-textconv', '--submodule=short', DIFF_FILTER, '--src-prefix=a/', '--dst-prefix=b/'];
// diff.relative=false: names are always relative to the top level, whatever directory the scan runs in
const gitq = (args, cwd) => git(['-c', 'core.quotePath=false', '-c', 'diff.relative=false', ...args], cwd);
const splitZ = (out) => out.split('\0').filter(Boolean);

/**
 * Names git reports as binary in `git diff --numstat -z` output (counts `-`): real binaries and
 * files a .gitattributes `-diff` marks. Their diff holds no lines, so they are scanned from content.
 */
function binaryNames(numstat) {
  const parts = numstat.split('\0');
  const names = [];
  for (let i = 0; i < parts.length; i++) {
    const m = /^(\d+|-)\t(\d+|-)\t([\s\S]*)$/.exec(parts[i]);
    if (!m) continue;
    let name = m[3];
    if (name === '') { name = parts[i + 2]; i += 2; } // rename or copy: "<counts>\t", old name, new name
    if (m[1] === '-' && m[2] === '-' && name) names.push(name);
  }
  return names;
}

/** The names that have a `diff --git a/<old> b/<new>` section in a diff, empty files and mode changes included. */
function headerNames(diff) {
  const names = new Set();
  for (const line of diff.split('\n')) {
    if (!line.startsWith('diff --git ')) continue;
    const rest = line.slice('diff --git '.length);
    if (rest.startsWith('"') || rest.endsWith('"')) {
      // A quoted name on either side (a rename can quote only one); a plain name holds no '"'
      const old = rest.startsWith('"') ? readQuoted(rest, 0) : { end: rest.indexOf(' "b/') };
      const name = old && old.end > 0 ? newSideName(rest.slice(old.end + 1)) : null;
      if (name !== null) names.add(name);
      continue;
    }
    if (!rest.startsWith('a/')) continue;
    // A name may hold " b/" itself, so every split point is a candidate
    for (let i = rest.indexOf(' b/'); i !== -1; i = rest.indexOf(' b/', i + 1)) names.add(rest.slice(i + 3));
  }
  return names;
}

const CAT_FILE_OPTIONS = { maxBuffer: 32 * 1024 * 1024, stdio: ['pipe', 'pipe', 'ignore'] };

/** Text of a head to scan: '' for content with a NUL byte (binary, nothing to scan), checked before any decoding. */
const headText = (buffer) => (buffer.includes(0) ? '' : buffer.toString('utf8'));

/**
 * The first MAX_FILE_BYTES of one staged blob, or null when git cannot read it. An over-long blob
 * ends the read with ENOBUFS and keeps what arrived, so a 40 MB file costs 1 MB.
 * @returns {Buffer|null}
 */
function readStagedHead(cwd, name) {
  const r = spawnSync('git', ['cat-file', 'blob', `:0:${name}`], { cwd, env: gitEnv(), maxBuffer: MAX_FILE_BYTES, stdio: ['ignore', 'pipe', 'ignore'] });
  const cutShort = r.error && r.error.code === 'ENOBUFS';
  if (r.error && !cutShort) return null;
  if (!cutShort && r.status !== 0) return null;
  return r.stdout;
}

/** Splits {name, size} entries into runs whose sizes fit the budget; a run holds at least one entry. */
function chunkByBytes(entries, budget = BATCH_BYTE_BUDGET) {
  const chunks = [];
  let current = [];
  let bytes = 0;
  for (const entry of entries) {
    const cost = entry.size + BATCH_ENTRY_OVERHEAD;
    if (current.length && bytes + cost > budget) { chunks.push(current); current = []; bytes = 0; }
    current.push(entry);
    bytes += cost;
  }
  if (current.length) chunks.push(current);
  return chunks;
}

/** One `git cat-file --batch` over the entries of a chunk; calls `visit(name, text|null)` for each, in order. */
function readBatch(cwd, chunk, visit) {
  const total = chunk.reduce((sum, { size }) => sum + size + BATCH_ENTRY_OVERHEAD, 0) + 1024;
  const input = `${chunk.map(({ name }) => `:0:${name}`).join('\n')}\n`;
  const batch = spawnSync('git', ['cat-file', '--batch'], { cwd, env: gitEnv(), input, ...CAT_FILE_OPTIONS, maxBuffer: total });
  let pos = 0;
  let inStep = !batch.error && batch.status === 0;
  for (const { name, size } of chunk) {
    const end = inStep ? batch.stdout.indexOf(0x0a, pos) : -1;
    const header = end === -1 ? null : /^[0-9a-f]{40,64} blob (\d+)$/.exec(batch.stdout.toString('latin1', pos, end));
    if (!header || Number(header[1]) !== size) inStep = false; // out of step: the rest of the chunk is reported
    if (!inStep) { visit(name, null); continue; }
    visit(name, headText(batch.stdout.subarray(end + 1, end + 1 + size)));
    pos = end + 1 + size + 1;
  }
}

/**
 * Hands the first MAX_FILE_BYTES of each staged blob to `visit(name, text|null)`, one blob at a time, so
 * nothing but the chunk being read is held: one git process for the sizes, then the blobs that fit in
 * chunks of BATCH_BYTE_BUDGET; a larger blob is read on its own. `text` is '' for content with a NUL
 * byte and null when git cannot read the blob (or the name has a newline, which the line-based batch
 * protocol would misread).
 */
function visitStagedHeads(cwd, names, visit) {
  const listable = names.filter((name) => !name.includes('\n'));
  names.filter((name) => name.includes('\n')).forEach((name) => visit(name, null));
  if (!listable.length) return;
  const input = `${listable.map((name) => `:0:${name}`).join('\n')}\n`;
  const check = spawnSync('git', ['cat-file', '--batch-check'], { cwd, env: gitEnv(), input, ...CAT_FILE_OPTIONS });
  const sizes = check.error || check.status !== 0 ? [] : check.stdout.toString('utf8').split('\n').map((line) => {
    const m = /^[0-9a-f]{40,64} blob (\d+)$/.exec(line);
    return m ? Number(m[1]) : null;
  });
  const small = [];
  listable.forEach((name, i) => {
    if (sizes[i] === undefined || sizes[i] === null) { visit(name, null); return; }
    if (sizes[i] > MAX_FILE_BYTES) {
      const head = readStagedHead(cwd, name);
      visit(name, head === null ? null : headText(head));
    } else small.push({ name, size: sizes[i] });
  });
  for (const chunk of chunkByBytes(small)) readBatch(cwd, chunk, visit);
}

/**
 * The first MAX_FILE_BYTES of a work-tree file (a regular file only), or null when it is not one or cannot be
 * read. Unlike a whole-file read, a larger file is scanned as far as the cap, never skipped.
 */
function readFileHead(file) {
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) return null;
    const length = Math.min(stat.size, MAX_FILE_BYTES);
    const buffer = Buffer.alloc(length);
    const read = length ? fs.readSync(fd, buffer, 0, length, 0) : 0;
    return buffer.toString('utf8', 0, read);
  } catch { return null; } finally { if (fd !== undefined) try { fs.closeSync(fd); } catch { /* closed */ } }
}

/**
 * Scan what the commit will contain. PreToolUse runs before anything in the command is
 * staged, so `scope` describes what the command itself will add:
 * @param {string} cwd
 * @param {{ tracked?: 'cached'|'head', paths?: string[]|null, untracked?: boolean, ignored?: boolean, allowFiles?: string[] }} scope
 *   tracked: 'cached' = staged changes only; 'head' = also unstaged tracked changes (commit -a, add -u/-A)
 *   paths: pathspecs from `git add <paths>`; the wider scan is limited to them (staged changes always count)
 *   untracked: include untracked, non-ignored files (`git add .`, `-A`, explicit paths)
 *   ignored: also include ignored files (`git add -f`)
 *   allowFiles: globs of files to skip, names and lines (commitGuard.allowSecretFiles)
 *   untrackedByteBudget: bytes of untracked files to read before the rest are reported as not scanned
 * @returns {{ files: string[], findings: Array<{file: string, line: number, rule: string}>, unscanned: string[] }}
 *   unscanned: changed names that neither the diff nor their content covered; the caller must not treat them as clean
 */
function scanCommit(cwd, { tracked = 'cached', paths = null, untracked = false, ignored = false, allowFiles = [], untrackedByteBudget = UNTRACKED_BYTE_BUDGET } = {}) {
  const top = git(['rev-parse', '--show-toplevel'], cwd).trim();
  // Without user pathspecs every call runs at the top level with no pathspec, which covers the whole tree
  // whatever directory the commit runs in. User pathspecs (`git add <paths>`) are read from `cwd`.
  const limited = paths && paths.length > 0;
  const spec = limited ? ['--', ...paths] : [];
  const specDir = limited ? cwd : top;
  const ranges = [{ base: '--cached', spec: [], dir: top }];
  if (tracked === 'head' && hasHead(cwd)) ranges.push({ base: 'HEAD', spec, dir: specDir });
  const allowed = allowFiles.length ? (file) => matchesAny(file, allowFiles) : () => false;

  const names = new Set();
  const unscanned = new Set();
  const seen = new Set();
  const findings = [];
  const add = (list) => {
    for (const f of list) {
      const key = `${f.file}:${f.line}:${f.rule}`;
      if (!allowed(f.file) && !seen.has(key)) { seen.add(key); findings.push(f); }
    }
  };
  for (const { base, spec: rangeSpec, dir } of ranges) {
    const rangeNames = splitZ(gitq(['diff', base, '--name-only', '-z', DIFF_FILTER, ...rangeSpec], dir));
    const binary = new Set(binaryNames(gitq(['diff', base, '--numstat', '--no-textconv', '-z', DIFF_FILTER, ...rangeSpec], dir)));
    const diff = gitq(['diff', base, ...DIFF_FLAGS, ...rangeSpec], dir);
    add(scanDiff(diff));
    const covered = headerNames(diff);
    const scanContent = (name, text) => { if (text !== null) add(scanFileContent(name, text)); else unscanned.add(name); };
    // Staged binaries are read in one pass that keeps no content; names the loop below sees are the others
    const fromBlob = base === '--cached' ? rangeNames.filter((name) => binary.has(name) && !allowed(name)) : [];
    visitStagedHeads(cwd, fromBlob, scanContent);
    for (const name of rangeNames) {
      names.add(name);
      if (allowed(name)) continue;
      if (binary.has(name)) {
        if (base !== '--cached') scanContent(name, readFileHead(path.join(top, name)));
      } else if (!covered.has(name)) {
        unscanned.add(name);
      }
    }
  }

  if (untracked) {
    const exclude = ignored ? [] : ['--exclude-standard'];
    const files = splitZ(gitq(['ls-files', '--others', ...exclude, '--full-name', '-z', ...spec], specDir));
    files.forEach((file) => names.add(file));
    let spent = 0;
    for (const file of files) {
      if (allowed(file)) continue;
      const full = path.join(top, file);
      let stat = null;
      try { stat = fs.lstatSync(full); } catch { /* gone since the listing: nothing to commit */ }
      // A symlink commits its target's name, a socket or directory no content: only a regular file holds lines
      if (!stat || !stat.isFile()) continue;
      spent += Math.min(stat.size, MAX_FILE_BYTES);
      if (spent > untrackedByteBudget) { unscanned.add(file); continue; }
      const text = readFileHead(full);
      if (text !== null) add(scanFileContent(file, text)); else unscanned.add(file);
    }
  }
  return { files: [...names].filter((name) => isSecretFile(name) && !allowed(name)), findings, unscanned: [...unscanned] };
}

module.exports = { scanCommit, scanDiff, scanFileContent, isSecretFile, matchLine, binaryNames, chunkByBytes, scanFailureCause, ALLOW_MARKER };
