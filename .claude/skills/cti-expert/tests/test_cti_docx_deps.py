"""CTI generators must never install packages and must fail with an install hint."""

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))

import cti_docx_deps


@pytest.mark.parametrize("name", ["generate-cti-docx.py", "generate-cti-docx-hybrid.py", "cti_docx_deps.py"])
def test_scripts_never_call_pip(name):
    text = (SCRIPTS / name).read_text()
    assert "pip" not in text.replace("pipe", "")
    assert "--break-system-packages" not in text


def test_missing_package_exits_with_install_hint(monkeypatch, capsys):
    real = importlib.util.find_spec
    monkeypatch.setattr(
        importlib.util, "find_spec", lambda m, *a: None if m == "networkx" else real(m, *a)
    )
    with pytest.raises(SystemExit) as exc:
        cti_docx_deps.require_python_packages()
    assert "networkx" in str(exc.value) and "install.sh" in str(exc.value)


def test_missing_pandoc_exits_with_install_hint(monkeypatch):
    monkeypatch.setattr(cti_docx_deps.shutil, "which", lambda _name: None)
    with pytest.raises(SystemExit) as exc:
        cti_docx_deps.require_pandoc()
    assert "pandoc" in str(exc.value) and "install.sh" in str(exc.value)


def test_present_pandoc_passes(monkeypatch):
    monkeypatch.setattr(cti_docx_deps.shutil, "which", lambda _name: "/usr/bin/pandoc")
    cti_docx_deps.require_pandoc()
