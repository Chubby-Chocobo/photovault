/**
 * Builds the reader page from template.html for the viewer and the plans dashboard.
 * Every data field is escaped here; the rendered markdown is already sanitized.
 */

const fs = require('fs');
const { escapeHtml, safeJson, generateNonce, addNonceToScripts } = require('./html-safety.cjs');

const ARROW_BACK = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M19 12H5M12 19l-7-7 7-7"/></svg>';

/** Prev/next buttons in the header for plan phase files. */
function renderHeaderNav(navContext) {
  if (!navContext.prev && !navContext.next) return '';
  const link = (target, cls, inner) => target && fs.existsSync(target.file)
    ? `<a href="/view?file=${encodeURIComponent(target.file)}" class="header-nav-btn ${cls}" title="${escapeHtml(target.name)}">${inner}</a>`
    : '';
  const prevBtn = link(navContext.prev, 'prev',
    '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M15 18l-6-6 6-6"/></svg><span>Prev</span>');
  const nextBtn = link(navContext.next, 'next',
    '<span>Next</span><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 18l6-6-6-6"/></svg>');
  return `<div class="header-nav">${prevBtn}${nextBtn}</div>`;
}

/** Back button linking to a (server-built) URL. */
function renderBackButton(href, title) {
  return `<a href="${escapeHtml(href)}" class="icon-btn back-btn" title="${escapeHtml(title)}">${ARROW_BACK}</a>`;
}

/**
 * Fill the reader template. Placeholders are replaced in one pass with function
 * replacements, so "$" sequences in content are never interpreted and content
 * that happens to contain "{{...}}" is not substituted again.
 * @param {string} templatePath
 * @param {{title: string, toc: string, navSidebar: string, navFooter: string, content: string,
 *   isPlan: boolean, frontmatter: object, backButton: string, headerNav: string}} parts
 * @returns {string}
 */
function buildReaderPage(templatePath, parts) {
  const nonce = generateNonce();
  const template = addNonceToScripts(fs.readFileSync(templatePath, 'utf8'), nonce);
  const values = {
    title: escapeHtml(parts.title),
    toc: parts.toc,
    'nav-sidebar': parts.navSidebar,
    'nav-footer': parts.navFooter,
    content: parts.content,
    'has-plan': parts.isPlan ? 'has-plan' : '',
    frontmatter: safeJson(parts.frontmatter || {}),
    'back-button': parts.backButton,
    'header-nav': parts.headerNav
  };
  return template.replace(/\{\{([a-z-]+)\}\}/g, (match, key) =>
    Object.prototype.hasOwnProperty.call(values, key) ? values[key] : match);
}

module.exports = { buildReaderPage, renderHeaderNav, renderBackButton };
