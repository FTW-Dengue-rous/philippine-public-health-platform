"""Regression checks for documentation paths and authoritative project claims."""

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCAL_LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)")


def _markdown_files() -> list[Path]:
    return [ROOT / "README.md", *sorted((ROOT / "docs").rglob("*.md")), *sorted((ROOT / "src").rglob("*.md"))]


def test_local_markdown_links_resolve():
    missing = []
    for page in _markdown_files():
        for target in LOCAL_LINK.findall(page.read_text(encoding="utf-8")):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            if not (page.parent / target).resolve().is_file():
                missing.append(f"{page.relative_to(ROOT)} -> {target}")
    assert not missing, "Broken local Markdown links:\n" + "\n".join(missing)


def test_bq1_and_current_lineage_contract_are_unambiguous():
    context = (ROOT / "docs/01-context/problem-and-business-context.md").read_text(encoding="utf-8")
    contract = (ROOT / "docs/04-pipeline/quality/lineage-and-quality-contract.md").read_text(
        encoding="utf-8"
    )
    legacy = (ROOT / "docs/lineage-qc-contract_v1.3.md").read_text(encoding="utf-8")

    assert "| **BQ1**" in context and "| **Core** |" in context
    assert "| BQ2 |" in context and "Previous scope" in context
    assert "Status** | Adopted" in contract
    assert "Historical record only" in legacy
