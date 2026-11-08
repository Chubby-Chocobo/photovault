"""Resolve the project docs root: $ADF_DOCS_PATH -> paths.docs in adf-config.json -> 'docs'.

Same contract as _shared/lib/resolve-docs-root.cjs. Kept as a per-skill copy so the skill
works when installed without its siblings.
"""

import json
import os
from pathlib import Path, PureWindowsPath

DEFAULT_DOCS = 'docs'


def _configured_docs(project_dir):
    try:
        cfg = json.loads((project_dir / '.claude' / 'config' / 'adf-config.json').read_text(encoding='utf-8'))
        value = cfg.get('paths', {}).get('docs')
    except (OSError, ValueError, AttributeError):
        return None
    return _normalize_docs_root(value)


def _normalize_docs_root(value):
    """Same rule as normalizeDocsRoot in .claude/hooks/lib/docs-layout.cjs: a relative folder inside the
    project, not the project root, not inside .git/ or .claude/ (any case). None when unusable."""
    if not isinstance(value, str):
        return None
    value = value.strip().rstrip('/\\')
    if not value or '\x00' in value or '\\' in value or value.startswith('/') or PureWindowsPath(value).drive:
        return None
    parts = [p for p in value.split('/') if p not in ('', '.')]
    if not parts or '..' in parts or parts[0].lower() in ('.git', '.claude'):
        return None
    return '/'.join(parts)


def resolve_docs_root(project_dir=None, env=None):
    """Return the absolute docs root as a Path."""
    env = os.environ if env is None else env
    base = Path(project_dir or env.get('CLAUDE_PROJECT_DIR') or os.getcwd()).resolve()
    from_env = env.get('ADF_DOCS_PATH')
    if from_env and Path(from_env).is_absolute():
        return Path(os.path.normpath(from_env))
    return base / (_configured_docs(base) or DEFAULT_DOCS)
