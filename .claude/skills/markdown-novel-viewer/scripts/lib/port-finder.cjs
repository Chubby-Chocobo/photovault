/**
 * Port finder utility - finds available port in range
 * Used by markdown-novel-viewer server
 */

const net = require('net');

const DEFAULT_PORT = 3456;
const PORT_RANGE_END = 3500;

/**
 * Check whether something already accepts connections on 127.0.0.1:port.
 * On macOS a wildcard listen() can succeed even while a loopback-only server owns the port.
 */
function isPortConnectable(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ port, host: '127.0.0.1' });
    const done = (result) => {
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(500, () => done(false));
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
  });
}

/**
 * Check if a port is available on the host the server will bind to.
 * @param {number} port - Port to check
 * @param {string} [host] - Bind address the server will use (default: 127.0.0.1)
 * @returns {Promise<boolean>} - True if available
 */
async function isPortAvailable(port, host = '127.0.0.1') {
  const bindable = await new Promise((resolve) => {
    const server = net.createServer();
    server.once('error', () => resolve(false));
    server.once('listening', () => {
      server.close(() => resolve(true));
    });
    server.listen(port, host);
  });
  if (!bindable) return false;
  return !(await isPortConnectable(port));
}

/**
 * Find first available port. The search range is DEFAULT_PORT..PORT_RANGE_END; an
 * explicit start port beyond that range is honoured and searched over a window of the same size.
 * @param {number} startPort - Starting port
 * @param {string} [host] - Bind address the server will use (default: 127.0.0.1)
 * @returns {Promise<number>} - Available port
 * @throws {Error} - If no port available in range
 */
async function findAvailablePort(startPort = DEFAULT_PORT, host = '127.0.0.1') {
  const window = PORT_RANGE_END - DEFAULT_PORT;
  const end = Math.min(startPort > PORT_RANGE_END ? startPort + window : PORT_RANGE_END, 65535);
  for (let port = startPort; port <= end; port++) {
    if (await isPortAvailable(port, host)) {
      return port;
    }
  }
  throw new Error(`No available port in range ${startPort}-${end}`);
}

module.exports = {
  isPortAvailable,
  isPortConnectable,
  findAvailablePort,
  DEFAULT_PORT,
  PORT_RANGE_END
};
