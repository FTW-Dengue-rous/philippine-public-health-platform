"""Placeholder so pytest has at least one test (pytest fails when it collects zero).
Replace/extend with real tests once src/ has Python functions."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_project_structure_exists():
    for folder in ["src/ingestion", "src/bronze", "src/silver", "src/gold", "src/quality"]:
        assert (ROOT / folder).is_dir(), f"missing folder: {folder}"
