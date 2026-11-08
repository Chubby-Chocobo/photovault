"""Persisted design system lands under <docs>/design/design-system/."""
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))

from design_system import persist_design_system  # noqa: E402


def test_persist_with_docs_root_override():
    root = Path(tempfile.mkdtemp())
    res = persist_design_system({'project_name': 'Demo'}, page='dash', output_dir=str(root))
    ds = root / 'design' / 'design-system'
    assert res['design_system_dir'] == str(ds)
    assert (ds / 'MASTER.md').exists()
    assert (ds / 'pages' / 'dash.md').exists()


def test_cli_persist_default_and_env_root():
    proj = Path(tempfile.mkdtemp()).resolve()
    base = {'CLAUDE_PROJECT_DIR': str(proj), 'PATH': '/usr/bin:/bin'}
    cmd = [sys.executable, str(SCRIPTS / 'search.py'), 'saas dashboard', '--design-system', '--persist', '-p', 'Demo']
    r = subprocess.run(cmd, env=base, capture_output=True, text=True, cwd=str(proj))
    assert r.returncode == 0, r.stderr
    assert (proj / 'docs' / 'design' / 'design-system' / 'MASTER.md').exists()

    other = Path(tempfile.mkdtemp()).resolve() / 'envdocs'
    r = subprocess.run(cmd, env={**base, 'ADF_DOCS_PATH': str(other)}, capture_output=True, text=True, cwd=str(proj))
    assert r.returncode == 0, r.stderr
    assert (other / 'design' / 'design-system' / 'MASTER.md').exists()


def test_persist_keeps_existing_master_unless_forced():
    root = Path(tempfile.mkdtemp())
    ds = root / 'design' / 'design-system'
    persist_design_system({'project_name': 'Demo'}, output_dir=str(root))
    (ds / 'MASTER.md').write_text('USER EDITED', encoding='utf-8')

    res = persist_design_system({'project_name': 'Demo'}, page='dash', output_dir=str(root))
    assert (ds / 'MASTER.md').read_text(encoding='utf-8') == 'USER EDITED'
    assert res['kept_files'] == [str(ds / 'MASTER.md')]
    assert (ds / 'pages' / 'dash.md').exists()

    persist_design_system({'project_name': 'Demo'}, output_dir=str(root), force=True)
    assert 'USER EDITED' not in (ds / 'MASTER.md').read_text(encoding='utf-8')


def test_page_names_that_escape_the_folder_are_rejected():
    import pytest
    root = Path(tempfile.mkdtemp())
    for bad in ('../../../escaped', 'a/b', '..', '!!!'):
        with pytest.raises(ValueError):
            persist_design_system({'project_name': 'Demo'}, page=bad, output_dir=str(root))
    assert not (root / 'escaped.md').exists()


def test_page_name_is_slugified():
    root = Path(tempfile.mkdtemp())
    persist_design_system({'project_name': 'Demo'}, page='My Dash_Board', output_dir=str(root))
    assert (root / 'design' / 'design-system' / 'pages' / 'my-dash-board.md').exists()


def test_cli_rejects_escaping_page_name():
    proj = Path(tempfile.mkdtemp()).resolve()
    cmd = [sys.executable, str(SCRIPTS / 'search.py'), 'saas dashboard', '--design-system', '--persist',
           '--page', '../../escaped', '-o', str(proj / 'docs')]
    r = subprocess.run(cmd, env={'PATH': '/usr/bin:/bin'}, capture_output=True, text=True, cwd=str(proj))
    assert r.returncode == 1
    assert 'Invalid page name' in r.stderr
    assert not (proj / 'escaped.md').exists()
