/**
 * git-remote-url.cjs - The single git remote URL parser for hooks and skill scripts.
 *
 * Understands https, git+https, ssh://, git://, scp-style (git@host:owner/repo) and the
 * github:/gitlab:/bitbucket: shorthands. Local paths and file:// URLs are not remotes and
 * parse to null. Credentials never survive a parse: callers get host and path only.
 *
 * @module git-remote-url
 */

'use strict';

const { execFileSync } = require('child_process');

const SCHEME_RE = /^(?:git\+)?(https?|ssh|git):\/\//i;
const SHORTHAND_HOSTS = { github: 'github.com', gitlab: 'gitlab.com', bitbucket: 'bitbucket.org' };
const SHORTHAND_RE = /^(github|gitlab|bitbucket):(?!\/\/)([^\s]+)$/i;
const SCP_RE = /^(?:[^@/\s]+@)?([^:/\s]+):(?!\/\/)(.+)$/;
const HOST_RE = /^[a-z0-9][a-z0-9.-]*$/;
const SEGMENT_RE = /^[A-Za-z0-9._~-]+$/;

/**
 * Validate and normalize a repo path ("/o/r.git" -> "o/r"). Needs at least owner and repo.
 * @param {string} raw
 * @returns {string|null}
 */
function cleanPath(raw) {
  const segments = raw.replace(/[#?].*$/, '').replace(/^\/+|\/+$/g, '').replace(/\.git$/, '').split('/');
  if (segments.length < 2) return null;
  for (const seg of segments) {
    if (seg === '.' || seg === '..' || !SEGMENT_RE.test(seg)) return null;
  }
  return segments.join('/');
}

/**
 * Split a remote URL into its parts, or null when it is not a remote git URL.
 * @param {string} url
 * @returns {{ form: 'https'|'ssh'|'scp'|'shorthand', scheme: string, host: string, port: string|null, path: string }|null}
 */
function splitUrl(url) {
  if (typeof url !== 'string') return null;
  const text = url.trim();
  if (!text || /[\s\0]/.test(text)) return null;

  const shorthand = SHORTHAND_RE.exec(text);
  if (shorthand) {
    const repoPath = cleanPath(shorthand[2]);
    return repoPath ? { form: 'shorthand', scheme: 'https', host: SHORTHAND_HOSTS[shorthand[1].toLowerCase()], port: null, path: repoPath } : null;
  }

  const scheme = SCHEME_RE.exec(text);
  if (scheme) {
    const rest = text.slice(scheme[0].length);
    const slash = rest.indexOf('/');
    if (slash < 0) return null;
    const authority = rest.slice(0, slash);
    const hostPort = authority.slice(authority.lastIndexOf('@') + 1);
    const match = /^([^:]+)(?::(\d+))?$/.exec(hostPort);
    if (!match) return null;
    const host = match[1].toLowerCase();
    const repoPath = cleanPath(rest.slice(slash));
    if (!HOST_RE.test(host) || !repoPath) return null;
    const base = scheme[1].toLowerCase();
    return { form: base === 'ssh' ? 'ssh' : 'https', scheme: base, host, port: match[2] || null, path: repoPath };
  }

  // A scheme-less string is scp-style only when it is not a filesystem path
  if (/^(?:[./~]|[A-Za-z]:[\\/])/.test(text) || /^file:/i.test(text)) return null;
  const scp = SCP_RE.exec(text);
  if (!scp) return null;
  const host = scp[1].toLowerCase();
  const repoPath = cleanPath(scp[2]);
  if (host.length < 2 || !HOST_RE.test(host) || !repoPath) return null;
  return { form: 'scp', scheme: 'ssh', host, port: null, path: repoPath };
}

/**
 * Parse a remote URL.
 * @param {string} url
 * @returns {{ host: string, owner: string, repo: string, path: string }|null} path is the full repo path without .git
 */
function parseRemoteUrl(url) {
  const parts = splitUrl(url);
  if (!parts) return null;
  const segments = parts.path.split('/');
  return { host: parts.host, owner: segments[0], repo: segments[segments.length - 1], path: parts.path };
}

/**
 * @param {string} url
 * @returns {string|null} https://host/<path>, or null when url is not a remote
 */
function canonicalUrl(url) {
  const parsed = parseRemoteUrl(url);
  return parsed ? `https://${parsed.host}/${parsed.path}` : null;
}

/**
 * Remove credentials. Userinfo is dropped from http(s) URLs; for ssh:// only a password is
 * dropped, because the user name (git@) is part of how ssh connects. scp-style is untouched.
 * @param {string} url
 * @returns {string}
 */
function stripCredentials(url) {
  if (typeof url !== 'string') return url;
  const match = /^((?:git\+)?(https?|ssh|git):\/\/)([^/]*)(.*)$/is.exec(url);
  if (!match) return url;
  const [, prefix, scheme, authority, rest] = match;
  const at = authority.lastIndexOf('@');
  if (at < 0) return url;
  const hostPort = authority.slice(at + 1);
  if (scheme.toLowerCase() !== 'ssh') return `${prefix}${hostPort}${rest}`;
  const user = authority.slice(0, at).split(':')[0];
  return `${prefix}${user ? `${user}@` : ''}${hostPort}${rest}`;
}

/**
 * @param {string} a
 * @param {string} b
 * @returns {boolean} same host (case-insensitive) and repo path, ignoring protocol, credentials and .git
 */
function sameRepo(a, b) {
  const left = parseRemoteUrl(a);
  const right = parseRemoteUrl(b);
  return Boolean(left && right && left.host === right.host && left.path === right.path);
}

/**
 * @param {string} url
 * @returns {string|null} The first path segment (GitLab group, GitHub owner)
 */
function ownerOf(url) {
  const parsed = parseRemoteUrl(url);
  return parsed ? parsed.owner : null;
}

/**
 * Rewrite a remote to the other protocol, keeping host and full path.
 * Returns null when the URL cannot be rewritten safely (local path, file://, a non-default
 * port), so callers fall back to the URL as written.
 * @param {string} url
 * @param {'ssh'|'https'} protocol
 * @returns {string|null}
 */
function toProtocol(url, protocol) {
  const parts = splitUrl(url);
  if (!parts || parts.port || (protocol !== 'ssh' && protocol !== 'https')) return null;
  const text = url.trim();
  if (protocol === 'ssh') {
    return parts.form === 'scp' || /^ssh:\/\//i.test(text) ? stripCredentials(text) : `git@${parts.host}:${parts.path}.git`;
  }
  return /^https:\/\//i.test(text) ? stripCredentials(text) : `https://${parts.host}/${parts.path}`;
}

/**
 * Raw `remote.origin.url` of the repo at `dir` (it may hold credentials: strip before printing).
 * One local git call, no prompt, no shell; never throws.
 * @param {string} dir
 * @param {{ timeoutMs?: number }} [opts]
 * @returns {string|null} null when there is no origin, `dir` is not a repo or git does not answer in time
 */
function originUrl(dir, { timeoutMs = 2000 } = {}) {
  try {
    const out = execFileSync('git', ['-C', dir, 'config', '--get', 'remote.origin.url'], {
      encoding: 'utf8', timeout: timeoutMs, windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'],
      env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
    }).trim();
    return out || null;
  } catch { return null; }
}

module.exports = { parseRemoteUrl, canonicalUrl, stripCredentials, sameRepo, ownerOf, toProtocol, originUrl };
