/**
 * Shared request guards for the local preview/dashboard HTTP servers.
 *
 * - Path containment by whole path segment, after resolving symlinks
 * - Dotfiles / dot-directories refused below an allowed directory
 * - Host header validation (DNS-rebinding defence) when bound to loopback
 *
 * Also used by the plans-kanban skill (it already depends on this skill).
 */

const fs = require('fs');
const path = require('path');

const LOOPBACK_HOSTNAMES = new Set(['localhost', '127.0.0.1', '::1']);
const WILDCARD_HOSTS = new Set(['0.0.0.0', '::', '']);

/** True when the bind address only accepts connections from this machine. */
function isLoopbackBind(host) {
  if (!host) return false;
  const h = String(host).replace(/^\[|\]$/g, '').toLowerCase();
  return LOOPBACK_HOSTNAMES.has(h) || /^127\.\d+\.\d+\.\d+$/.test(h);
}

/** True for wildcard bind addresses (all interfaces). */
function isWildcardBind(host) {
  return WILDCARD_HOSTS.has(String(host || '').replace(/^\[|\]$/g, ''));
}

/** Warning text for a non-loopback bind, or null when the bind is loopback. */
function nonLoopbackWarning(host) {
  if (isLoopbackBind(host)) return null;
  return `WARNING: binding to "${host}" exposes this server (and the files it serves) to other machines on your network. ` +
    'There is no authentication. Use only on trusted networks; omit --host to stay on 127.0.0.1.';
}

/**
 * Validate the Host header. Only enforced when bound to loopback; an explicit
 * non-loopback bind is a user opt-in and cannot know its own hostnames.
 * @returns {boolean} true if the request may proceed
 */
function isHostHeaderAllowed(hostHeader, bindHost) {
  if (!isLoopbackBind(bindHost)) return true;
  if (typeof hostHeader !== 'string' || !hostHeader) return false;
  let hostname;
  const m = hostHeader.match(/^\[([^\]]+)\](?::\d+)?$/); // [::1]:port
  if (m) {
    hostname = m[1];
  } else {
    const parts = hostHeader.split(':');
    if (parts.length > 2) return false; // bare IPv6 without brackets is not a valid Host
    if (parts.length === 2 && !/^\d+$/.test(parts[1])) return false;
    hostname = parts[0];
  }
  return LOOPBACK_HOSTNAMES.has(hostname.toLowerCase());
}

/** realpath that tolerates a not-yet-existing tail by resolving the deepest existing ancestor. */
function realpathLoose(p) {
  const resolved = path.resolve(p);
  const tail = [];
  let cur = resolved;
  for (;;) {
    try {
      const real = fs.realpathSync(cur);
      return tail.length ? path.join(real, ...tail.reverse()) : real;
    } catch (_) {
      const parent = path.dirname(cur);
      if (parent === cur) return resolved;
      tail.push(path.basename(cur));
      cur = parent;
    }
  }
}

function isInside(child, dir) {
  return child === dir || child.startsWith(dir.endsWith(path.sep) ? dir : dir + path.sep);
}

/**
 * Check that filePath is inside one of allowedDirs (or equals one of allowedFiles).
 * Symlinks are resolved on both sides. Below an allowed directory, any path
 * segment starting with "." is refused (.env, .git, ...). The allowed dir itself
 * may live under a dot-directory (e.g. .claude/skills/x/assets).
 * @param {string} filePath
 * @param {string[]} allowedDirs
 * @param {string[]} [allowedFiles]
 * @returns {boolean}
 */
function isPathAllowed(filePath, allowedDirs, allowedFiles = []) {
  if (typeof filePath !== 'string' || !filePath || filePath.includes('\0')) return false;
  const real = realpathLoose(filePath);

  for (const f of allowedFiles) {
    if (real === realpathLoose(f)) return true;
  }
  for (const d of allowedDirs) {
    const realDir = realpathLoose(d);
    if (!isInside(real, realDir)) continue;
    const rel = path.relative(realDir, real);
    if (rel.split(path.sep).some(seg => seg.startsWith('.') && seg !== '')) continue;
    return true;
  }
  return false;
}

module.exports = {
  isLoopbackBind,
  isWildcardBind,
  nonLoopbackWarning,
  isHostHeaderAllowed,
  isPathAllowed,
  realpathLoose
};
