"""Inspection: slugs, document classification, section map, protected-block continuations."""

from __future__ import annotations

import contextlib
import json
import re
import unicodedata
from dataclasses import dataclass, replace
from pathlib import Path

import pymupdf

from pdfprep.ui import PdfPrepError, warn

MB = 1_000_000
TEXT_PAGE_MIN_CHARS = 20
ARTIFACT_MARKERS = ("--part_", "--manifest.", "--document", "--translated")

# OCR swaps Latin letters for their Cyrillic twins at random: "TCHK" and "ТCHK" are one header
_LOOKALIKES = str.maketrans("аеорсухтнмвк", "aeopcyxthmbk")
_FILE_NAME = re.compile(r"^[\w .()-]+\.(pdf|docx?|xlsx?|pptx?|txt)$", re.IGNORECASE)
_CAPTION = re.compile(r"^(рис|fig|табл|tab)\w*\b", re.IGNORECASE)
_LEADER = re.compile(r"(\.\s?){4,}")
# A font embedded without a Unicode map extracts as control codes and private-use glyphs
_UNDECODED = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\ue000-\uf8ff\ufffd]")
UNDECODED_MAX_RATIO = 0.1

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


def unique_slugs(paths: list[Path], root: Path) -> dict[Path, str]:
    """Slug per source. result/ is flat and every output name starts with the slug, so two
    `manual.pdf` in different folders would overwrite each other's parts — and a re-run's
    cleanup would delete the other's. Clashing names take their folder path into the slug."""
    by_stem: dict[str, list[Path]] = {}
    for path in paths:
        by_stem.setdefault(slugify(path.stem), []).append(path)
    slugs: dict[Path, str] = {}
    used: set[str] = set()
    for stem_slug, group in by_stem.items():
        for path in group:
            if len(group) == 1:
                slug = stem_slug
            else:
                slug = slugify(str(path.relative_to(root).with_suffix("")), limit=60)
            base, suffix = slug, 2
            while slug in used:
                slug, suffix = f"{base}-{suffix}", suffix + 1
            used.add(slug)
            slugs[path] = slug
    return slugs


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
    renamed_sections: int = 0  # bookmarks named after files, replaced with the page heading
    undecoded_pages: tuple[int, ...] = ()  # 0-based; a text layer that is not readable text


def text_layer(page: pymupdf.Page) -> str:
    """ "readable" when the page carries text, "undecoded" when it carries only glyph codes
    (as unreadable as a scan, and it needs OCR just the same), else "none"."""
    text = "".join(page.get_text("text").split())
    if len(text) < TEXT_PAGE_MIN_CHARS:
        return "none"
    if len(_UNDECODED.findall(text)) / len(text) >= UNDECODED_MAX_RATIO:
        return "undecoded"
    return "readable"


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


def _page_lines(page: pymupdf.Page) -> list[tuple[float, str]]:
    """Lines in reading order, each with its largest span size rounded to 0.5 pt.

    Rounding matters for OCR'd pages: every word gets a float size from its own box, so
    two lines of one wrapped title never compare equal without it.
    """
    lines: list[tuple[float, str]] = []
    for block in page.get_text("dict").get("blocks", []):
        for line in block.get("lines", []):
            spans = line.get("spans", [])
            text = " ".join("".join(span.get("text", "") for span in spans).split())
            if text:
                size = max((span.get("size", 0.0) for span in spans), default=0.0)
                lines.append((round(size * 2) / 2, text))
    return lines


def _line_key(text: str) -> str:
    return "".join(text.lower().translate(_LOOKALIKES).split())


def _running_keys(pages: list[list[tuple[float, str]]]) -> set[str]:
    """Headers, footers and logos: text repeated on a quarter of the pages or more.

    A logo is often the largest text on every page; left in, it would open a section on
    each of them.
    """
    counts: dict[str, int] = {}
    for lines in pages:
        for key in {_line_key(text) for _, text in lines}:
            counts[key] = counts.get(key, 0) + 1
    threshold = max(3, len(pages) // 4)
    return {key for key, count in counts.items() if count >= threshold}


def _never_a_title(text: str) -> bool:
    return bool(_LEADER.search(text) or _CAPTION.match(text) or re.search(r"[;:©]", text))


def _is_title(text: str) -> bool:
    letters = [char for char in text if char.isalpha()]
    return len(letters) >= 3 and letters[0].isupper() and text[0].isalnum()


def _opens_lower(text: str) -> bool:
    return next((char.islower() for char in text if char.isalpha()), False)


def _page_headings(lines: list[tuple[float, str]], running: set[str], body: float) -> list[str]:
    """Headings on a page, largest size first; an empty list rather than a guess.

    Size groups are tried top-down while they stand out from the body text, because the
    largest text on a page is often a figure label or a stray OCR fragment and the real
    heading sits one size below it. A wrong title in the index misleads more than a
    missing one, hence every filter here errs towards returning nothing.
    """
    # Filtered before grouping: a bullet glyph or a part number set at the heading's size
    # would otherwise inflate its group into a "paragraph" and hide the heading.
    lines = [
        (size, text)
        for size, text in lines
        if len(text) <= 90
        and sum(char.isalpha() for char in text) >= 3
        and _line_key(text) not in running
        and not _never_a_title(text)
    ]
    for size in sorted({size for size, _ in lines}, reverse=True):
        if size < body * 1.15:
            break
        at_size = [index for index, (s, _) in enumerate(lines) if s == size]
        # three or more lines at one size are a paragraph or a table, not a title
        if len(at_size) > 2:
            continue
        texts = [lines[index][1] for index in at_size]
        wraps = (
            len(at_size) == 2
            and at_size[1] == at_size[0] + 1
            and (_opens_lower(texts[1]) or (texts[0].isupper() and texts[1].isupper()))
        )
        # "HI-" / "SCAN 5180i": a trailing hyphen is a wrap whatever the next line's case
        hyphenated = len(at_size) == 2 and at_size[1] == at_size[0] + 1 and texts[0][-1] == "-"
        if hyphenated:
            texts = ["".join(texts)]
        elif wraps:
            texts = [" ".join(texts)]
        titles = [text.rstrip(" -–—") for text in texts if _is_title(text)]
        if titles:
            return titles
    return []


def _doc_lines(doc: pymupdf.Document) -> tuple[list[list[tuple[float, str]]], set[str], float]:
    """Per-page lines, the running header/footer keys, and the body text size.

    The body size is the median weighted by characters, not by lines: counted per line,
    footers and drawing labels outnumber the body text and every label looks like a heading.
    """
    pages = [_page_lines(page) for page in doc]
    weighted = sorted((size, len(text)) for lines in pages for size, text in lines)
    half = sum(weight for _, weight in weighted) / 2
    body, seen = 0.0, 0
    for size, weight in weighted:
        seen += weight
        if seen >= half:
            body = size
            break
    return pages, _running_keys(pages), body


def _sections_heuristic(doc: pymupdf.Document) -> list[Section]:
    pages, running, body = _doc_lines(doc)
    out: list[Section] = []
    for index, lines in enumerate(pages):
        for title in _page_headings(lines, running, body):
            # a heading repeated on the next page continues its section, it does not open one
            if out and _line_key(out[-1].title) == _line_key(title):
                continue
            out.append(Section(index, title, 1))
    if not out or out[0].page != 0:
        out.insert(0, Section(0, (doc.metadata or {}).get("title") or "Document", 1))
    return out


def resolve_file_titles(doc: pymupdf.Document, sections: list[Section]) -> int:
    """A merged document often carries bookmarks named after the files it was built from
    (`95587112.pdf`). Each one is replaced with the heading printed on its page, or with the
    bare file stem when the page has none. Returns how many bookmarks were renamed."""
    targets = [section for section in sections if _FILE_NAME.match(section.title)]
    if not targets:
        return 0
    pages, running, body = _doc_lines(doc)
    for section in targets:
        headings = []
        if 0 <= section.page < len(pages):
            headings = _page_headings(pages[section.page], running, body)
        section.title = (headings[0] if headings else None) or re.sub(
            r"\.[a-z0-9]{1,4}$", "", section.title, flags=re.IGNORECASE
        )
    return len(targets)


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


def classify(doc: pymupdf.Document) -> tuple[str, bool, bool, int, tuple[int, ...]]:
    text_pages = 0
    undecoded: list[int] = []
    has_images = False
    has_tables = False
    for page in doc:
        # Same test as ocr.pages_without_text, so classification and OCR agree on a page
        layer = text_layer(page)
        if layer == "readable":
            text_pages += 1
        elif layer == "undecoded":
            undecoded.append(page.number)
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
    return kind, has_tables, has_images, text_pages, tuple(undecoded)


def _mapped_sections(
    doc: pymupdf.Document, source: Path, toc_json: Path | None
) -> tuple[list[Section], str, int]:
    sections, toc_source = section_map(doc, source, toc_json)
    renamed = resolve_file_titles(doc, sections) if toc_source == "bookmarks" else 0
    return sections, toc_source, renamed


def remap_sections(info: DocInfo, text_copy: Path) -> DocInfo:
    """Rebuild the section map from a copy that gained a text layer through OCR.

    The map built at intake came from a scan with no text, so it holds one section at most.
    Identity fields (path, size, slug) stay the original source's: they drive the
    source-intact check and the output names.
    """
    doc = open_doc(text_copy)
    try:
        sections, toc_source, renamed = _mapped_sections(doc, info.path, None)
    finally:
        doc.close()
    return replace(info, sections=sections, toc_source=toc_source, renamed_sections=renamed)


def inspect(path: Path, toc_json: Path | None = None) -> DocInfo:
    doc = open_doc(path)
    try:
        kind, has_tables, has_images, text_pages, undecoded = classify(doc)
        sections, toc_source, renamed = _mapped_sections(doc, path, toc_json)
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
            renamed_sections=renamed,
            undecoded_pages=undecoded,
        )
    finally:
        doc.close()


_LIST_MARKER = re.compile(r"^\s*([-•*‣◦]|\(?\d{1,3}[.)]|[a-z][.)])\s+")


def _placed_lines(page: pymupdf.Page) -> list[tuple[float, float, str]]:
    """(top, bottom, text) per line, top to bottom."""
    lines = []
    for block in page.get_text("dict").get("blocks", []):
        for line in block.get("lines", []):
            text = " ".join("".join(s.get("text", "") for s in line.get("spans", [])).split())
            if text:
                lines.append((line["bbox"][1], line["bbox"][3], text))
    return sorted(lines)


def continuation_pages(doc: pymupdf.Document) -> set[int]:
    """0-based pages that continue a protected block from the previous page.

    Cutting immediately before such a page would split a table, a list or a figure from
    its caption, so these page indexes are not allowed cut points. Running headers and
    footers are left out of every test: they sit at the edge of each page, so counting them
    made a third of all pages look like continuations and blocked real section starts.
    """
    placed = [_placed_lines(page) for page in doc]
    running = _running_keys([[(0.0, text) for _, _, text in lines] for lines in placed])
    bottom_table: list[bool] = []
    top_table: list[bool] = []
    bottom_image: list[bool] = []
    first_line: list[str] = []
    last_line: list[str] = []

    for page, lines in zip(doc, placed, strict=True):
        rect = page.rect
        height = rect.height or 1.0
        body = [
            (top, bottom, text)
            for top, bottom, text in lines
            if _line_key(text) not in running and sum(char.isalpha() for char in text) >= 3
        ]
        tables = []
        try:
            tables = [t.bbox for t in page.find_tables().tables]
        except Exception:  # heuristic detector; an unparsable page simply has no tables
            tables = []
        # a drawing border is detected as one page-sized table on every sheet
        tables = [
            bbox
            for bbox in tables
            if not (bbox[2] - bbox[0] >= rect.width * 0.88 and bbox[3] - bbox[1] >= height * 0.88)
        ]
        bottom_table.append(any(bbox[3] >= height * 0.90 for bbox in tables))
        # text above the table means the page opens with something else, e.g. a new heading
        top_table.append(
            any(
                bbox[1] <= height * 0.18 and not any(bottom <= bbox[1] for _, bottom, _ in body)
                for bbox in tables
            )
        )
        bottom_image.append(
            any(
                box.y1 >= height * 0.80
                for xref in (image[0] for image in page.get_images(full=True))
                for box in page.get_image_rects(xref)
            )
        )
        first_line.append(body[0][2] if body else "")
        last_line.append(body[-1][2] if body else "")

    continues: set[int] = set()
    for index in range(1, doc.page_count):
        if bottom_table[index - 1] and top_table[index]:
            continues.add(index)
            continue
        if bottom_image[index - 1] and _CAPTION.match(first_line[index]):
            continues.add(index)
            continue
        if _LIST_MARKER.match(first_line[index]) and _LIST_MARKER.match(last_line[index - 1]):
            continues.add(index)
    return continues
