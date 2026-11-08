"""The review viewer only stops its own earlier instance, never other programs on the port."""

import importlib.util
import signal
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "eval-viewer" / "generate_review.py"


@pytest.fixture
def module():
    spec = importlib.util.spec_from_file_location("generate_review_under_test", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def fake_system(module, monkeypatch):
    """lsof lists pids 111 (a viewer) and 222 (unrelated); records every kill."""
    calls = []
    kills = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        if cmd[0] == "lsof":
            return SimpleNamespace(stdout="111\n222\n")
        pid = cmd[2]
        command = "python3 skill-creator/eval-viewer/generate_review.py ws" if pid == "111" else "nginx: master"
        return SimpleNamespace(stdout=command + "\n")

    monkeypatch.setattr(module.subprocess, "run", fake_run)
    monkeypatch.setattr(module.os, "kill", lambda pid, sig: kills.append((pid, sig)))
    monkeypatch.setattr(module.time, "sleep", lambda s: None)
    return calls, kills


def test_only_listening_sockets_are_queried(module, fake_system):
    calls, _ = fake_system
    module._kill_port(3117)
    assert calls[0] == ["lsof", "-ti", "tcp:3117", "-sTCP:LISTEN"]


def test_unrelated_listener_is_not_killed(module, fake_system):
    _, kills = fake_system
    module._kill_port(3117)
    assert kills == [(111, signal.SIGTERM)]
