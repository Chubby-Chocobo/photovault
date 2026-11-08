"""Every executed sudo call in the skills installer must sit behind --with-sudo."""

import re
from pathlib import Path

INSTALL = Path(__file__).resolve().parents[2] / "install.sh"
SAFE_CONTEXT = ("WITH_SUDO", "id -u")


def _executed_sudo_lines():
    lines = INSTALL.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith("#") or stripped.startswith(("print_", "echo")):
            continue
        if re.search(r"(^|[;&|]\s*|\|\s*)sudo\s", stripped):
            yield i, lines


def test_every_sudo_call_is_gated():
    found = 0
    for i, lines in _executed_sudo_lines():
        found += 1
        window = "\n".join(lines[max(0, i - 20):i + 1])
        assert any(token in window for token in SAFE_CONTEXT), f"line {i + 1}: {lines[i].strip()}"
    assert found > 0
