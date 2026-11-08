/**
 * Open a URL in the default browser. Failures are ignored: the URL is also printed.
 */
const { execSync } = require('child_process');

function openBrowserCommand(platform, url) {
  if (platform === 'darwin') return `open "${url}"`;
  // `start` takes the first quoted argument as the window title, so pass an empty one first.
  if (platform === 'win32') return `start "" "${url}"`;
  return `xdg-open "${url}"`;
}

function openBrowser(url) {
  try {
    execSync(openBrowserCommand(process.platform, url), { stdio: 'ignore' });
  } catch {
    // Ignore browser open errors
  }
}

module.exports = { openBrowser, openBrowserCommand };
