"""Gate checks and media scripts must never install software while they run."""

import os
import stat
import subprocess
from pathlib import Path

import pytest

SKILLS = Path(__file__).resolve().parents[2]
GATE_LIB = SKILLS / "quality-gates" / "checks" / "lib-gate-utils.sh"
RMBG = SKILLS / "media-processing" / "scripts" / "remove-background.sh"
RMBG_BATCH = SKILLS / "media-processing" / "scripts" / "batch-remove-background.sh"
INSTALLERS = ["brew", "sudo", "apt-get", "snap", "pip3", "pip", "npm", "winget", "choco"]


@pytest.fixture
def stub_env(tmp_path):
    """PATH with recording stubs for every installer, plus the basic system tools."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "calls.log"
    for name in INSTALLERS:
        stub = bin_dir / name
        stub.write_text(f'#!/bin/sh\necho "{name} $@" >> "{log}"\nexit 0\n')
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path), "TERM": "dumb"}
    return env, log


def calls(log: Path) -> str:
    return log.read_text() if log.exists() else ""


def test_sourcing_gate_lib_installs_nothing(stub_env, tmp_path):
    env, log = stub_env
    result = subprocess.run(
        ["bash", "-c", f'source "{GATE_LIB}"; echo ok'],
        env=env, cwd=tmp_path, capture_output=True, text=True,
    )
    assert "ok" in result.stdout, result.stderr
    assert calls(log) == ""


def test_config_value_falls_back_without_mikefarah_yq(stub_env, tmp_path):
    env, _ = stub_env
    (tmp_path / ".quality-gates").mkdir()
    (tmp_path / ".quality-gates" / "config.yaml").write_text("max_file_lines: 123\n")
    result = subprocess.run(
        ["bash", "-c", f'source "{GATE_LIB}"; read_config_value max_file_lines 7'],
        env=env, cwd=tmp_path, capture_output=True, text=True,
    )
    assert result.stdout.strip() == "123", result.stderr


def test_remove_background_does_not_install_rmbg(stub_env, tmp_path):
    env, log = stub_env
    image = tmp_path / "a.png"
    image.write_bytes(b"x")
    result = subprocess.run(["bash", str(RMBG), str(image)], env=env, cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0
    assert "npm" not in calls(log)


def test_batch_remove_background_does_not_install_rmbg(stub_env, tmp_path):
    env, log = stub_env
    images = tmp_path / "imgs"
    images.mkdir()
    result = subprocess.run(["bash", str(RMBG_BATCH), str(images)], env=env, cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode != 0
    assert "npm" not in calls(log)


SONAR = SKILLS / "quality-gates" / "checks" / "check-sonar.sh"


def test_sonar_token_goes_through_the_environment_not_argv(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    seen = tmp_path / "scanner.log"
    for name, body in {
        "sonar-scanner": f'echo "ARGS $@" >> "{seen}"; echo "TOKEN ${{SONAR_TOKEN:-unset}}" >> "{seen}"; echo "QUALITY GATE STATUS: PASSED"; exit 0',
        "curl": f'echo "CURL $@" >> "{seen}"; for a in "$@"; do case "$a" in @*) echo "HEADERFILE ${{a#@}} $(cat "${{a#@}}")" >> "{seen}";; esac; done; exit 1',
    }.items():
        stub = bin_dir / name
        stub.write_text(f"#!/bin/sh\n{body}\n")
        stub.chmod(stub.stat().st_mode | stat.S_IEXEC)
    work = tmp_path / "proj"
    work.mkdir()
    env = {
        "PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(tmp_path), "TERM": "dumb",
        "SONAR_HOST_URL": "http://localhost:9000", "SONAR_PROJECT_KEY": "p",
        "SONAR_TOKEN": "sekret-token-value",
    }
    subprocess.run(["bash", str(SONAR)], cwd=work, env=env, capture_output=True, timeout=60)
    log = seen.read_text()
    assert "ARGS" in log, "sonar-scanner was not invoked"
    args_line = next(l for l in log.splitlines() if l.startswith("ARGS"))
    assert "sekret-token-value" not in args_line
    assert "TOKEN sekret-token-value" in log
    curl_lines = [l for l in log.splitlines() if l.startswith("CURL")]
    assert curl_lines, "curl was not invoked"
    assert all("sekret-token-value" not in l for l in curl_lines)
    header_line = next(l for l in log.splitlines() if l.startswith("HEADERFILE"))
    assert "Authorization: Bearer sekret-token-value" in header_line
    assert not Path(header_line.split()[1]).exists(), "header file was not removed"
    leaked = [p for p in work.rglob("*") if p.is_file() and "sekret-token-value" in p.read_text(errors="ignore")]
    assert leaked == []
