"""validate-svg.sh marker check compares full marker ids."""

import subprocess
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "scripts" / "validate-svg.sh"

SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
<defs><marker id="{defined}" markerWidth="6" markerHeight="6"><path d="M0,0 L6,3 L0,6"/></marker></defs>
<line x1="0" y1="0" x2="50" y2="50" marker-end="url(#{used})"/>
</svg>
"""


def validate(tmp_path, defined, used):
    svg = tmp_path / "d.svg"
    svg.write_text(SVG.format(defined=defined, used=used))
    return subprocess.run(["bash", str(SCRIPT), str(svg)], capture_output=True, text=True)


def test_ids_containing_i_d_are_matched(tmp_path):
    for name in ("arrowhead", "arrow-gold", "arr-gold"):
        result = validate(tmp_path, name, name)
        assert "Missing marker" not in result.stdout, (name, result.stdout)


def test_truly_missing_marker_is_reported(tmp_path):
    result = validate(tmp_path, "arrow-a", "arrow-b")
    assert "Missing marker: arrow-b" in result.stdout
    assert result.returncode != 0
