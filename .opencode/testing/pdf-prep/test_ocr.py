"""Searchable layers must survive OCR model failures without changing the scanned image."""

from __future__ import annotations

from types import SimpleNamespace

import pymupdf
import pytest
import torch
from pdfprep import ocr
from pdfprep.ui import PdfPrepError

BOX = ((20, 30), (500, 30), (500, 70), (20, 70))


@pytest.fixture(autouse=True)
def isolated_models(monkeypatch):
    monkeypatch.setattr(ocr, "_READERS", {})
    monkeypatch.setattr(ocr, "_RECOGNIZERS", {})


def scanned(page, _number):
    page.draw_rect(pymupdf.Rect(50, 50, 200, 200), color=(0.5, 0.5, 0.5))


def test_searchable_layer_preserves_pixels_and_skips_readable_pages(
    make_pdf, tmp_path, monkeypatch
):
    def fill(page, number):
        if number == 1:
            page.insert_text((72, 100), "Existing text must stay intact.")
        elif number == 0:
            scanned(page, number)

    source = make_pdf("mixed", 3, fill)
    original = source.read_bytes()
    replies = iter([[(BOX, "Привод AB-1050-X")], []])
    monkeypatch.setattr(ocr, "_read_page", lambda *_args: next(replies))
    dst = tmp_path / "searchable.pdf"

    assert ocr.add_text_layer(source, dst, ("en", "ru"), tmp_path, "cpu") == (1, ocr.ENGINE)
    assert source.read_bytes() == original
    with pymupdf.open(source) as before, pymupdf.open(dst) as after:
        assert "Привод AB-1050-X" in after[0].get_text()
        assert after[0].search_for("AB-1050-X")
        assert after[1].get_text() == before[1].get_text()
        assert after[2].get_text() == ""
        assert all(
            a.get_pixmap().samples == b.get_pixmap().samples
            for a, b in zip(before, after, strict=True)
        )


def test_page_count_does_not_depend_on_an_embedded_font(make_pdf, tmp_path, monkeypatch):
    source = make_pdf("scan", 1, scanned)
    monkeypatch.setattr(ocr, "find_font", lambda: None)
    monkeypatch.setattr(ocr, "_read_page", lambda *_args: [(BOX, "Pump AB-1050-X")])

    assert ocr.add_text_layer(source, tmp_path / "out.pdf", ("en",), tmp_path, "cpu")[0] == 1


def test_gpu_failure_retries_the_page_on_cpu_and_keeps_the_remaining_pages_there(
    make_pdf, tmp_path, monkeypatch
):
    source = make_pdf("scan", 2, scanned)
    devices = []
    monkeypatch.setattr(ocr, "_use_gpu", lambda *_args: True)
    ocr._READERS[(("en",), True)] = object()
    ocr._RECOGNIZERS[True] = (object(), object())

    def read_page(_image, _languages, _work_dir, gpu):
        devices.append(gpu)
        if gpu:
            raise RuntimeError("GPU kernel failed")
        return [(BOX, "Motor AB-1050-X")]

    monkeypatch.setattr(ocr, "_read_page", read_page)
    assert ocr.add_text_layer(source, tmp_path / "out.pdf", ("en",), tmp_path)[0] == 2
    assert devices == [True, False, False]
    assert not ocr._READERS
    assert not ocr._RECOGNIZERS


def test_failed_cpu_ocr_does_not_deliver_a_partial_file(make_pdf, tmp_path, monkeypatch):
    source = make_pdf("scan", 1, scanned)
    original = source.read_bytes()
    dst = tmp_path / "out.pdf"

    def failed(*_args):
        raise RuntimeError("CPU inference failed")

    monkeypatch.setattr(ocr, "_read_page", failed)
    with pytest.raises(RuntimeError, match="CPU inference failed"):
        ocr.add_text_layer(source, dst, ("en",), tmp_path, "cpu")
    assert not dst.exists()
    assert source.read_bytes() == original


def test_a_readable_document_never_loads_the_models(make_pdf, tmp_path, monkeypatch):
    source = make_pdf(
        "typed",
        1,
        lambda page, _: page.insert_text((72, 100), "Existing text must stay intact."),
    )

    def unexpected(*_args):
        pytest.fail("A readable page must not invoke OCR")

    monkeypatch.setattr(ocr, "_read_page", unexpected)
    assert ocr.add_text_layer(source, tmp_path / "out.pdf", ("en",), tmp_path)[0] == 0


def test_isolated_letters_join_their_line_without_joining_distant_columns():
    class Detector:
        def detect(self, _image, **_kwargs):
            return [
                [
                    [0, 100, 10, 30],
                    [112, 120, 11, 29],
                    [130, 210, 10, 30],
                    [0, 100, 60, 80],
                    [300, 400, 60, 80],
                ]
            ], [[]]

    boxes = ocr._text_boxes(None, Detector())
    assert boxes == [
        ((0, 10), (210, 10), (210, 30), (0, 30)),
        ((0, 60), (100, 60), (100, 80), (0, 80)),
        ((300, 60), (400, 60), (400, 80), (300, 80)),
    ]


def test_math_is_searchable_without_changing_plain_backslashes():
    assert "×" in ocr._plain_text(r"\(U = I \times R\)")
    assert ocr._plain_text(r"C:\parts\AB-1050-X") == r"C:\parts\AB-1050-X"


class FakeProcessor:
    def __init__(self):
        self.batches = []

    def apply_chat_template(self, messages, **kwargs):
        assert kwargs["enable_thinking"] is False
        assert kwargs["processor_kwargs"]["padding"] is True
        self.batches.append(len(messages))

        class Inputs(dict):
            def to(self, _device):
                return self

        return Inputs(input_ids=torch.ones((len(messages), 3), dtype=torch.long))

    def batch_decode(self, tokens, **_kwargs):
        return [r"\(U = I \times R\)"] * len(tokens)


class FakeModel:
    generation_config = SimpleNamespace(eos_token_id=[2, 3])

    def __init__(self, truncated=False):
        self.truncated = truncated

    def generate(self, input_ids, **_kwargs):
        end = 9 if self.truncated else 2
        return torch.tensor([[1, 1, 1, 7, end]] * len(input_ids))


@pytest.mark.parametrize(("gpu", "expected"), [(True, [8, 1]), (False, [1] * 9)])
def test_batched_transcription_preserves_one_response_per_crop(monkeypatch, gpu, expected):
    processor = FakeProcessor()
    monkeypatch.setattr(ocr, "_recognizer", lambda _gpu: (processor, FakeModel()))
    result = ocr._transcribe([object()] * 9, gpu)
    assert processor.batches == expected
    assert len(result) == 9
    assert all("×" in text and "\\times" not in text for text in result)


def test_truncated_generation_is_rejected(monkeypatch):
    monkeypatch.setattr(
        ocr, "_recognizer", lambda _gpu: (FakeProcessor(), FakeModel(truncated=True))
    )
    with pytest.raises(PdfPrepError, match="truncated"):
        ocr._transcribe([object()], False)
