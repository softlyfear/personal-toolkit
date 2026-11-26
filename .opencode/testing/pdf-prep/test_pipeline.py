"""Split, compress and OCR behaviour that real documents broke once."""

from __future__ import annotations

import pymupdf
import pytest
from pdfprep import compress, config, ocr, pdfdoc, split, translate
from pdfprep.extract import Block
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


def test_a_later_run_of_another_manual_does_not_inherit_the_slug(tmp_path) -> None:
    first = tmp_path / "a" / "manual.pdf"
    second = tmp_path / "b" / "manual.pdf"
    first.parent.mkdir()
    second.parent.mkdir()
    first.write_bytes(b"%PDF")
    second.write_bytes(b"%PDF")
    result = tmp_path / "result"
    result.mkdir()

    first_slugs = pdfdoc.unique_slugs([first], tmp_path, result)
    assert first_slugs[first] == "manual"
    (result / "manual--part_001_intro.pdf").write_bytes(b"old")

    second_slugs = pdfdoc.unique_slugs([second], tmp_path, result)
    assert second_slugs[second] != "manual"
    assert (result / "manual--part_001_intro.pdf").is_file()


def test_discover_finds_an_uppercase_pdf_suffix(tmp_path) -> None:
    source = tmp_path / "Scan.PDF"
    source.write_bytes(b"%PDF")
    assert pdfdoc.discover(tmp_path) == [source]


def test_page_range_rejects_zero_and_a_reversed_span() -> None:
    assert list(translate._page_range("2-4", 10)) == [1, 2, 3]
    # A bare N is the start of an open range, not a single page.
    assert list(translate._page_range("8", 10)) == [7, 8, 9]
    with pytest.raises(translate.PdfPrepError, match="ends before"):
        translate._page_range("5-3", 10)
    with pytest.raises(translate.PdfPrepError, match="starting at 1"):
        translate._page_range("0-2", 10)


def test_url_gate_rejects_a_url_that_only_contains_the_source_url(tmp_path) -> None:
    blocks = tmp_path / "blocks.json"
    blocks.write_text(
        '[{"source": "see https://example.com/a", "translated": "see https://example.com/a/extra"}]',
        encoding="utf-8",
    )
    status, _detail = translate.verify_urls(blocks)
    assert status == "fail"


def test_checkpoint_ignores_a_different_language_and_changed_source(tmp_path) -> None:
    block = Block(
        id="p1_b1",
        page=0,
        bbox=(0, 0, 10, 10),
        kind="paragraph",
        text="belt tension",
        size=11,
        level=0,
    )
    path = translate._checkpoint_path(tmp_path, "manual", "russian")
    translate._write_checkpoint(path, "russian", [block], {"p1_b1": "натяжение"})
    assert translate._load_checkpoint(path, [block])["p1_b1"] == "натяжение"
    changed = Block(
        id="p1_b1",
        page=0,
        bbox=(0, 0, 10, 10),
        kind="paragraph",
        text="roller alignment",
        size=11,
        level=0,
    )
    assert translate._load_checkpoint(path, [changed]) == {}
    german = translate._checkpoint_path(tmp_path, "manual", "german")
    assert not german.exists()
