/**
 * Core HTTP server for markdown-novel-viewer
 * Handles routing for markdown viewer and directory browser
 *
 * Routes:
 * - /view?file=<path>  - Markdown file viewer
 * - /browse?dir=<path> - Directory browser
 * - /assets/*          - Static assets
 * - /file/*            - Local files (images, etc.)
 *
 * Security: paths are contained to an explicit allow-list (segment-wise, realpath,
 * no dotfiles); Host header is checked when bound to loopback
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const { isPathAllowed, isHostHeaderAllowed, realpathLoose } = require('./path-guard.cjs');
const { escapeHtml, htmlHeaders } = require('./html-safety.cjs');

// Allowed base directories / exact files for file access (set at runtime)
let allowedBaseDirs = [];
let allowedExactFiles = [];

/**
 * Set allowed directories (and optionally exact files) for file serving
 * @param {string[]} dirs - Array of allowed directory paths
 * @param {string[]} [files] - Individual files allowed without their directory
 */
function setAllowedDirs(dirs, files = []) {
  allowedBaseDirs = dirs.map(d => path.resolve(d));
  allowedExactFiles = files.map(f => path.resolve(f));
}

/**
 * Validate path is within allowed directories: whole-segment containment after
 * symlink resolution, dotfiles/dot-directories refused. Empty allow-list denies all.
 * @param {string} filePath - Path to validate
 * @param {string[]} allowedDirs - Allowed base directories
 * @returns {boolean} - True if path is safe
 */
function isPathSafe(filePath, allowedDirs = allowedBaseDirs, allowedFiles = allowedExactFiles) {
  return isPathAllowed(filePath, allowedDirs, allowedFiles);
}

// Types the /file route may serve (no scripts, configs or unknown binaries)
const SERVABLE_FILE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.ico', '.md', '.markdown', '.txt', '.pdf']);

function isServableFileType(filePath) {
  return SERVABLE_FILE_EXTS.has(path.extname(filePath).toLowerCase());
}

const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.ico']);

/** Image file directly inside a media-only dir (no dotfiles, no subdirectories). */
function isMediaSibling(filePath, mediaDirs) {
  if (typeof filePath !== 'string' || !filePath || filePath.includes('\0')) return false;
  const real = realpathLoose(filePath);
  const base = path.basename(real);
  return !base.startsWith('.') &&
    IMAGE_EXTS.has(path.extname(real).toLowerCase()) &&
    mediaDirs.includes(path.dirname(real));
}

/** Type check applies to both the requested name and the symlink target. */
function isServableTarget(filePath) {
  return isServableFileType(filePath) && isServableFileType(realpathLoose(filePath));
}

function isMarkdownFile(filePath) {
  return /\.(md|markdown)$/i.test(filePath);
}

/**
 * Sanitize error message to prevent path disclosure
 */
function sanitizeErrorMessage(message) {
  return message.replace(/\/[^\s'"<>]+/g, '[path]');
}

// MIME type mapping
const MIME_TYPES = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.md': 'text/markdown',
  '.txt': 'text/plain',
  '.pdf': 'application/pdf'
};

/**
 * Get MIME type for file extension
 */
function getMimeType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  return MIME_TYPES[ext] || 'application/octet-stream';
}

/**
 * Send response with content
 */
function sendResponse(res, statusCode, contentType, content) {
  const headers = contentType === 'text/html'
    ? htmlHeaders(content)
    : { 'Content-Type': contentType, 'X-Content-Type-Options': 'nosniff' };
  // SVG can embed script; block it when opened directly (still renders as <img>)
  if (contentType === 'image/svg+xml') headers['Content-Security-Policy'] = "script-src 'none'; sandbox";
  res.writeHead(statusCode, headers);
  res.end(content);
}

/**
 * Send error response (sanitized)
 */
function sendError(res, statusCode, message) {
  const safeMessage = escapeHtml(sanitizeErrorMessage(message));
  sendResponse(res, statusCode, 'text/html', `
    <!DOCTYPE html>
    <html>
    <head><title>Error ${statusCode}</title></head>
    <body style="font-family: system-ui; padding: 2rem;">
      <h1>Error ${statusCode}</h1>
      <p>${safeMessage}</p>
    </body>
    </html>
  `);
}

/**
 * Serve static file with path validation
 */
function serveFile(res, filePath, skipValidation = false) {
  if (!skipValidation && !isPathSafe(filePath)) {
    sendError(res, 403, 'Access denied');
    return;
  }

  if (!fs.existsSync(filePath)) {
    sendError(res, 404, 'File not found');
    return;
  }

  const content = fs.readFileSync(filePath);
  const mimeType = getMimeType(filePath);
  sendResponse(res, 200, mimeType, content);
}

/**
 * Get file icon based on extension
 */
function getFileIcon(filename) {
  const ext = path.extname(filename).toLowerCase();
  const iconMap = {
    '.md': '📄',
    '.txt': '📝',
    '.json': '📋',
    '.js': '📜',
    '.cjs': '📜',
    '.mjs': '📜',
    '.ts': '📘',
    '.css': '🎨',
    '.html': '🌐',
    '.png': '🖼️',
    '.jpg': '🖼️',
    '.jpeg': '🖼️',
    '.gif': '🖼️',
    '.svg': '🖼️',
    '.pdf': '📕',
    '.yaml': '⚙️',
    '.yml': '⚙️',
    '.toml': '⚙️',
    '.env': '🔐',
    '.sh': '💻',
    '.bash': '💻'
  };
  return iconMap[ext] || '📄';
}

/**
 * Render directory browser HTML
 */
function renderDirectoryBrowser(dirPath, assetsDir) {
  const items = fs.readdirSync(dirPath);
  const displayPath = dirPath.length > 50 ? '...' + dirPath.slice(-47) : dirPath;

  // Separate directories and files, sort alphabetically
  const dirs = [];
  const files = [];

  for (const item of items) {
    // Skip hidden files and deprecated folders
    if (item.startsWith('.') || item === 'deprecated') continue;

    const itemPath = path.join(dirPath, item);
    try {
      const stats = fs.statSync(itemPath);
      if (stats.isDirectory()) {
        dirs.push(item);
      } else {
        files.push(item);
      }
    } catch {
      // Skip items we can't stat
    }
  }

  dirs.sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
  files.sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));

  // Build file list HTML
  let listHtml = '';

  // Parent directory link (if not root)
  const parentDir = path.dirname(dirPath);
  if (parentDir !== dirPath) {
    listHtml += `<li class="dir-item parent">
      <a href="/browse?dir=${encodeURIComponent(parentDir)}">
        <span class="icon">📁</span>
        <span class="name">..</span>
      </a>
    </li>`;
  }

  // Directories
  for (const dir of dirs) {
    const fullPath = path.join(dirPath, dir);
    listHtml += `<li class="dir-item folder">
      <a href="/browse?dir=${encodeURIComponent(fullPath)}">
        <span class="icon">📁</span>
        <span class="name">${escapeHtml(dir)}/</span>
      </a>
    </li>`;
  }

  // Files
  for (const file of files) {
    const fullPath = path.join(dirPath, file);
    const icon = getFileIcon(file);
    const isMarkdown = file.endsWith('.md');

    if (isMarkdown) {
      listHtml += `<li class="dir-item file markdown">
        <a href="/view?file=${encodeURIComponent(fullPath)}">
          <span class="icon">${icon}</span>
          <span class="name">${escapeHtml(file)}</span>
        </a>
      </li>`;
    } else {
      listHtml += `<li class="dir-item file">
        <a href="/file/${encodeURIComponent(fullPath)}" target="_blank">
          <span class="icon">${icon}</span>
          <span class="name">${escapeHtml(file)}</span>
        </a>
      </li>`;
    }
  }

  // Empty directory message
  if (dirs.length === 0 && files.length === 0) {
    listHtml = '<li class="empty">This directory is empty</li>';
  }

  // Read CSS
  let css = '';
  const cssPath = path.join(assetsDir, 'directory-browser.css');
  if (fs.existsSync(cssPath)) {
    css = fs.readFileSync(cssPath, 'utf8');
  }

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>📁 ${escapeHtml(path.basename(dirPath))}</title>
  <style>
    ${css}
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>📁 ${escapeHtml(path.basename(dirPath))}</h1>
      <p class="path">${escapeHtml(displayPath)}</p>
    </header>
    <ul class="file-list">
      ${listHtml}
    </ul>
    <footer>
      <p>${dirs.length} folder${dirs.length !== 1 ? 's' : ''}, ${files.length} file${files.length !== 1 ? 's' : ''}</p>
    </footer>
  </div>
</body>
</html>`;
}

/**
 * Create HTTP server with routing
 * @param {Object} options - Server options
 * @param {string} options.assetsDir - Static assets directory
 * @param {Function} options.renderMarkdown - Markdown render function (filePath) => html
 * @param {string[]} options.allowedDirs - Allowed directories for file access
 * @returns {http.Server} - HTTP server instance
 */
function createHttpServer(options) {
  const { assetsDir, renderMarkdown, allowedDirs = [], allowedFiles = [], mediaDirs = [], bindHost = '127.0.0.1' } = options;

  // Set allowed directories for path validation (empty list denies everything)
  // Per-server allow-list in closure state (not module-global) so several servers can coexist.
  // mediaDirs: direct children of image type only (never dotfiles/subdirs).
  const dirList = allowedDirs.map(d => path.resolve(d));
  const fileList = allowedFiles.map(f => path.resolve(f));
  const mediaList = mediaDirs.map(d => realpathLoose(d));
  const isPathSafe = (p) => isPathAllowed(p, dirList, fileList);
  setAllowedDirs(allowedDirs, allowedFiles); // module-level isPathSafe export stays in sync

  const server = http.createServer((req, res) => {
    if (!isHostHeaderAllowed(req.headers.host, bindHost)) {
      sendError(res, 403, 'Forbidden host');
      return;
    }

    const parsedUrl = url.parse(req.url, true);
    let pathname;
    try {
      pathname = decodeURIComponent(parsedUrl.pathname);
    } catch (_) {
      sendError(res, 400, 'Bad request');
      return;
    }

    // Route: /assets/* - serve static files from assets directory
    if (pathname.startsWith('/assets/')) {
      const relativePath = pathname.replace('/assets/', '');
      if (relativePath.includes('..')) {
        sendError(res, 403, 'Access denied');
        return;
      }
      const assetPath = path.join(assetsDir, relativePath);
      if (!isPathAllowed(assetPath, [assetsDir])) {
        sendError(res, 403, 'Access denied');
        return;
      }
      serveFile(res, assetPath, true);
      return;
    }

    // Route: /file/* - serve local files (images, etc.)
    if (pathname.startsWith('/file/')) {
      // Extract path after '/file/' prefix (slice(6) removes '/file/')
      // Path is already URL-decoded by decodeURIComponent above
      const filePath = pathname.slice(6);

      if (!(isPathSafe(filePath) || isMediaSibling(filePath, mediaList)) || !isServableTarget(filePath)) {
        sendError(res, 403, 'Access denied');
        return;
      }

      serveFile(res, filePath, true); // already validated above (incl. media siblings)
      return;
    }

    // Route: /view?file=<path> - render markdown (query param)
    if (pathname === '/view') {
      const filePath = parsedUrl.query?.file;

      if (!filePath) {
        sendError(res, 400, 'Missing ?file= parameter. Use /view?file=/path/to/file.md');
        return;
      }

      if (!isPathSafe(filePath) || !isMarkdownFile(filePath) || !isMarkdownFile(realpathLoose(filePath))) {
        sendError(res, 403, 'Access denied');
        return;
      }

      if (!fs.existsSync(filePath)) {
        sendError(res, 404, 'File not found');
        return;
      }

      try {
        const html = renderMarkdown(filePath);
        sendResponse(res, 200, 'text/html', html);
      } catch (err) {
        console.error('[http-server] Render error:', err.message);
        sendError(res, 500, 'Error rendering markdown');
      }
      return;
    }

    // Route: /browse?dir=<path> - directory browser (query param)
    if (pathname === '/browse') {
      const dirPath = parsedUrl.query?.dir;

      if (!dirPath) {
        sendError(res, 400, 'Missing ?dir= parameter. Use /browse?dir=/path/to/directory');
        return;
      }

      if (!isPathSafe(dirPath)) {
        sendError(res, 403, 'Access denied');
        return;
      }

      if (!fs.existsSync(dirPath) || !fs.statSync(dirPath).isDirectory()) {
        sendError(res, 404, 'Directory not found');
        return;
      }

      try {
        const html = renderDirectoryBrowser(dirPath, assetsDir);
        sendResponse(res, 200, 'text/html', html);
      } catch (err) {
        console.error('[http-server] Browse error:', err.message);
        sendError(res, 500, 'Error listing directory');
      }
      return;
    }

    // Route: / - show welcome/usage page
    if (pathname === '/') {
      sendResponse(res, 200, 'text/html', `
        <!DOCTYPE html>
        <html>
        <head>
          <title>Markdown Novel Viewer</title>
          <style>
            body { font-family: system-ui; max-width: 600px; margin: 2rem auto; padding: 1rem; }
            h1 { color: #8b4513; }
            code { background: #f5f5f5; padding: 0.2rem 0.4rem; border-radius: 3px; }
            .routes { background: #faf8f3; padding: 1rem; border-radius: 8px; margin: 1rem 0; }
          </style>
        </head>
        <body>
          <h1>📖 Markdown Novel Viewer</h1>
          <p>A calm, book-like viewer for markdown files.</p>
          <div class="routes">
            <h3>Routes</h3>
            <ul>
              <li><code>/view?file=/path/to/file.md</code> - View markdown</li>
              <li><code>/browse?dir=/path/to/dir</code> - Browse directory</li>
            </ul>
          </div>
          <p>Use the <code>/preview</code> skill invocation to start viewing files.</p>
        </body>
        </html>
      `);
      return;
    }

    // Default: 404
    sendError(res, 404, 'Not found');
  });

  return server;
}

module.exports = {
  createHttpServer,
  getMimeType,
  sendResponse,
  sendError,
  serveFile,
  isPathSafe,
  isServableFileType,
  isMarkdownFile,
  setAllowedDirs,
  sanitizeErrorMessage,
  MIME_TYPES,
  renderDirectoryBrowser,
  getFileIcon
};
