"""Searchable scans: CRAFT locates text, Xiaomi-OCR-0 transcribes it locally."""

from __future__ import annotations

import re
from pathlib import Path

import pymupdf

from pdfprep.fonts import find_font
from pdfprep.pdfdoc import text_layer
from pdfprep.ui import PdfPrepError, info, warn

RENDER_DPI = 200
ENGINE = "xiaomi-ocr-0"
MODEL_ID = "xiaomi-research/Xiaomi-OCR-0"
MODEL_REVISION = "bbd8cf8d21f256b3644b44cb860f3a7cecb93c30"
BATCH_SIZE = 8
MAX_NEW_TOKENS = 512
GPU_MIN_FREE_BYTES = 6 * 1024**3
_READERS: dict[tuple[tuple[str, ...], bool], object] = {}
_RECOGNIZERS: dict[bool, tuple[object, object]] = {}


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
    info("Loading the CRAFT text detector — first run downloads model weights")
    _READERS[(languages, gpu)] = easyocr.Reader(
        list(languages),
        gpu=gpu,
        recognizer=False,
        model_storage_directory=str(model_dir),
        user_network_directory=str(model_dir),
        verbose=False,
    )
    return _READERS[(languages, gpu)]


def _recognizer(gpu: bool):
    if gpu in _RECOGNIZERS:
        return _RECOGNIZERS[gpu]
    try:
        import torch
        from transformers import AutoModelForImageTextToText, AutoProcessor
    except ImportError as exc:
        raise PdfPrepError("transformers is not installed — run the pdf-prep installer") from exc
    info("Loading Xiaomi-OCR-0 — first run downloads about 1.7 GB to the Hugging Face cache")
    dtype = torch.float32
    if gpu:
        dtype = torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    try:
        processor = AutoProcessor.from_pretrained(MODEL_ID, revision=MODEL_REVISION)
        processor.tokenizer.padding_side = "left"
        model = (
            AutoModelForImageTextToText.from_pretrained(
                MODEL_ID, revision=MODEL_REVISION, dtype=dtype, attn_implementation="sdpa"
            )
            .to("cuda" if gpu else "cpu")
            .eval()
        )
    except OSError as exc:
        raise PdfPrepError(f"Cannot load Xiaomi-OCR-0: {exc}") from exc
    _RECOGNIZERS[gpu] = (processor, model)
    return processor, model


def _text_boxes(image, reader):
    horizontal, free = reader.detect(image, min_size=10)
    rows = []
    for x0, x1, y0, y1 in sorted(horizontal[0], key=lambda box: (box[2] + box[3]) / 2):
        center = (y0 + y1) / 2
        row = next((r for r in rows if abs(r[0] - center) <= 0.45 * min(r[1], y1 - y0)), None)
        if row is None:
            rows.append((center, y1 - y0, [[x0, x1, y0, y1]]))
        else:
            row[2].append([x0, x1, y0, y1])
    merged = []
    for _, _, row in rows:
        current = None
        for box in sorted(row, key=lambda item: item[0]):
            # A letter such as Cyrillic "и" is ambiguous alone; preserve its line context.
            if current is not None and box[0] - current[1] <= 2 * min(
                box[3] - box[2], current[3] - current[2]
            ):
                current[1] = max(current[1], box[1])
                current[2] = min(current[2], box[2])
                current[3] = max(current[3], box[3])
            else:
                current = list(box)
                merged.append(current)
    return [((x0, y0), (x1, y0), (x1, y1), (x0, y1)) for x0, x1, y0, y1 in merged] + free[0]


def _plain_text(text: str) -> str:
    from pylatexenc.latex2text import LatexNodes2Text

    # Region transcription can still return LaTeX; PDF search needs the visible symbols.
    text = re.sub(
        r"\\\((.*?)\\\)|\\\[(.*?)\\\]",
        lambda match: LatexNodes2Text().latex_to_text(
            match[1] if match[1] is not None else match[2]
        ),
        text,
        flags=re.DOTALL,
    )
    return " ".join(text.split())


def _transcribe(crops: list, gpu: bool) -> list[str]:
    import torch

    processor, model = _recognizer(gpu)
    batch_size = BATCH_SIZE if gpu else 1
    texts = []
    for offset in range(0, len(crops), batch_size):
        messages = [
            [
                {
                    "role": "user",
                    "content": [
                        {"type": "image", "image": crop},
                        {"type": "text", "text": "Extract the text in the image."},
                    ],
                }
            ]
            for crop in crops[offset : offset + batch_size]
        ]
        inputs = processor.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=True,
            enable_thinking=False,
            return_dict=True,
            return_tensors="pt",
            processor_kwargs={"padding": True},
        ).to("cuda" if gpu else "cpu")
        with torch.inference_mode():
            output = model.generate(**inputs, max_new_tokens=MAX_NEW_TOKENS, do_sample=False)
        generated = output[:, inputs["input_ids"].shape[-1] :]
        eos = model.generation_config.eos_token_id
        endings = {eos} if isinstance(eos, int) else set(eos or [])
        if any(not endings.intersection(tokens) for tokens in generated.tolist()):
            raise PdfPrepError(
                "Xiaomi-OCR-0 truncated a text region; refusing an incomplete text layer"
            )
        texts.extend(
            _plain_text(text)
            for text in processor.batch_decode(generated, skip_special_tokens=True)
        )
    return texts


def _read_page(image, languages: tuple[str, ...], work_dir: Path, gpu: bool):
    import numpy as np
    from easyocr.utils import four_point_transform
    from PIL import Image

    boxes = _text_boxes(image, _reader(languages, work_dir / "ocr-models", gpu))
    if not boxes:
        return []
    crops = [
        Image.fromarray(four_point_transform(image, np.asarray(box, dtype="float32")))
        for box in boxes
    ]
    return list(zip(boxes, _transcribe(crops, gpu), strict=True))


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
                found = _read_page(image, languages, work_dir, gpu)
            # torch.OutOfMemoryError and a kernel the ROCm build lacks both land here
            except RuntimeError as exc:
                if not gpu:
                    raise
                warn(f"OCR on the GPU failed on page {index + 1} ({exc}); continuing on the CPU")
                gpu = False
                _READERS.pop((languages, True), None)
                _RECOGNIZERS.pop(True, None)
                found = _read_page(image, languages, work_dir, gpu)
            font_ready = False
            gained_text = False
            for box, text in found:
                if not text.strip():
                    continue
                # Embedded lazily: a blank separator page gains no word and needs no font
                if font_path is not None and not font_ready:
                    page.insert_font(fontname="ocrfont", fontfile=str(font_path))
                    font_ready = True
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
                gained_text = True
            pages_with_text += gained_text
            del pixmap
        # garbage=3 merges duplicate objects and can leave an XObject without /Subtype, which
        # MuPDF then reports as a syntax error on every read; pikepdf compresses this later anyway
        doc.save(dst, garbage=1, deflate=True)
        if words == 0:
            warn(f"{source.name}: OCR recognised no text")
        elif pages_with_text < len(targets):
            info(
                f"{source.name}: {len(targets) - pages_with_text} of {len(targets)} pages "
                "carry no recognisable content (blank or image-free separators)"
            )
        return pages_with_text, ENGINE
    finally:
        doc.close()
