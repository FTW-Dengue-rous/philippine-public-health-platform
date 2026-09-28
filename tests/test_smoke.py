"""Placeholder so pytest has at least one test (pytest fails when it collects zero)."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

EXPECTED_FOLDERS = [
    "src/00_setup",
    "src/01_ingestion",
    "src/02_bronze",
    "src/03_silver",
    "src/04_gold",
]


def test_project_structure_exists():
    for folder in EXPECTED_FOLDERS:
        assert (ROOT / folder).is_dir(), f"missing folder: {folder}"