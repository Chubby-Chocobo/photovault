/**
 * HTTP server for plans-kanban dashboard
 * Routes: /kanban, /api/plans, /assets/*, /file/*
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const { scanPlans } = require('./plan-scanner.cjs');
const { renderDashboard } = require('./dashboard-renderer.cjs');
// Fail closed: the guard is required, unlike the optional markdown renderer below
const { isPathAllowed, isHostHeaderAllowed, realpathLoose } = require('../../../markdown-novel-viewer/scripts/lib/path-guard.cjs');
const { escapeHtml, htmlHeaders } = require('../../../markdown-novel-viewer/scripts/lib/html-safety.cjs');

// Import full page renderer from markdown-novel-viewer skill
let generateFullPage = null;
let mdViewerAssetsDir = null;
try {
  const mdViewerDir = path.join(__dirname, '..', '..', '..', 'markdown-novel-viewer');
  mdViewerAssetsDir = path.join(mdViewerDir, 'assets');
  // We need to call the server's generateFullPage function
  // Since it's not exported, we'll create a minimal wrapper
  const { renderMarkdownFile, renderTOCHtml } = require(path.join(mdViewerDir, 'scripts', 'lib', 'markdown-renderer.cjs'));
  const { buildReaderPage, renderHeaderNav, renderBackButton } = require(path.join(mdViewerDir, 'scripts', 'lib', 'page-builder.cjs'));
  const { generateNavSidebar, generateNavFooter, detectPlan } = require(path.join(mdViewerDir, 'scripts', 'lib', 'plan-navigator.cjs'));

  generateFullPage = (filePath, options = {}) => {
    const { html, toc, frontmatter, title } = renderMarkdownFile(filePath);
    const tocHtml = renderTOCHtml(toc);
    const navSidebar = generateNavSidebar(filePath);
    const navFooter = generateNavFooter(filePath);
    const planInfo = detectPlan(filePath);
    const { getNavigationContext } = require(path.join(mdViewerDir, 'scripts', 'lib', 'plan-navigator.cjs'));
    const navContext = getNavigationContext(filePath);

    return buildReaderPage(path.join(mdViewerAssetsDir, 'template.html'), {
      title,
      toc: tocHtml,
      navSidebar,
      navFooter,
      content: html,
      isPlan: planInfo.isPlan,
      frontmatter,
      backButton: renderBackButton(options.dashboardUrl || '/kanban', 'Back to Dashboard'),
      headerNav: renderHeaderNav(navContext)
    });
  };
} catch (err) {
  console.warn('[http-server] Could not load markdown renderer:', err.message);
}

/**
 * Validate path is within the given directories: whole-segment containment after
 * symlink resolution, dotfiles/dot-directories refused. Empty list denies all.
 * @param {string} filePath - Path to validate
 * @param {string[]} allowedDirs - Allowed base directories
 * @returns {boolean} - True if path is safe
 */
function isPathSafe(filePath, allowedDirs) {
  return isPathAllowed(filePath, allowedDirs);
}

// Types the /file route may serve (no scripts, configs or unknown binaries)
const SERVABLE_FILE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.ico', '.md', '.markdown', '.txt', '.pdf']);

// MIME types
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
  '.ico': 'image/x-icon'
};

function getMimeType(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  return MIME_TYPES[ext] || 'application/octet-stream';
}

function sendResponse(res, statusCode, contentType, content) {
  const headers = contentType === 'text/html'
    ? htmlHeaders(content)
    : { 'Content-Type': contentType, 'X-Content-Type-Options': 'nosniff' };
  // SVG can embed script; block it when opened directly (still renders as <img>)
  if (contentType === 'image/svg+xml') headers['Content-Security-Policy'] = "script-src 'none'; sandbox";
  res.writeHead(statusCode, headers);
  res.end(content);
}

function sendError(res, statusCode, message) {
  sendResponse(res, statusCode, 'text/html', `
    <!DOCTYPE html>
    <html>
    <head><title>Error ${statusCode}</title></head>
    <body style="font-family: system-ui; padding: 2rem;">
      <h1>Error ${statusCode}</h1>
      <p>${escapeHtml(message)}</p>
    </body>
    </html>
  `);
}

/** Serve a file. Caller must have validated the path against its allow-list. */
function serveFile(res, filePath) {
  if (!fs.existsSync(filePath)) {
    sendError(res, 404, 'File not found');
    return;
  }

  const content = fs.readFileSync(filePath);
  sendResponse(res, 200, getMimeType(filePath), content);
}

/**
 * Create HTTP server for kanban dashboard
 * @param {Object} options - Server options
 * @param {string} options.assetsDir - Static assets directory
 * @param {string[]} options.allowedDirs - Allowed directories for file access
 * @param {string} options.plansDir - Plans directory for dashboard
 * @returns {http.Server}
 */
function createHttpServer(options) {
  const { assetsDir, allowedDirs = [], plansDir, bindHost = '127.0.0.1' } = options;

  // Per-server allow-list (closure state): empty list denies everything
  const dirList = allowedDirs.map(d => path.resolve(d));
  const isSafe = (p) => isPathSafe(p, dirList);

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

    // Route: /assets/* - serve static files (check kanban assets first, then markdown-viewer assets)
    if (pathname.startsWith('/assets/')) {
      const relativePath = pathname.replace('/assets/', '');
      if (relativePath.includes('..')) {
        sendError(res, 403, 'Access denied');
        return;
      }
      // Check kanban assets first
      let assetPath = path.join(assetsDir, relativePath);
      if (!fs.existsSync(assetPath) && mdViewerAssetsDir) {
        // Fallback to markdown-novel-viewer assets
        assetPath = path.join(mdViewerAssetsDir, relativePath);
      }
      const assetRoots = mdViewerAssetsDir ? [assetsDir, mdViewerAssetsDir] : [assetsDir];
      if (!isPathAllowed(assetPath, assetRoots)) {
        sendError(res, 403, 'Access denied');
        return;
      }
      serveFile(res, assetPath);
      return;
    }

    // Route: /file/* - serve local files (images, etc.)
    if (pathname.startsWith('/file/')) {
      const filePath = pathname.slice('/file'.length);
      if (!isSafe(filePath) ||
          !SERVABLE_FILE_EXTS.has(path.extname(filePath).toLowerCase()) ||
          !SERVABLE_FILE_EXTS.has(path.extname(realpathLoose(filePath)).toLowerCase())) {
        sendError(res, 403, 'Access denied');
        return;
      }
      serveFile(res, filePath);
      return;
    }

    // Route: /api/plans - JSON API for plans data
    if (pathname === '/api/plans') {
      const customDir = parsedUrl.query?.dir;
      const dir = customDir || plansDir;

      if (customDir && !isSafe(customDir)) {
        sendError(res, 403, 'Access denied');
        return;
      }

      if (!dir) {
        sendResponse(res, 200, 'application/json', JSON.stringify({ plans: [], error: 'Plans directory not configured' }));
        return;
      }

      try {
        const plans = scanPlans(dir);
        sendResponse(res, 200, 'application/json', JSON.stringify({ plans }));
      } catch (err) {
        console.error('[http-server] API error:', err.message);
        sendResponse(res, 500, 'application/json', JSON.stringify({ error: 'Error scanning plans' }));
      }
      return;
    }

    // Route: / or /kanban - render dashboard
    if (pathname === '/' || pathname === '/kanban') {
      const customDir = parsedUrl.query?.dir;
      const dir = customDir || plansDir;

      if (customDir && !isSafe(customDir)) {
        sendError(res, 403, 'Access denied');
        return;
      }

      if (!dir) {
        sendError(res, 400, 'Plans directory not configured');
        return;
      }

      try {
        const plans = scanPlans(dir);
        const html = renderDashboard(plans, { assetsDir, plansDir: dir });
        sendResponse(res, 200, 'text/html', html);
      } catch (err) {
        console.error('[http-server] Dashboard error:', err.message);
        sendError(res, 500, 'Error rendering dashboard');
      }
      return;
    }

    // Route: /view?file=<path> - render markdown file
    if (pathname === '/view') {
      const filePath = parsedUrl.query?.file;

      if (!filePath) {
        sendError(res, 400, 'Missing ?file= parameter');
        return;
      }

      if (!isSafe(filePath) || !/\.(md|markdown)$/i.test(filePath) ||
          !/\.(md|markdown)$/i.test(realpathLoose(filePath))) {
        sendError(res, 403, 'Access denied');
        return;
      }

      if (!fs.existsSync(filePath)) {
        sendError(res, 404, 'File not found');
        return;
      }

      if (!generateFullPage) {
        sendError(res, 500, 'Markdown renderer not available');
        return;
      }

      try {
        // Build dashboard URL with the plans directory
        const dashboardUrl = `/kanban?dir=${encodeURIComponent(plansDir)}`;
        const html = generateFullPage(filePath, { dashboardUrl });
        sendResponse(res, 200, 'text/html', html);
      } catch (err) {
        console.error('[http-server] Render error:', err.message);
        sendError(res, 500, 'Error rendering markdown');
      }
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
  MIME_TYPES
};
