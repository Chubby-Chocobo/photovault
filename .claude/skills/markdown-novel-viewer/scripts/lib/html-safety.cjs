/**
 * HTML safety helpers shared by the markdown viewer and the plans dashboard:
 * escaping, safe JSON embedding, an allow-list sanitizer for rendered markdown,
 * and the Content-Security-Policy sent with every HTML page.
 */

const crypto = require('crypto');

/** Escape text for HTML text and quoted attribute contexts. */
function escapeHtml(value) {
  if (value === null || value === undefined) return '';
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

/** Serialize a value for an inline <script> so data cannot close the block. */
function safeJson(value) {
  const json = JSON.stringify(value === undefined ? null : value);
  return json
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e')
    .replace(/&/g, '\\u0026')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
}

// ---------------------------------------------------------------------------
// Sanitizer
// ---------------------------------------------------------------------------

const ALLOWED_TAGS = new Set([
  'a', 'abbr', 'b', 'blockquote', 'br', 'caption', 'code', 'col', 'colgroup', 'dd', 'del',
  'details', 'div', 'dl', 'dt', 'em', 'figcaption', 'figure', 'h1', 'h2', 'h3', 'h4', 'h5',
  'h6', 'hr', 'i', 'img', 'input', 'ins', 'kbd', 'li', 'mark', 'ol', 'p', 'pre', 'q', 's',
  'samp', 'small', 'span', 'strong', 'sub', 'summary', 'sup', 'table', 'tbody', 'td',
  'tfoot', 'th', 'thead', 'tr', 'u', 'ul', 'var'
]);

// Tags removed together with everything inside them
const DROP_WITH_CONTENT = new Set([
  'script', 'style', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'noscript',
  'template', 'textarea', 'title', 'svg', 'math', 'xmp', 'plaintext', 'noembed', 'noframes'
]);

const GLOBAL_ATTRS = new Set(['class', 'title', 'lang', 'dir', 'align']);
const TAG_ATTRS = {
  a: new Set(['href']),
  img: new Set(['src', 'alt', 'width', 'height']),
  td: new Set(['colspan', 'rowspan']),
  th: new Set(['colspan', 'rowspan']),
  col: new Set(['span']),
  colgroup: new Set(['span']),
  ol: new Set(['start', 'type']),
  details: new Set(['open']),
  input: new Set(['type', 'checked', 'disabled'])
};

const LINK_SCHEMES = new Set(['http', 'https', 'mailto', 'tel']);
const IMAGE_SCHEMES = new Set(['http', 'https']);
const SAFE_DATA_IMAGE = /^data:image\/(?:png|gif|jpe?g|webp|avif|bmp)[;,]/i;

const NAMED_ENTITIES = { colon: ':', tab: '\t', newline: '\n', lpar: '(', rpar: ')', sol: '/', amp: '&' };

function decodeEntities(value) {
  return value.replace(/&(?:#(\d+)|#[xX]([0-9a-fA-F]+)|([a-zA-Z]+));?/g, (match, dec, hex, name) => {
    if (name) {
      const mapped = NAMED_ENTITIES[name.toLowerCase()];
      return mapped === undefined ? match : mapped;
    }
    const code = dec ? parseInt(dec, 10) : parseInt(hex, 16);
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : '';
  });
}

/** True when an href/src value uses a scheme outside the allow-list. */
function isUrlAllowed(raw, schemes, allowDataImage) {
  // Browsers ignore control characters and whitespace inside the scheme
  const cleaned = decodeEntities(raw).replace(/[\u0000- \u007f-\u00a0\u1680\u2000-\u200f\u2028\u2029\u202f\u205f\u3000\ufeff]/g, '');
  const scheme = cleaned.match(/^([^/?#]*?):/);
  if (!scheme) return true; // relative URL or fragment
  if (allowDataImage && SAFE_DATA_IMAGE.test(cleaned)) return true;
  return schemes.has(scheme[1].toLowerCase());
}

const ATTR_RE = /([^\s"'<>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;

function sanitizeAttributes(tag, rawAttrs) {
  const allowed = TAG_ATTRS[tag];
  let out = '';
  let inputType = null;
  ATTR_RE.lastIndex = 0;
  let m;
  while ((m = ATTR_RE.exec(rawAttrs)) !== null) {
    const name = m[1].toLowerCase();
    const value = m[2] !== undefined ? m[2] : m[3] !== undefined ? m[3] : m[4] !== undefined ? m[4] : '';
    if (!GLOBAL_ATTRS.has(name) && !(allowed && allowed.has(name))) continue;
    if (name === 'href' && !isUrlAllowed(value, LINK_SCHEMES, false)) continue;
    if (name === 'src' && !isUrlAllowed(value, IMAGE_SCHEMES, true)) continue;
    if (tag === 'input' && name === 'type') inputType = value.toLowerCase();
    const safeValue = value.replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    out += m[2] === undefined && m[3] === undefined && m[4] === undefined ? ` ${name}` : ` ${name}="${safeValue}"`;
  }
  return { attrs: out, inputType };
}

const TAG_RE = /<!--[\s\S]*?(?:-->|$)|<(\/?)([a-zA-Z][a-zA-Z0-9:-]*)((?:"[^"]*"|'[^']*'|[^'">])*)>/g;

/**
 * Allow-list sanitizer for HTML produced from markdown: unknown tags are dropped
 * (script-like tags with their content), attributes outside the allow-list and
 * unsafe URL schemes are removed, and any stray "<" is escaped.
 * @param {string} html
 * @returns {string}
 */
function sanitizeHtml(html) {
  const source = String(html);
  let out = '';
  let last = 0;
  let m;
  TAG_RE.lastIndex = 0;
  while ((m = TAG_RE.exec(source)) !== null) {
    out += source.slice(last, m.index).replace(/</g, '&lt;');
    last = TAG_RE.lastIndex;
    if (m[0].startsWith('<!--')) continue;

    const closing = m[1] === '/';
    const tag = m[2].toLowerCase();

    if (DROP_WITH_CONTENT.has(tag)) {
      if (!closing) {
        const end = new RegExp(`</${tag}[\\s/>]`, 'i');
        const rest = source.slice(last);
        const hit = end.exec(rest);
        if (!hit) {
          last = source.length;
          TAG_RE.lastIndex = last;
        } else {
          const close = rest.indexOf('>', hit.index);
          last += close === -1 ? rest.length : close + 1;
          TAG_RE.lastIndex = last;
        }
      }
      continue;
    }
    if (!ALLOWED_TAGS.has(tag)) continue;
    if (closing) {
      out += `</${tag}>`;
      continue;
    }

    const { attrs, inputType } = sanitizeAttributes(tag, m[3]);
    if (tag === 'input' && inputType !== 'checkbox') continue;
    out += `<${tag}${attrs}>`;
  }
  out += source.slice(last).replace(/</g, '&lt;');
  return out;
}

// ---------------------------------------------------------------------------
// Content-Security-Policy
// ---------------------------------------------------------------------------

// Hosts the pages really load from: mermaid (ESM and its chunks), highlight.js
// themes, and Google Fonts.
const CDN_SCRIPT_HOSTS = 'https://cdn.jsdelivr.net';
const CDN_STYLE_HOSTS = 'https://cdnjs.cloudflare.com https://fonts.googleapis.com';
const CDN_FONT_HOSTS = 'https://fonts.gstatic.com';

function generateNonce() {
  return crypto.randomBytes(16).toString('base64');
}

/**
 * Policy for an HTML response. With a nonce, only inline scripts carrying it run.
 * @param {string|null} nonce
 * @returns {string}
 */
function buildCsp(nonce) {
  const scriptSrc = nonce
    ? `'self' 'nonce-${nonce}' ${CDN_SCRIPT_HOSTS}`
    : "'none'";
  return [
    "default-src 'self'",
    `script-src ${scriptSrc}`,
    `style-src 'self' 'unsafe-inline' ${CDN_STYLE_HOSTS}`,
    `font-src 'self' ${CDN_FONT_HOSTS}`,
    "img-src 'self' data: https:",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'"
  ].join('; ');
}

/** Add a nonce to every <script> in a trusted template (call before inserting content). */
function addNonceToScripts(template, nonce) {
  return template.replace(/<script(?=[\s>])/g, `<script nonce="${nonce}"`);
}

// The nonce a page template carries is the first one in the document: templates
// put their scripts in <head>, and all content inserted later is sanitized/escaped.
function extractNonce(html) {
  const m = /<script nonce="([A-Za-z0-9+/=]+)"/.exec(html);
  return m ? m[1] : null;
}

/** Response headers for an HTML page (CSP derived from the page's nonce, if any). */
function htmlHeaders(html) {
  return {
    'Content-Type': 'text/html; charset=utf-8',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': buildCsp(extractNonce(html)),
    'Referrer-Policy': 'no-referrer'
  };
}

module.exports = {
  escapeHtml,
  safeJson,
  sanitizeHtml,
  buildCsp,
  generateNonce,
  addNonceToScripts,
  extractNonce,
  htmlHeaders
};
