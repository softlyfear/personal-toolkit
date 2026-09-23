"""OCR: add an invisible text layer to pages that have none. EasyOCR, CPU, inside the venv."""

from __future__ import annotations

from pathlib import Path

import pymupdf

from pdfprep.fonts import find_font
from pdfprep.pdfdoc import text_layer
from pdfprep.ui import PdfPrepError, info, warn

RENDER_DPI = 200
ENGINE = "easyocr"
MIN_CONFIDENCE = 0.2
# Detector plus recogniser, with headroom for a large page render
GPU_MIN_FREE_BYTES = 2 * 1024**3
# Building a Reader costs seconds and hundreds of MB, so one is kept per language set and device
_READERS: dict[tuple[tuple[str, ...], bool], object] = {}


def pages_without_text(doc: pymupdf.Document) -> list[int]:
    return [i for i in range(doc.page_count) if text_layer(doc[i]) != "readable"]


def gpu_status() -> tuple[bool, str]:
    """(usable, description) of the GPU as torch sees it. A ROCm build of torch answers
    through torch.cuda as well, so one check covers NVIDIA and AMD."""
    try:
        import torch
    except ImportError:
        return False, "torch is not installed"
    if not torch.cuda.is_available():
        return False, f"no GPU visible to torch {torch.__version__}"
    free, total = torch.cuda.mem_get_info()
    detail = (
        f"{torch.cuda.get_device_name(0)} · {free / 1024**3:.1f} of {total / 1024**3:.1f} GB free"
        f" · torch {torch.__version__}"
    )
    if free < GPU_MIN_FREE_BYTES:
        return False, f"{detail} — too little free memory"
    return True, detail


def _use_gpu(device: str, languages: tuple[str, ...]) -> bool:
    if device == "cpu":
        return False
    # the memory a loaded GPU reader holds reads as "not free" and would push every document
    # after the first onto the CPU
    if (languages, True) in _READERS:
        return True
    usable, detail = gpu_status()
    if usable:
        info(f"OCR on the GPU: {detail}")
    elif device == "gpu":
        warn(f"OCR falls back to the CPU: {detail}")
    return usable


def _reader(languages: tuple[str, ...], model_dir: Path, gpu: bool):
    cached = _READERS.get((languages, gpu))
    if cached is not None:
        return cached
    try:
        import easyocr
    except ImportError as exc:
        raise PdfPrepError("easyocr is not installed — run `uv sync` in the project") from exc
    model_dir.mkdir(parents=True, exist_ok=True)
    info(f"Loading EasyOCR ({', '.join(languages)}) — first run downloads model weights")
    _READERS[(languages, gpu)] = easyocr.Reader(
        list(languages),
        gpu=gpu,
        model_storage_directory=str(model_dir),
        user_network_directory=str(model_dir),
        verbose=False,
    )
    return _READERS[(languages, gpu)]


def add_text_layer(
    source: Path, dst: Path, languages: tuple[str, ...], work_dir: Path, device: str = "auto"
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
        gpu = _use_gpu(device, languages)
        reader = _reader(languages, work_dir / "ocr-models", gpu)
        scale = RENDER_DPI / 72.0
        words = 0
        pages_with_text = 0
        for index in targets:
            page = doc[index]
            pixmap = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), colorspace=pymupdf.csRGB)
            image = np.frombuffer(pixmap.samples, dtype=np.uint8).reshape(
                pixmap.height, pixmap.width, 3
            )
            try:
                found = reader.readtext(image)
            # torch.OutOfMemoryError and a kernel the ROCm build lacks both land here
            except RuntimeError as exc:
                if not gpu:
                    raise
                warn(f"OCR on the GPU failed on page {index + 1} ({exc}); continuing on the CPU")
                gpu = False
                reader = _reader(languages, work_dir / "ocr-models", gpu)
                found = reader.readtext(image)
            font_ready = False
            for box, text, confidence in found:
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
