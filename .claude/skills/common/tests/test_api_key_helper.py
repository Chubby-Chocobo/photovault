"""api_key_helper looks in the project's own .env files, never above the project."""

import importlib.util
import shutil
from pathlib import Path

import pytest

HELPER = Path(__file__).parent.parent / "api_key_helper.py"


@pytest.fixture
def project(tmp_path, monkeypatch):
    for name in list(__import__("os").environ):
        if name.startswith("GEMINI_API_KEY"):
            monkeypatch.delenv(name)
    monkeypatch.setenv("HOME", str(tmp_path / "empty-home"))
    proj = tmp_path / "parent" / "proj"
    common = proj / ".claude" / "skills" / "common"
    common.mkdir(parents=True)
    shutil.copy(HELPER, common / "api_key_helper.py")
    spec = importlib.util.spec_from_file_location("api_key_helper_copy", common / "api_key_helper.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return tmp_path / "parent", proj, module


def test_parent_directory_env_is_ignored(project):
    parent, proj, helper = project
    (parent / ".env").write_text("GEMINI_API_KEY=FROM_PARENT\n")
    assert helper.find_api_key() is None
    assert helper.find_all_api_keys() == []


def test_project_env_files_follow_resolve_env_order(project):
    parent, proj, helper = project
    skill = proj / ".claude" / "skills" / "ai-multimodal"
    skill.mkdir()
    (parent / ".env").write_text("GEMINI_API_KEY=FROM_PARENT\n")
    (proj / ".env").write_text("GEMINI_API_KEY=PROJECT_ROOT_IGNORED\n")
    (proj / ".claude" / ".env").write_text("GEMINI_API_KEY=CLAUDE\nGEMINI_API_KEY_2=CLAUDE2\n")
    assert helper.find_api_key(skill) == "CLAUDE"
    (proj / ".claude" / "skills" / ".env").write_text("GEMINI_API_KEY=SHARED\n")
    assert helper.find_api_key(skill) == "SHARED"
    (skill / ".env").write_text("GEMINI_API_KEY=SKILL\n")
    assert helper.find_api_key(skill) == "SKILL"
    assert helper.find_all_api_keys(skill) == ["SKILL", "SHARED", "CLAUDE", "CLAUDE2"]


def test_project_root_env_is_not_read(project):
    parent, proj, helper = project
    (proj / ".env").write_text("GEMINI_API_KEY=ROOT\n")
    assert helper.find_api_key() is None


def test_user_level_env_comes_after_project_files(project, tmp_path):
    parent, proj, helper = project
    home = tmp_path / "empty-home"
    (home / ".claude").mkdir(parents=True)
    (home / ".claude" / ".env").write_text("GEMINI_API_KEY=USER\n")
    assert helper.find_api_key() == "USER"
    (proj / ".claude" / ".env").write_text("GEMINI_API_KEY=CLAUDE\n")
    assert helper.find_api_key() == "CLAUDE"


def test_rotator_masking_never_shows_the_key_start():
    spec = importlib.util.spec_from_file_location("api_key_rotator_copy", HELPER.parent / "api_key_rotator.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    key = "AIzaSyABCDEFGHIJKLMNOP"
    masked = module.KeyRotator([key]).current_key_masked
    assert key[:8] not in masked and masked.endswith(key[-4:])
    assert module.KeyRotator(["short"]).current_key_masked == "***"
