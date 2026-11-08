"""Tests for docs root resolution and the token scripts' default path."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

from docs_root import resolve_docs_root  # noqa: E402


def make_project(config=None):
    d = Path(tempfile.mkdtemp()).resolve()
    if config is not None:
        (d / '.claude' / 'config').mkdir(parents=True)
        (d / '.claude' / 'config' / 'adf-config.json').write_text(
            config if isinstance(config, str) else json.dumps(config))
    return d


def test_default_root():
    d = make_project()
    assert resolve_docs_root(d, {}) == d / 'docs'


def test_env_override_must_be_absolute():
    d = make_project({'paths': {'docs': 'manuals'}})
    abs_path = Path(tempfile.mkdtemp()).resolve()
    assert resolve_docs_root(d, {'ADF_DOCS_PATH': str(abs_path)}) == abs_path
    assert resolve_docs_root(d, {'ADF_DOCS_PATH': 'rel'}) == d / 'manuals'


def test_config_override_and_rejections():
    assert resolve_docs_root(make_project({'paths': {'docs': 'manuals'}}), {}).name == 'manuals'
    for cfg in ({'paths': {'docs': '/etc'}}, {'paths': {'docs': '../x'}}, {'paths': {'docs': 3}}, '{bad'):
        d = make_project(cfg)
        assert resolve_docs_root(d, {}) == d / 'docs'


def test_validate_tokens_reads_default_design_system_dir():
    d = make_project()
    ds = d / 'docs' / 'design' / 'design-system'
    ds.mkdir(parents=True)
    (ds / 'tokens.json').write_text(json.dumps({'color': {'primary': {'$value': '#fff', '$type': 'color'}}}))
    env = {'CLAUDE_PROJECT_DIR': str(d), 'PATH': '/usr/bin:/bin'}
    r = subprocess.run([sys.executable, str(SCRIPTS / 'validate-tokens.py')], env=env,
                       capture_output=True, text=True, cwd=str(d))
    assert 'tokens.json not found' not in r.stdout, r.stdout + r.stderr
