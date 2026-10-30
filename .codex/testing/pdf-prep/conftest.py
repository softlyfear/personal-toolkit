"""Synthetic PDFs for the pdf-prep tests: the user's documents never enter the repository."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

import pymupdf
import pytest

BODY = 11
BODY_LINE = "The operator checks the belt tension and the roller alignment before each shift."


def body_text(page: pymupdf.Page, top: float = 140, lines: int = 14) -> None:
    for index in range(lines):
        page.insert_text((72, top + index * 16), BODY_LINE, fontsize=BODY)


@pytest.fixture(autouse=True)
def isolated_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    # without it config.load() reads the developer's own cli/pdf-prep/config.toml
    home = tmp_path / "home"
    (home / "task").mkdir(parents=True)
    (home / "result").mkdir()
    monkeypatch.setenv("PDFPREP_HOME", str(home))
    return home


@pytest.fixture
def make_pdf(isolated_home: Path) -> Callable[..., Path]:
    """Build task/<name>.pdf from a callback that fills one page at a time."""

    def build(name: str, pages: int, fill: Callable[[pymupdf.Page, int], None]) -> Path:
        doc = pymupdf.open()
        for number in range(pages):
            fill(doc.new_page(width=595, height=842), number)
        path = isolated_home / "task" / f"{name}.pdf"
        doc.save(path)
        doc.close()
        return path

    return build
