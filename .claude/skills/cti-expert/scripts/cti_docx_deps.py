"""Dependency checks for the CTI DOCX generators. Never installs anything."""
import importlib.util
import shutil
import sys

INSTALL_HINT = "Run: bash .claude/skills/cti-expert/scripts/install.sh"
REQUIRED_MODULES = {"python-docx": "docx", "matplotlib": "matplotlib", "networkx": "networkx"}


def require_python_packages() -> None:
    """Exit with an install hint when a required package is missing."""
    missing = [pkg for pkg, mod in REQUIRED_MODULES.items() if importlib.util.find_spec(mod) is None]
    if missing:
        sys.exit(
            f"Error: missing Python packages: {', '.join(missing)} "
            f"(interpreter: {sys.executable}).\n{INSTALL_HINT}\n"
            "Then run this script with .claude/skills/.venv/bin/python3."
        )


def require_pandoc() -> None:
    """Exit with an install hint when pandoc is not on PATH."""
    if shutil.which("pandoc") is None:
        sys.exit(f"Error: pandoc not found on PATH.\n{INSTALL_HINT}\nOr install pandoc with your package manager.")
