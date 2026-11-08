#!/usr/bin/env node

/**
 * Markdown Novel Viewer Server
 * Background HTTP server rendering markdown files with calm, book-like UI
 *
 * Universal viewer - pass ANY path and view it:
 * - Markdown files → novel-reader UI
 * - Directories → file listing browser
 *
 * Usage:
 *   node server.cjs --file ./plan.md [--port 3456] [--no-open] [--stop] [--host <addr>]
 *   node server.cjs --dir ./plans [--port 3456]  # Browse directory
 *
 * Options:
 *   --file <path>   Path to markdown file
 *   --dir <path>    Path to directory (browse mode)
 *   --port <number> Server port (default: 3456, auto-increment if busy)
 *   --host <addr>   Host to bind (default: 127.0.0.1). Non-loopback (e.g. 0.0.0.0) exposes
 *                   served files to the LAN with no auth; prints a warning
 *   --no-open       Disable auto-open browser (opens by default)
 *   --stop          Stop all running servers
 *   --background    Run in background (detached) - legacy mode
 *   --foreground    Run in foreground (for CC background tasks)
 */

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawn, execSync } = require('child_process');

const { findAvailablePort, DEFAULT_PORT } = require('./lib/port-finder.cjs');
const { buildReaderPage, renderHeaderNav, renderBackButton } = require('./lib/page-builder.cjs');
const { writePidFile, stopAllServers, setupShutdownHandlers, findRunningInstances } = require('./lib/process-mgr.cjs');
const { createHttpServer } = require('./lib/http-server.cjs');
const { isWildcardBind, nonLoopbackWarning } = require('./lib/path-guard.cjs');
const { renderMarkdownFile, renderTOCHtml } = require('./lib/markdown-renderer.cjs');
const { generateNavSidebar, generateNavFooter, detectPlan, getNavigationContext } = require('./lib/plan-navigator.cjs');

/**
 * Parse command line arguments
 */
function parseArgs(argv) {
  const args = {
    file: null,
    dir: null,
    port: DEFAULT_PORT,
    host: '127.0.0.1',
    open: true,  // Auto-open browser by default
    stop: false,
    background: false,
    foreground: false,
    isChild: false
  };

  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--file' && argv[i + 1]) {
      args.file = argv[++i];
    } else if (arg === '--dir' && argv[i + 1]) {
      args.dir = argv[++i];
    } else if (arg === '--port' && argv[i + 1]) {
      const value = argv[++i];
      args.port = /^\d+$/.test(value) ? parseInt(value, 10) : NaN;
      if (!(args.port >= 1 && args.port <= 65535)) {
        console.error(`Error: invalid --port "${value}" (expected 1-65535)`);
        process.exit(1);
      }
    } else if (arg === '--host' && argv[i + 1]) {
      args.host = argv[++i];
    } else if (arg === '--open') {
      args.open = true;
    } else if (arg === '--no-open') {
      args.open = false;
    } else if (arg === '--stop') {
      args.stop = true;
    } else if (arg === '--background') {
      args.background = true;
    } else if (arg === '--foreground') {
      args.foreground = true;
    } else if (arg === '--child') {
      args.isChild = true;
    } else if (!arg.startsWith('--') && !args.file && !args.dir) {
      // Positional argument - could be file or directory
      args.file = arg;
    }
  }

  return args;
}

/**
 * Resolve input path - simple logic, no smart detection
 * @param {string} input - Input path
 * @param {string} cwd - Current working directory
 * @returns {{type: 'file'|'directory'|null, path: string|null}}
 */
function resolveInput(input, cwd) {
  if (!input) return { type: null, path: null };

  // Resolve relative to CWD
  const resolved = path.isAbsolute(input) ? input : path.resolve(cwd, input);

  if (!fs.existsSync(resolved)) {
    return { type: null, path: null };
  }

  const stats = fs.statSync(resolved);

  // File mode
  if (stats.isFile()) {
    return { type: 'file', path: resolved };
  }

  // Directory mode - browse, no auto-detection of plan.md
  if (stats.isDirectory()) {
    return { type: 'directory', path: resolved };
  }

  return { type: null, path: null };
}

/**
 * Open browser with URL
 */
function openBrowser(url) {
  const platform = process.platform;
  let cmd;

  if (platform === 'darwin') {
    cmd = `open "${url}"`;
  } else if (platform === 'win32') {
    // On Windows, start command treats first quoted arg as window title
    // Use empty title "" before the URL to prevent this
    cmd = `start "" "${url}"`;
  } else {
    cmd = `xdg-open "${url}"`;
  }

  try {
    execSync(cmd, { stdio: 'ignore' });
  } catch {
    // Ignore browser open errors
  }
}

/**
 * Generate full HTML page from markdown
 */
function generateFullPage(filePath, assetsDir) {
  const { html, toc, frontmatter, title } = renderMarkdownFile(filePath);
  const tocHtml = renderTOCHtml(toc);
  const navSidebar = generateNavSidebar(filePath);
  const navFooter = generateNavFooter(filePath);
  const planInfo = detectPlan(filePath);
  const navContext = getNavigationContext(filePath);

  const parentDir = path.dirname(filePath);
  return buildReaderPage(path.join(assetsDir, 'template.html'), {
    title,
    toc: tocHtml,
    navSidebar,
    navFooter,
    content: html,
    isPlan: planInfo.isPlan,
    frontmatter,
    backButton: renderBackButton(`/browse?dir=${encodeURIComponent(parentDir)}`, 'Back to folder'),
    headerNav: renderHeaderNav(navContext)
  });
}

/**
 * Get local network IP address for remote access
 * @returns {string|null} - Local IP or null if not found
 */
function getLocalIP() {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      // Skip internal (loopback) and non-IPv4 addresses
      if (iface.family === 'IPv4' && !iface.internal) {
        return iface.address;
      }
    }
  }
  return null;
}

/**
 * Build URL with query parameters (fixes path conflicts)
 * @returns {{url: string, networkUrl: string|null}} - Local and network URLs
 */
function buildUrl(host, port, type, filePath) {
  const displayHost = isWildcardBind(host) ? 'localhost' : (host.includes(':') ? `[${host.replace(/^\[|\]$/g, '')}]` : host);
  const baseUrl = `http://${displayHost}:${port}`;

  let urlPath = '';
  if (type === 'file') {
    urlPath = `/view?file=${encodeURIComponent(filePath)}`;
  } else if (type === 'directory') {
    urlPath = `/browse?dir=${encodeURIComponent(filePath)}`;
  }

  const url = baseUrl + urlPath;

  // If binding to all interfaces, provide network URL for remote access
  let networkUrl = null;
  if (isWildcardBind(host)) {
    const localIP = getLocalIP();
    if (localIP) {
      networkUrl = `http://${localIP}:${port}${urlPath}`;
    }
  }

  return { url, networkUrl };
}

/**
 * Main function
 */
async function main() {
  const args = parseArgs(process.argv);
  const hostWarning = nonLoopbackWarning(args.host);
  if (hostWarning && !args.isChild) console.error(hostWarning);
  const cwd = process.cwd();
  const assetsDir = path.join(__dirname, '..', 'assets');

  // Handle --stop
  if (args.stop) {
    const instances = findRunningInstances();
    if (instances.length === 0) {
      console.log('No server running to stop');
      process.exit(0);
    }
    const stopped = stopAllServers();
    console.log(`Stopped ${stopped} server(s)`);
    process.exit(0);
  }

  // Determine input
  const input = args.dir || args.file;

  // Validate input
  if (!input) {
    console.error('Error: --file or --dir argument required');
    console.error('Usage:');
    console.error('  node server.cjs --file <path.md> [--port 3456] [--open]');
    console.error('  node server.cjs --dir <path> [--port 3456] [--open]  # Browse directory');
    process.exit(1);
  }

  // Resolve input path - simple logic
  let resolved = resolveInput(input, cwd);

  // If --dir was explicitly used, force directory mode
  if (args.dir && resolved.type === null) {
    const dirPath = path.isAbsolute(args.dir) ? args.dir : path.resolve(cwd, args.dir);
    if (fs.existsSync(dirPath) && fs.statSync(dirPath).isDirectory()) {
      resolved = { type: 'directory', path: dirPath };
    }
  }

  if (resolved.type === null) {
    console.error(`Error: Invalid path: ${input}`);
    console.error('Path must be a file or directory.');
    process.exit(1);
  }

  // Background mode - spawn child and exit (legacy mode for manual runs)
  // Skip if --foreground is set (for Claude Code background tasks)
  if (args.background && !args.foreground && !args.isChild) {
    const childArgs = ['--port', String(args.port), '--host', args.host, '--child'];
    if (resolved.type === 'file') {
      childArgs.unshift('--file', resolved.path);
    } else {
      childArgs.unshift('--dir', resolved.path);
    }
    if (args.open) childArgs.push('--open');

    const child = spawn(process.execPath, [__filename, ...childArgs], {
      detached: true,
      stdio: 'ignore',
      cwd: cwd
    });
    child.unref();

    // Report the port the child itself registered (matched by pid), never another server's
    let instance = null;
    for (let i = 0; i < 50 && !instance; i++) {
      await new Promise(r => setTimeout(r, 100));
      instance = findRunningInstances().find(inst => inst.pid === child.pid) || null;
    }
    if (!instance) {
      console.error('Error: background server did not start (no PID registered within 5s)');
      process.exit(1);
    }
    const port = instance.port;

    const { url, networkUrl } = buildUrl(args.host, port, resolved.type, resolved.path);

    const result = {
      success: true,
      url,
      path: resolved.path,
      port,
      host: args.host,
      mode: resolved.type
    };
    if (networkUrl) result.networkUrl = networkUrl;

    console.log(JSON.stringify(result));

    process.exit(0);
  }

  // Find available port
  const port = await findAvailablePort(args.port, args.host);
  if (port !== args.port) {
    console.error(`Port ${args.port} in use, using ${port}`);
  }

  // Allowed directories: bundled assets plus only what the user asked to view.
  // The project root (cwd) is never added implicitly. A file that sits directly in
  // cwd is served alone, not together with its siblings.
  const allowedDirs = [assetsDir];
  const allowedFiles = [];
  const mediaDirs = [];
  if (resolved.type === 'directory') {
    allowedDirs.push(resolved.path);
  } else if (resolved.type === 'file') {
    const fileDir = path.dirname(resolved.path);
    if (path.resolve(fileDir) === path.resolve(cwd)) {
      allowedFiles.push(resolved.path);
      mediaDirs.push(fileDir); // sibling images only, so README images still render
    } else {
      allowedDirs.push(fileDir);
    }
  }

  // Create server
  const server = createHttpServer({
    assetsDir,
    renderMarkdown: (fp) => generateFullPage(fp, assetsDir),
    allowedDirs,
    allowedFiles,
    mediaDirs,
    bindHost: args.host
  });

  // Start server
  server.listen(port, args.host, () => {
    const { url, networkUrl } = buildUrl(args.host, port, resolved.type, resolved.path);

    // Write PID file
    try {
      writePidFile(port, process.pid);
    } catch (err) {
      // The server still works; only `--stop` by PID file is unavailable
      console.error(`Warning: could not write PID file: ${err.message}`);
    }

    // Setup shutdown handlers
    setupShutdownHandlers(port, () => {
      server.close();
    });

    // Output for CLI/command integration
    // In foreground mode (CC background task), always output JSON
    if (args.foreground || args.isChild || process.env.CLAUDE_COMMAND) {
      const result = {
        success: true,
        url,
        path: resolved.path,
        port,
        host: args.host,
        mode: resolved.type
      };
      if (networkUrl) result.networkUrl = networkUrl;
      console.log(JSON.stringify(result));
    } else {
      console.log(`\nMarkdown Novel Viewer`);
      console.log(`${'─'.repeat(40)}`);
      console.log(`URL: ${url}`);
      if (networkUrl) {
        console.log(`Network: ${networkUrl}`);
      }
      console.log(`Path: ${resolved.path}`);
      console.log(`Port: ${port}`);
      console.log(`Host: ${args.host}`);
      console.log(`Mode: ${resolved.type === 'file' ? 'File Viewer' : 'Directory Browser'}`);
      console.log(`\nPress Ctrl+C to stop\n`);
    }

    // Open browser
    if (args.open) {
      openBrowser(url);
    }
  });

  server.on('error', (err) => {
    console.error(`Server error: ${err.message}`);
    process.exit(1);
  });
}

// Run
main().catch(err => {
  console.error(`Error: ${err.message}`);
  process.exit(1);
});
