"""Locating a TTF that covers Cyrillic and Latin.

PyMuPDF's base-14 fonts are Latin-1 only: writing Russian with `helv` silently produces
wrong glyphs, so both the OCR text layer and the translated PDF need a real font file.
"""

from __future__ import annotations

import os
from pathlib import Path

CANDIDATES = (
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/calibri.ttf",
)


def find_font() -> Path | None:
    override = os.environ.get("PDFPREP_FONT")
    if override and Path(override).is_file():
        return Path(override)
    for candidate in CANDIDATES:
        path = Path(candidate)
        if path.is_file():
            return path
    return None
