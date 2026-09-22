"""Inspection: slugs, document classification, section map, protected-block continuations."""

from __future__ import annotations

import contextlib
import json
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path

import pymupdf

from pdfprep.ui import PdfPrepError, warn

MB = 1_000_000
TEXT_PAGE_MIN_CHARS = 20
ARTIFACT_MARKERS = ("--part_", "--manifest.", "--document", "--translated", "--compressed")

_CYRILLIC = {
    "а": "a",
    "б": "b",
    "в": "v",
    "г": "g",
    "д": "d",
    "е": "e",
    "ё": "e",
    "ж": "zh",
    "з": "z",
    "и": "i",
    "й": "y",
    "к": "k",
    "л": "l",
    "м": "m",
    "н": "n",
    "о": "o",
    "п": "p",
    "р": "r",
    "с": "s",
    "т": "t",
    "у": "u",
    "ф": "f",
    "х": "h",
    "ц": "ts",
    "ч": "ch",
    "ш": "sh",
    "щ": "sch",
    "ъ": "",
    "ы": "y",
    "ь": "",
    "э": "e",
    "ю": "yu",
    "я": "ya",
}


def slugify(text: str, limit: int = 40) -> str:
    lowered = "".join(_CYRILLIC.get(char, char) for char in text.lower())
    ascii_text = unicodedata.normalize("NFKD", lowered).encode("ascii", "ignore").decode()
    cleaned = re.sub(r"[^a-z0-9]+", "-", ascii_text).strip("-")
    return (cleaned[:limit].rstrip("-")) or "untitled"


def is_artifact(path: Path) -> bool:
    name = path.name
    return any(marker in name for marker in ARTIFACT_MARKERS)


def discover(task_dir: Path, scope: list[str] | None = None) -> list[Path]:
    """Every source PDF under task_dir, artifacts of earlier runs excluded."""
    if not task_dir.is_dir():
        raise PdfPrepError(f"Task directory does not exist: {task_dir}")
    found = sorted(p for p in task_dir.rglob("*.pdf") if p.is_file() and not is_artifact(p))
    if not scope:
        return found
    wanted = [s.lower() for s in scope]
    return [
        p
        for p in found
        if any(w in p.name.lower() or w in str(p.relative_to(task_dir)).lower() for w in wanted)
    ]


@dataclass
class Section:
    page: int  # 0-based
    title: str
    level: int


@dataclass
class DocInfo:
    path: Path
    slug: str
    pages: int
    size_bytes: int
    kind: str  # TextBased | Scanned | ImageBased | Mixed
    has_tables: bool
    has_images: bool
    text_pages: int
    sections: list[Section]
    toc_source: str  # toc_json | bookmarks | heuristic


def open_doc(path: Path) -> pymupdf.Document:
    try:
        doc = pymupdf.open(path)
    except Exception as exc:
        raise PdfPrepError(f"{path.name}: cannot open ({exc})") from exc
    if doc.needs_pass:
        doc.close()
        raise PdfPrepError(f"{path.name}: encrypted, no password supplied")
    if doc.page_count == 0:
        doc.close()
        raise PdfPrepError(f"{path.name}: no pages")
    return doc


def _sections_from_toc_json(path: Path) -> list[Section] | None:
    """A toc.json next to the source: [{"page": 1, "title": "...", "level": 1}, ...]."""
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        warn(f"{path.name}: ignored, cannot parse ({exc})")
        return None
    entries = data.get("sections", data) if isinstance(data, dict) else data
    if not isinstance(entries, list):
        return None
    out: list[Section] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        try:
            page = int(entry.get("page", entry.get("page_number", 0))) - 1
        except (TypeError, ValueError):
            continue
        title = str(entry.get("title", entry.get("name", ""))).strip()
        if page >= 0 and title:
            out.append(Section(page, title, int(entry.get("level", 1) or 1)))
    return out or None


def _sections_from_bookmarks(doc: pymupdf.Document) -> list[Section] | None:
    toc = doc.get_toc(simple=True)
    out = [
        Section(int(page) - 1, str(title).strip(), int(level))
        for level, title, page in toc
        if int(page) >= 1 and str(title).strip()
    ]
    return out or None


def _sections_heuristic(doc: pymupdf.Document) -> list[Section]:
    """Largest-font short line on a page, when it stands out from the body text."""
    sizes: list[float] = []
    per_page: list[tuple[float, str]] = []
    for page in doc:
        best_size, best_text = 0.0, ""
        for block in page.get_text("dict").get("blocks", []):
            for line in block.get("lines", []):
                text = "".join(span.get("text", "") for span in line.get("spans", [])).strip()
                if not text or len(text) > 90:
                    continue
                size = max((span.get("size", 0.0) for span in line.get("spans", [])), default=0.0)
                sizes.append(size)
                if size > best_size:
                    best_size, best_text = size, text
        per_page.append((best_size, best_text))
    if not sizes:
        return [Section(0, "Document", 1)]
    body = sorted(sizes)[len(sizes) // 2]
    out = [
        Section(index, text, 1)
        for index, (size, text) in enumerate(per_page)
        if text and size >= body * 1.15
    ]
    if not out or out[0].page != 0:
        out.insert(0, Section(0, per_page[0][1] or "Document", 1))
    return out


def section_map(
    doc: pymupdf.Document, source: Path, toc_json: Path | None
) -> tuple[list[Section], str]:
    candidate = toc_json if toc_json else source.with_name("toc.json")
    sections = _sections_from_toc_json(candidate)
    if sections:
        return sections, "toc_json"
    sections = _sections_from_bookmarks(doc)
    if sections:
        return sections, "bookmarks"
    return _sections_heuristic(doc), "heuristic"


def classify(doc: pymupdf.Document) -> tuple[str, bool, bool, int]:
    text_pages = 0
    has_images = False
    has_tables = False
    for page in doc:
        # Same threshold as ocr.pages_without_text, so classification and OCR agree on a page
        if len(page.get_text("text").strip()) >= TEXT_PAGE_MIN_CHARS:
            text_pages += 1
        if not has_images and page.get_images(full=True):
            has_images = True
        if not has_tables:
            # find_tables is heuristic and raises on odd content streams
            with contextlib.suppress(Exception):
                has_tables = bool(page.find_tables().tables)
    total = doc.page_count
    if text_pages == 0:
        kind = "Scanned" if has_images else "ImageBased"
    elif text_pages == total and not has_images and not has_tables:
        kind = "TextBased"
    elif text_pages == total:
        kind = "TextBased" if not has_images else "Mixed"
    else:
        kind = "Mixed"
    return kind, has_tables, has_images, text_pages


def inspect(path: Path, toc_json: Path | None = None) -> DocInfo:
    doc = open_doc(path)
    try:
        kind, has_tables, has_images, text_pages = classify(doc)
        sections, toc_source = section_map(doc, path, toc_json)
        return DocInfo(
            path=path,
            slug=slugify(path.stem),
            pages=doc.page_count,
            size_bytes=path.stat().st_size,
            kind=kind,
            has_tables=has_tables,
            has_images=has_images,
            text_pages=text_pages,
            sections=sections,
            toc_source=toc_source,
        )
    finally:
        doc.close()


_LIST_MARKER = re.compile(r"^\s*([-•*‣◦]|\(?\d{1,3}[.)]|[a-z][.)])\s+")


def continuation_pages(doc: pymupdf.Document) -> set[int]:
    """0-based pages that continue a protected block from the previous page.

    Cutting immediately before such a page would split a table, a list or a figure from
    its caption, so these page indexes are not allowed cut points.
    """
    bottom_table: list[bool] = []
    top_table: list[bool] = []
    bottom_image: list[bool] = []
    first_line: list[str] = []
    last_line: list[str] = []

    for page in doc:
        height = page.rect.height or 1.0
        tables = []
        try:
            tables = [t.bbox for t in page.find_tables().tables]
        except Exception:  # heuristic detector; an unparsable page simply has no tables
            tables = []
        bottom_table.append(any(bbox[3] >= height * 0.90 for bbox in tables))
        top_table.append(any(bbox[1] <= height * 0.18 for bbox in tables))
        bottom_image.append(
            any(
                rect.y1 >= height * 0.80
                for xref in (image[0] for image in page.get_images(full=True))
                for rect in page.get_image_rects(xref)
            )
        )
        lines = [line for line in page.get_text("text").splitlines() if line.strip()]
        first_line.append(lines[0] if lines else "")
        last_line.append(lines[-1] if lines else "")

    continues: set[int] = set()
    for index in range(1, doc.page_count):
        if bottom_table[index - 1] and top_table[index]:
            continues.add(index)
            continue
        if bottom_image[index - 1] and first_line[index] and len(first_line[index]) < 140:
            continues.add(index)
            continue
        if _LIST_MARKER.match(first_line[index]) and _LIST_MARKER.match(last_line[index - 1]):
            continues.add(index)
    return continues
