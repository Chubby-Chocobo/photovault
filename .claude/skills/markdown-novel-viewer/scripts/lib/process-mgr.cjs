/**
 * Process manager - handles PID files and server lifecycle
 * Used by markdown-novel-viewer server
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const PID_PREFIX = 'md-novel-viewer-';
const PID_DIR_NAME = `md-novel-viewer-${typeof process.getuid === 'function' ? process.getuid() : 'user'}`;

/**
 * Per-user PID directory under the OS temp dir (never a shared, predictable path).
 * Created owner-only; refuses a symlink or a directory owned by someone else.
 * @param {boolean} create - Create the directory when missing
 * @returns {string|null} - Directory path, or null when absent and not creating
 */
function getPidDir(create) {
  const dir = path.join(os.tmpdir(), PID_DIR_NAME);
  if (create) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  let stat;
  try {
    stat = fs.lstatSync(dir);
  } catch (err) {
    if (err.code === 'ENOENT') return null;
    throw err;
  }
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error(`PID directory ${dir} is not a plain directory`);
  }
  if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
    throw new Error(`PID directory ${dir} is owned by another user`);
  }
  return dir;
}

/**
 * Get PID file path for a port
 * @param {number} port - Server port
 * @returns {string} - PID file path
 */
function getPidFilePath(port) {
  return path.join(path.join(os.tmpdir(), PID_DIR_NAME), `${PID_PREFIX}${port}.pid`);
}

/**
 * Write PID file for running server
 * @param {number} port - Server port
 * @param {number} pid - Process ID
 */
function writePidFile(port, pid) {
  getPidDir(true);
  const pidPath = getPidFilePath(port);
  // Replace any stale file; 'wx' never follows a planted symlink
  fs.rmSync(pidPath, { force: true });
  fs.writeFileSync(pidPath, String(pid), { flag: 'wx', mode: 0o600 });
}

/**
 * Read PID from file
 * @param {number} port - Server port
 * @returns {number|null} - PID or null if not found
 */
function readPidFile(port) {
  if (!getPidDir(false)) return null;
  const pidPath = getPidFilePath(port);
  if (fs.existsSync(pidPath)) {
    const pid = parseInt(fs.readFileSync(pidPath, 'utf8').trim(), 10);
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  }
  return null;
}

/**
 * Remove PID file
 * @param {number} port - Server port
 */
function removePidFile(port) {
  if (!getPidDir(false)) return;
  fs.rmSync(getPidFilePath(port), { force: true });
}

/**
 * Find all running server instances
 * @returns {Array<{port: number, pid: number}>} - Running instances
 */
function findRunningInstances() {
  const instances = [];
  const pidDir = getPidDir(false);
  if (!pidDir) return instances;
  const files = fs.readdirSync(pidDir);

  for (const file of files) {
    if (file.startsWith(PID_PREFIX) && file.endsWith('.pid')) {
      const port = parseInt(file.replace(PID_PREFIX, '').replace('.pid', ''), 10);
      const pid = readPidFile(port);
      if (pid) {
        // Check if process is actually running
        try {
          process.kill(pid, 0);
          instances.push({ port, pid });
        } catch {
          // Process not running, clean up stale PID file
          removePidFile(port);
        }
      }
    }
  }

  return instances;
}

/**
 * Stop server by port
 * @param {number} port - Server port
 * @returns {boolean} - True if stopped successfully
 */
function stopServer(port) {
  const pid = readPidFile(port);
  if (!pid) return false;

  try {
    process.kill(pid, 'SIGTERM');
    removePidFile(port);
    return true;
  } catch {
    removePidFile(port);
    return false;
  }
}

/**
 * Stop all running servers
 * @returns {number} - Number of servers stopped
 */
function stopAllServers() {
  const instances = findRunningInstances();
  let stopped = 0;

  for (const { port, pid } of instances) {
    try {
      process.kill(pid, 'SIGTERM');
      removePidFile(port);
      stopped++;
    } catch {
      removePidFile(port);
    }
  }

  return stopped;
}

/**
 * Setup graceful shutdown handlers
 * @param {number} port - Server port
 * @param {Function} cleanup - Additional cleanup function
 */
function setupShutdownHandlers(port, cleanup) {
  const handler = (signal) => {
    if (cleanup) cleanup();
    removePidFile(port);
    process.exit(0);
  };

  process.on('SIGTERM', handler);
  process.on('SIGINT', handler);
}

module.exports = {
  getPidDir,
  getPidFilePath,
  writePidFile,
  readPidFile,
  removePidFile,
  findRunningInstances,
  stopServer,
  stopAllServers,
  setupShutdownHandlers,
  PID_PREFIX
};
