"""Scripts the installer may run on Python 3.9 must not use newer-only syntax."""

import ast
import re
from pathlib import Path

SKILLS = Path(__file__).resolve().parents[2]


def test_no_backslash_inside_fstring_expressions():
    # Backslashes in f-string expressions are a SyntaxError before Python 3.12.
    offenders = []
    for path in SKILLS.rglob("*.py"):
        if ".venv" in path.parts or "node_modules" in path.parts:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for node in ast.walk(ast.parse(text, str(path))):
            if isinstance(node, ast.JoinedStr):
                segment = ast.get_source_segment(text, node) or ""
                if re.search(r"\{[^{}]*\\[^{}]*\}", re.sub(r"\{\{|\}\}", "", segment)):
                    offenders.append(f"{path.relative_to(SKILLS)}:{node.lineno}")
    assert offenders == []


def test_generate_review_defers_annotation_evaluation():
    source = (SKILLS / "skill-creator" / "eval-viewer" / "generate_review.py").read_text(encoding="utf-8")
    assert "from __future__ import annotations" in source


def _has_future_annotations(tree: ast.Module) -> bool:
    return any(
        isinstance(n, ast.ImportFrom) and n.module == "__future__" and any(a.name == "annotations" for a in n.names)
        for n in tree.body
    )


def test_union_annotations_need_deferred_evaluation():
    # `X | None` in a signature is evaluated at import time and raises TypeError on Python 3.9
    # unless annotations are deferred.
    offenders = []
    for path in SKILLS.rglob("*.py"):
        if ".venv" in path.parts or "node_modules" in path.parts:
            continue
        tree = ast.parse(path.read_text(encoding="utf-8", errors="replace"), str(path))
        if _has_future_annotations(tree):
            continue
        annotations = []
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                args = node.args
                for arg in args.posonlyargs + args.args + args.kwonlyargs + [args.vararg, args.kwarg]:
                    if arg is not None and arg.annotation is not None:
                        annotations.append(arg.annotation)
                if node.returns is not None:
                    annotations.append(node.returns)
            elif isinstance(node, ast.AnnAssign):
                annotations.append(node.annotation)
        for annotation in annotations:
            if any(isinstance(n, ast.BinOp) and isinstance(n.op, ast.BitOr) for n in ast.walk(annotation)):
                offenders.append(f"{path.relative_to(SKILLS)}:{annotation.lineno}")
                break
    assert offenders == []
