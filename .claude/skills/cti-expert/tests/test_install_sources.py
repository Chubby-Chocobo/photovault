"""The CTI installer must only pull pinned third-party code and never use sudo."""

import re
import subprocess
from pathlib import Path

INSTALL = Path(__file__).parent.parent / "scripts" / "install.sh"
TEXT = INSTALL.read_text(encoding="utf-8")
CODE = "\n".join(l for l in TEXT.splitlines() if not l.lstrip().startswith("#"))


def test_script_parses():
    assert subprocess.run(["bash", "-n", str(INSTALL)], capture_output=True).returncode == 0


def test_no_floating_refs():
    assert "@master" not in CODE and "@main" not in CODE
    assert re.search(r"git\s+-C\s+\S+\s+pull", CODE) is None
    assert "clone --quiet --depth 1" not in CODE


def test_git_sources_are_pinned_to_commits():
    for name in ("MSFTRECON_COMMIT", "SHARETRACE_COMMIT"):
        assert re.search(rf'^{name}="[0-9a-f]{{40}}"$', CODE, re.M), name
    assert "msftrecon.git@$MSFTRECON_COMMIT" in CODE


def test_release_binaries_are_checksum_verified_and_no_sudo():
    assert "checksum" in CODE and "sha256sum" in CODE
    start = CODE.index("gh_binary_install() {")
    body = CODE[start:CODE.index("\n}\n", start)]
    assert "sudo" not in body


def test_go_tools_are_pinned_to_versions():
    for line in CODE.splitlines():
        if line.lstrip().startswith("go_install "):
            assert re.search(r"@v\d+\.\d+\.\d+\"$", line), line
    assert "@latest" not in CODE


def test_sudo_only_runs_behind_the_with_sudo_flag():
    lines = CODE.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"\s*(?:.*[;&|]\s*)?sudo\s", line) and not line.lstrip().startswith(("log_", "echo")):
            window = "\n".join(lines[max(0, i - 4):i + 1])
            assert "OPT_SUDO" in window, line


def test_go_requirement_matches_the_pinned_tools():
    assert "Go 1.21" not in TEXT
    assert "Go 1.26+" in TEXT and "GO_MINOR" in CODE
