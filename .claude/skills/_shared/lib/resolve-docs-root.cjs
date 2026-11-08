'use strict';
/**
 * Resolve the project docs root for scripts that write or read docs.
 * Order: $ADF_DOCS_PATH (absolute, set by the session hook) ->
 * `paths.docs` in <project>/.claude/config/adf-config.json (the docs-root rule in hooks/lib/docs-layout.cjs) -> `docs`.
 * Returns an absolute path. Project dir is `projectDir`, else $CLAUDE_PROJECT_DIR, else cwd.
 */
const fs = require('fs');
const path = require('path');
const { normalizeDocsRoot } = require('../../../hooks/lib/docs-layout.cjs');

const DEFAULT_DOCS = 'docs';

function configuredDocs(projectDir) {
  try {
    const raw = fs.readFileSync(path.join(projectDir, '.claude', 'config', 'adf-config.json'), 'utf8');
    return normalizeDocsRoot(JSON.parse(raw)?.paths?.docs);
  } catch (_) {
    return null;
  }
}

function resolveDocsRoot(opts = {}) {
  const env = opts.env || process.env;
  const projectDir = path.resolve(opts.projectDir || env.CLAUDE_PROJECT_DIR || process.cwd());
  const fromEnv = env.ADF_DOCS_PATH;
  if (typeof fromEnv === 'string' && path.isAbsolute(fromEnv)) return path.normalize(fromEnv);
  return path.resolve(projectDir, configuredDocs(projectDir) || DEFAULT_DOCS);
}

module.exports = { resolveDocsRoot };
