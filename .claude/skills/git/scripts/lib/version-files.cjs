'use strict';

// Reads and writes the version in the files listed in git.versionFiles: JSON files by dot path, other
// files by a regex whose first group is the version. package-lock.json also gets packages[""].version.

const fs = require('fs');
const path = require('path');

/** Manifests to suggest when the default package.json is missing. */
const KNOWN_MANIFESTS = [
  { path: 'pyproject.toml', regex: '^version\\s*=\\s*"([^"]+)"' },
  { path: 'Cargo.toml', regex: '^version\\s*=\\s*"([^"]+)"' },
  { path: 'build.gradle.kts', regex: '^version\\s*=\\s*"([^"]+)"' },
  { path: 'build.gradle', regex: "^version\\s*=\\s*['\"]([^'\"]+)['\"]" },
  { path: 'pom.xml', regex: '<version>([^<]+)</version>' },
  { path: 'pubspec.yaml', regex: '^version:\\s*([^\\s+]+)' },
];

function getPath(obj, dotted) {
  return dotted.split('.').reduce((o, k) => (o && typeof o === 'object' ? o[k] : undefined), obj);
}

function setPath(obj, dotted, value) {
  const keys = dotted.split('.');
  let o = obj;
  for (const k of keys.slice(0, -1)) {
    if (!o[k] || typeof o[k] !== 'object') o[k] = {};
    o = o[k];
  }
  o[keys.at(-1)] = value;
}

/** The version in one file's text, or null. */
function readVersionFromText(entry, text) {
  if (text == null) return null;
  if (entry.json) {
    try { const v = getPath(JSON.parse(text), entry.json); return typeof v === 'string' ? v : null; } catch { return null; }
  }
  const m = new RegExp(entry.regex, 'm').exec(text);
  return m ? m[1] : null;
}

const escape = (v) => v.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * JSON: replaces only the version value(s) in the text, keeping the file's formatting, and checks the
 * result parses to exactly the intended object; if not, the file is re-serialized.
 */
function writeJsonVersion(entry, text, version) {
  const data = JSON.parse(text);
  const isLock = path.basename(entry.path) === 'package-lock.json' && data.packages && data.packages[''];
  const old = getPath(data, entry.json);
  setPath(data, entry.json, version);
  if (isLock) data.packages[''].version = version;
  const expected = JSON.stringify(data);
  if (typeof old === 'string') {
    const key = entry.json.split('.').at(-1);
    let count = 0;
    const limit = isLock && data.packages[''] ? 2 : 1;
    const edited = text.replace(new RegExp(`("${escape(key)}"\\s*:\\s*")${escape(old)}"`, 'g'), (m, lead) => (count++ < limit ? `${lead}${version}"` : m));
    try { if (JSON.stringify(JSON.parse(edited)) === expected) return edited; } catch { /* fall through */ }
  }
  const indent = (/^[ \t]+(?=")/m.exec(text) || ['  '])[0];
  return `${JSON.stringify(data, null, indent)}\n`;
}

function writeVersionToText(entry, text, version) {
  if (entry.json) return writeJsonVersion(entry, text, version);
  const re = new RegExp(entry.regex, 'm');
  const m = re.exec(text);
  if (!m) throw new Error(`${entry.path}: the version pattern ${entry.regex} does not match`);
  const start = m.index + m[0].indexOf(m[1]);
  return text.slice(0, start) + version + text.slice(start + m[1].length);
}

/**
 * The files to use. When the project never configured versionFiles and has no package.json, the
 * error names the manifest it found and a ready-to-paste config.
 */
function effectiveVersionFiles(config, root) {
  if (config.versionFilesConfigured || fs.existsSync(path.join(root, 'package.json'))) return config.versionFiles;
  const found = KNOWN_MANIFESTS.filter((m) => fs.existsSync(path.join(root, m.path)));
  for (const name of fs.readdirSync(root).filter((n) => n.endsWith('.csproj'))) found.push({ path: name, regex: '<Version>([^<]+)</Version>' });
  const hint = found.length > 0
    ? `add to .claude/config/adf-config.json: "git": { "versionFiles": ${JSON.stringify(found)} }`
    : 'set "git": { "versionFiles": [...] } in .claude/config/adf-config.json (JSON files take "json": "dot.path", others "regex" with the version as group 1)';
  throw new Error(`no package.json, so ADF does not know where this project keeps its version; ${hint}`);
}

/** [{path, version}] read from the working tree, or through `read(path)` (e.g. from a commit). */
function readVersions(files, read) {
  return files.map((entry) => ({ path: entry.path, version: readVersionFromText(entry, read(entry.path)) }));
}

function writeVersions(files, root, version) {
  const touched = [];
  for (const entry of files) {
    const file = path.join(root, entry.path);
    if (!fs.existsSync(file)) throw new Error(`${entry.path} is listed in git.versionFiles but does not exist`);
    const before = fs.readFileSync(file, 'utf8');
    const after = writeVersionToText(entry, before, version);
    if (after !== before) { fs.writeFileSync(file, after); touched.push(entry.path); }
  }
  return touched;
}

/** Problems when the files do not all hold `version`. */
function checkVersions(found, version) {
  return found.filter((f) => f.version !== version).map((f) => `${f.path} has ${f.version === null ? 'no readable version' : f.version}, expected ${version}`);
}

module.exports = { KNOWN_MANIFESTS, readVersionFromText, writeVersionToText, effectiveVersionFiles, readVersions, writeVersions, checkVersions };
