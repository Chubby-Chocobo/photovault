"""The maintainer data tool must not rewrite the shipped CSVs unless asked."""

import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "data" / "_sync_all.py"


def test_without_apply_it_leaves_the_data_untouched(tmp_path):
    shutil.copy(SCRIPT, tmp_path / "_sync_all.py")
    colors = tmp_path / "colors.csv"
    colors.write_text("keep,me\n")
    result = subprocess.run([sys.executable, str(tmp_path / "_sync_all.py")], capture_output=True, text=True)
    assert result.returncode == 1 and "--apply" in result.stdout
    assert colors.read_text() == "keep,me\n"
    assert not (tmp_path / "ui-reasoning.csv").exists()
