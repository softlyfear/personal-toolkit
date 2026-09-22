"""OCR: add an invisible text layer to pages that have none. EasyOCR, CPU, inside the venv."""

from __future__ import annotations

from pathlib import Path

import pymupdf

from pdfprep.fonts import find_font
from pdfprep.pdfdoc import TEXT_PAGE_MIN_CHARS
from pdfprep.ui import PdfPrepError, info, warn

RENDER_DPI = 200
ENGINE = "easyocr"
MIN_CONFIDENCE = 0.2
# Building a Reader costs seconds and hundreds of MB, so one is kept per language set
_READERS: dict[tuple[str, ...], object] = {}


def pages_without_text(doc: pymupdf.Document) -> list[int]:
    return [
        i
        for i in range(doc.page_count)
        if len(doc[i].get_text("text").strip()) < TEXT_PAGE_MIN_CHARS
    ]


def _reader(languages: tuple[str, ...], model_dir: Path):
    cached = _READERS.get(languages)
    if cached is not None:
        return cached
    try:
        import easyocr
    except ImportError as exc:
        raise PdfPrepError("easyocr is not installed — run `uv sync` in the project") from exc
    model_dir.mkdir(parents=True, exist_ok=True)
    info(f"Loading EasyOCR ({', '.join(languages)}) — first run downloads model weights")
    _READERS[languages] = easyocr.Reader(
        list(languages),
        gpu=False,
        model_storage_directory=str(model_dir),
        user_network_directory=str(model_dir),
        verbose=False,
    )
    return _READERS[languages]


def add_text_layer(
    source: Path, dst: Path, languages: tuple[str, ...], work_dir: Path
) -> tuple[int, str]:
    """Write an OCR'd copy of `source` to `dst`. Returns (pages that gained text, engine)."""
    # Imported here so `split`/`compress` never pay for loading numpy
    import numpy as np

    font_path = find_font()
    if font_path is None:
        warn("No Cyrillic-capable TTF found — OCR text is inserted with a Latin-1 base font")
    font_name = "ocrfont" if font_path is not None else "helv"
    font = pymupdf.Font(fontfile=str(font_path)) if font_path is not None else pymupdf.Font("helv")

    doc = pymupdf.open(source)
    try:
        targets = pages_without_text(doc)
        if not targets:
            doc.save(dst)
            return 0, ENGINE
        reader = _reader(languages, work_dir / "ocr-models")
        scale = RENDER_DPI / 72.0
        words = 0
        pages_with_text = 0
        for index in targets:
            page = doc[index]
            pixmap = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), colorspace=pymupdf.csRGB)
            image = np.frombuffer(pixmap.samples, dtype=np.uint8).reshape(
                pixmap.height, pixmap.width, 3
            )
            font_ready = False
            for box, text, confidence in reader.readtext(image):
                if not text.strip() or confidence < MIN_CONFIDENCE:
                    continue
                # Embedded lazily: a blank separator page gains no word and needs no font
                if font_path is not None and not font_ready:
                    page.insert_font(fontname="ocrfont", fontfile=str(font_path))
                    font_ready = True
                    pages_with_text += 1
                xs = [point[0] / scale for point in box]
                ys = [point[1] / scale for point in box]
                rect = pymupdf.Rect(min(xs), min(ys), max(xs), max(ys))
                # insert_textbox silently drops a word that does not fit its own box, so the
                # size is scaled to the measured width and the word drawn from its baseline
                size = max(1.0, min(rect.height * 0.85, 60.0))
                width = font.text_length(text, fontsize=size)
                if width > rect.width and width > 0:
                    size = max(1.0, size * rect.width / width)
                page.insert_text(
                    (rect.x0, rect.y1 - rect.height * 0.18),
                    text,
                    fontname=font_name,
                    fontsize=size,
                    render_mode=3,  # invisible: the scan stays the only thing on screen
                    overlay=True,
                )
                words += 1
            del pixmap
        # garbage=3 merges duplicate objects and can leave an XObject without /Subtype, which
        # MuPDF then reports as a syntax error on every read; pikepdf compresses this later anyway
        doc.save(dst, garbage=1, deflate=True)
        if words == 0:
            warn(f"{source.name}: OCR recognised nothing above confidence {MIN_CONFIDENCE}")
        elif pages_with_text < len(targets):
            info(
                f"{source.name}: {len(targets) - pages_with_text} of {len(targets)} pages "
                "carry no recognisable content (blank or image-free separators)"
            )
        return pages_with_text, ENGINE
    finally:
        doc.close()
