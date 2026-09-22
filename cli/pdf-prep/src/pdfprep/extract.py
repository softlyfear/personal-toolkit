"""Text extraction into typed blocks with geometry, shared by the Markdown and translate paths."""

from __future__ import annotations

import re
from dataclasses import dataclass

import pymupdf

_LIST_MARKER = re.compile(r"^\s*([-•*‣◦]|\(?\d{1,3}[.)]|[a-z][.)])\s+")
_CODEISH = re.compile(r"^(\s{4,}|\t)|[{};]\s*$")


@dataclass
class Block:
    id: str
    page: int
    bbox: tuple[float, float, float, float]
    kind: str  # heading | paragraph | list | caption | code
    text: str
    size: float
    level: int


def _classify(
    text: str, size: float, body: float, is_bold: bool, line_count: int
) -> tuple[str, int]:
    stripped = text.strip()
    if _LIST_MARKER.match(stripped):
        return "list", 0
    if _CODEISH.search(stripped) and size < body:
        return "code", 0
    if (
        len(stripped) <= 120
        and line_count <= 2
        and (size >= body * 1.12 or (is_bold and size >= body))
    ):
        if size >= body * 1.6:
            level = 1
        elif size >= body * 1.35:
            level = 2
        elif size >= body * 1.15:
            level = 3
        else:
            level = 4
        return "heading", level
    if len(stripped) < 110 and size < body * 0.95:
        return "caption", 0
    return "paragraph", 0


def extract_blocks(doc: pymupdf.Document, pages: range | None = None) -> list[Block]:
    indexes = list(pages) if pages is not None else list(range(doc.page_count))
    sizes: list[float] = []
    raw: list[tuple[int, dict]] = []
    for index in indexes:
        for block in doc[index].get_text("dict").get("blocks", []):
            if block.get("type") != 0:
                continue
            raw.append((index, block))
            for line in block.get("lines", []):
                for span in line.get("spans", []):
                    if span.get("text", "").strip():
                        sizes.append(round(span.get("size", 0.0), 1))
    body = sorted(sizes)[len(sizes) // 2] if sizes else 10.0

    blocks: list[Block] = []
    counters: dict[int, int] = {}
    for page_index, block in raw:
        lines = block.get("lines", [])
        text = "\n".join(
            "".join(span.get("text", "") for span in line.get("spans", [])).rstrip()
            for line in lines
        ).strip()
        if not text:
            continue
        spans = [
            span for line in lines for span in line.get("spans", []) if span.get("text", "").strip()
        ]
        if not spans:
            continue
        size = max(span.get("size", body) for span in spans)
        font = str(spans[0].get("font", ""))
        is_bold = bool(spans[0].get("flags", 0) & 2**4) or "bold" in font.lower()
        kind, level = _classify(text, size, body, is_bold, len(lines))
        counters[page_index] = counters.get(page_index, 0) + 1
        blocks.append(
            Block(
                id=f"p{page_index + 1}_b{counters[page_index]}",
                page=page_index,
                bbox=tuple(round(value, 2) for value in block.get("bbox", (0, 0, 0, 0))),
                kind=kind,
                text=text,
                size=round(size, 2),
                level=level,
            )
        )
    return blocks


def blocks_to_markdown(blocks: list[Block], title: str) -> str:
    out: list[str] = [f"# {title}", ""]
    for block in blocks:
        text = block.text.replace("\n", " ").strip()
        if block.kind == "heading":
            out += ["", "#" * min(6, block.level + 1) + f" {text}", ""]
        elif block.kind == "list":
            out += [f"- {_LIST_MARKER.sub('', line).strip()}" for line in block.text.splitlines()]
        elif block.kind == "code":
            out += ["```", block.text, "```", ""]
        elif block.kind == "caption":
            out += [f"*{text}*", ""]
        else:
            out += [text, ""]
    return "\n".join(out).strip() + "\n"
