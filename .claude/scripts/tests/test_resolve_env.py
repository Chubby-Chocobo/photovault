"""resolve_env.py must not print secret values unless asked."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parent.parent / "resolve_env.py"
SECRET = "sk-secret'value;touch pwned"


@pytest.fixture
def project(tmp_path):
    (tmp_path / ".claude").mkdir()
    (tmp_path / ".claude" / ".env").write_text(f'MY_KEY="{SECRET}"\n')
    return tmp_path


def run(project, *args):
    env = {k: v for k, v in os.environ.items() if k != "MY_KEY"}
    env["HOME"] = str(project / "home")
    return subprocess.run(
        [sys.executable, str(SCRIPT), "MY_KEY", *args],
        cwd=project, env=env, capture_output=True, text=True,
    )


def test_default_output_hides_value(project):
    result = run(project)
    assert result.returncode == 0
    assert SECRET not in result.stdout + result.stderr
    assert f"length {len(SECRET)}" in result.stdout


def test_find_all_hides_value(project):
    result = run(project, "--find-all")
    assert result.returncode == 0
    assert "sk-secret" not in result.stdout + result.stderr


def test_print_value_prints_raw_value(project):
    assert run(project, "--print-value").stdout.strip() == SECRET


def test_export_quotes_value_for_shell(project):
    out = run(project, "--export").stdout.strip()
    probe = subprocess.run(
        ["sh", "-c", f'{out}; printf %s "$MY_KEY"'], capture_output=True, text=True, cwd=project
    )
    assert probe.stdout == SECRET
    assert not (project / "pwned").exists()
