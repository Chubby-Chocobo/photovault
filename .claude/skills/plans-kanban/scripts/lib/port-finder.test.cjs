/**
 * Port finder: must skip a port already held on 127.0.0.1 and honour explicit ports
 * outside the default auto-search range.
 */
const test = require('node:test');
const assert = require('node:assert');
const net = require('net');

const { findAvailablePort, isPortAvailable } = require('./port-finder.cjs');

function listenLoopback(port) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

test('finder skips a port already served on 127.0.0.1', async () => {
  const holder = await listenLoopback(0);
  const taken = holder.address().port;
  try {
    assert.strictEqual(await isPortAvailable(taken, '127.0.0.1'), false);
    assert.strictEqual(await isPortAvailable(taken, '0.0.0.0'), false);
    const found = await findAvailablePort(taken, '127.0.0.1');
    assert.notStrictEqual(found, taken);
    assert.ok(found > taken);
  } finally {
    holder.close();
  }
});

test('explicit port above the default range is honoured', async () => {
  const start = 41000 + Math.floor(Math.random() * 2000);
  const found = await findAvailablePort(start, '127.0.0.1');
  assert.ok(found >= start && found <= start + 60);
});
