"""Split, compress and OCR behaviour that real documents broke once."""

from __future__ import annotations

import pymupdf
import pytest
from pdfprep import compress, config, ocr, pdfdoc, split
from pdfprep.ui import PdfPrepError

from conftest import body_text


def illustrated(page: pymupdf.Page, number: int) -> None:
    if number % 3 == 0:
        page.insert_text((72, 100), f"Section {number // 3 + 1} Procedures", fontsize=18)
    body_text(page)
    # an image keeps the document off the text-only path, which never compresses
    pixmap = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 64, 64), False)
    pixmap.set_rect(pixmap.irect, (40 * (number % 5), 120, 200))
    page.insert_image(pymupdf.Rect(72, 500, 272, 700), pixmap=pixmap)


def test_split_survives_a_rejected_compression(make_pdf, monkeypatch) -> None:
    def rejected(*_args, **_kwargs):
        raise PdfPrepError("compression rejected by acceptance checks: pixel_identity")

    source = make_pdf("manual", 9, illustrated)
    monkeypatch.setattr(compress, "compress_file", rejected)
    cfg = config.load()

    result = split.split_source(source, cfg, pdfdoc.inspect(source))

    assert [(p.first_page, p.last_page) for p in result.parts] == [(0, 8)]
    assert any("compression was rejected" in note for note in result.notes)
    assert all(status == "pass" for _, status, _ in split.validate(result, cfg))


def test_lossless_compression_is_pixel_identical(make_pdf, tmp_path) -> None:
    source = make_pdf("plain", 4, illustrated)
    cfg = config.load()

    result = compress.compress_file(
        source,
        tmp_path / "out.pdf",
        target_dpi=cfg.target_dpi,
        jpeg_quality=cfg.jpeg_quality,
        verify_dpi=cfg.verify_dpi,
        verify_sample=cfg.verify_sample_pages,
        work_dir=tmp_path / "work",
    )

    assert not result.acceptance.failed
    assert not list((tmp_path / "work").iterdir())


def test_a_loaded_gpu_reader_is_reused_for_the_next_document(monkeypatch) -> None:
    # the loaded reader's own memory reads as "not free", which sent every document after
    # the first to the CPU
    languages = ("en", "ru")
    monkeypatch.setitem(ocr._READERS, (languages, True), object())
    monkeypatch.setattr(ocr, "gpu_status", lambda: (False, "0.2 of 7.5 GB free"))

    assert ocr._use_gpu("auto", languages)
    assert not ocr._use_gpu("cpu", languages)


@pytest.mark.parametrize("device", ["auto", "gpu"])
def test_no_gpu_and_no_loaded_reader_means_cpu(monkeypatch, device) -> None:
    monkeypatch.setattr(ocr, "_READERS", {})
    monkeypatch.setattr(ocr, "gpu_status", lambda: (False, "no GPU visible to torch"))

    assert not ocr._use_gpu(device, ("en",))
