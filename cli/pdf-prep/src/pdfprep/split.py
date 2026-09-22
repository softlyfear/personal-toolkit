"""Splitting a PDF into upload-ready parts for the Files section of a Claude Project.

Every part stays inside both limits, parts cover the source exactly once, and a boundary
falls on a page that starts a section and does not cut a table, list or figure caption.
Where no such boundary exists the part is flagged in the manifest instead of being moved.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from itertools import pairwise
from pathlib import Path

import pikepdf
import pymupdf

from pdfprep import compress
from pdfprep.config import Config
from pdfprep.extract import blocks_to_markdown, extract_blocks
from pdfprep.pdfdoc import MB, DocInfo, Section, continuation_pages, open_doc, slugify
from pdfprep.ui import warn


@dataclass
class Part:
    file: str
    first_page: int  # 0-based inclusive
    last_page: int  # 0-based inclusive
    size_bytes: int
    sections: list[Section]
    forced_split: bool = False
    forced_split_reason: str | None = None
    section_split: bool = False
    # The boundary after this part cuts a section or a protected block in two
    cut_inside: bool = False
    continues_from: str | None = None
    continues_in: str | None = None

    @property
    def chapters(self) -> list[str]:
        return [section.title for section in self.sections]


@dataclass
class SplitResult:
    info: DocInfo
    branch: str
    result_dir: Path
    parts: list[Part] = field(default_factory=list)
    replaced: int = 0
    notes: list[str] = field(default_factory=list)
    ocr_applied: bool = False
    ocr_engine: str | None = None
    compressed_from: int = 0
    compressed_to: int = 0


def _write_range(
    source: Path, first: int, last: int, dst: Path, sections: list[Section] | None = None
) -> int:
    # add_pages_from, not pages.extend: the latter drops AcroForm fields and named
    # destinations, which pikepdf reports as a PageCopyWarning on any document that has them
    with pikepdf.open(source) as src, pikepdf.Pdf.new() as out:
        out.add_pages_from(src, range(first, last + 1))
        out.save(
            dst,
            compress_streams=True,
            object_stream_mode=pikepdf.ObjectStreamMode.generate,
            deterministic_id=True,
        )
    if sections is not None:
        _carry_bookmarks(dst, sections, first, last)
    return dst.stat().st_size


def _carry_bookmarks(part: Path, sections: list[Section], first: int, last: int) -> None:
    """Re-attach the slice of the source outline that falls inside this part."""
    inside = [section for section in sections if first <= section.page <= last]
    if not inside:
        return
    # set_toc rejects an outline that does not start at level 1 or that skips a level,
    # and a slice of a larger document routinely does both
    entries: list[list] = []
    previous = 0
    for section in inside:
        level = 1 if not entries else min(section.level, previous + 1)
        entries.append([max(1, level), section.title, section.page - first + 1])
        previous = max(1, level)
    doc = pymupdf.open(part)
    try:
        doc.set_toc(entries)
        doc.saveIncr()
    except Exception as exc:  # a part without its outline is still a valid deliverable
        warn(f"{part.name}: could not carry the outline ({exc})")
    finally:
        doc.close()


def _largest_fitting(source: Path, start: int, hi: int, limit: int, probe: Path) -> int:
    """Largest last-page index in [start, hi] whose part stays within `limit` bytes."""
    if _write_range(source, start, start, probe) > limit:
        return start
    low, high, best = start, hi, start
    while low <= high:
        mid = (low + high) // 2
        if _write_range(source, start, mid, probe) <= limit:
            best, low = mid, mid + 1
        else:
            high = mid - 1
    return best


def _unique_slug(title: str, used: set[str]) -> str:
    slug = base = slugify(title)
    suffix = 2
    while slug in used:
        slug = f"{base}-{suffix}"
        suffix += 1
    used.add(slug)
    return slug


def _part_sections(sections: list[Section], first: int, last: int) -> list[Section]:
    """Every section opening inside the part; a part that opens mid-section also gets the
    section it continues, first, with that section's own (earlier) start page."""
    inside = [s for s in sections if first <= s.page <= last]
    if inside and inside[0].page == first:
        return inside
    before = [s for s in sections if s.page < first]
    lead = [before[-1]] if before else []
    return (lead + inside) or [Section(first, "Untitled", 1)]


def _plan_parts(
    source: Path,
    total: int,
    section_pages: set[int],
    continues: set[int],
    max_pages: int,
    limit_bytes: int,
    probe: Path,
) -> list[tuple[int, int, bool, bool, str | None, bool]]:
    """-> list of (first, last, section_split, forced_split, forced_reason, cut_inside)."""
    plan: list[tuple[int, int, bool, bool, str | None, bool]] = []
    start = 0
    while start < total:
        hi = min(start + max_pages, total) - 1
        last = _largest_fitting(source, start, hi, limit_bytes, probe)
        section_split = False
        forced = False
        cut_inside = False
        reason: str | None = None

        if last < total - 1:
            snapped = next(
                (
                    page - 1
                    for page in range(last + 1, start, -1)
                    if page not in continues and page in section_pages
                ),
                None,
            )
            if snapped is None:
                snapped = next(
                    (page - 1 for page in range(last + 1, start, -1) if page not in continues),
                    None,
                )
                section_split = snapped is not None
            if snapped is None:
                forced = True
                cut_inside = True
                reason = (
                    "no allowed cut point between the section start and the size/page limit; "
                    "a protected block spans the whole span"
                )
            else:
                last = snapped
                cut_inside = section_split

        if last < start:
            last = start
        if last == start and _write_range(source, start, start, probe) > limit_bytes:
            forced = True
            reason = "a single page exceeds the size limit even after compression"
        plan.append((start, last, section_split, forced, reason, cut_inside))
        start = last + 1
    return plan


# The index is read by Claude inside a Project, after upload: there are no folders there, and
# the size of a part matters only before upload. So it carries what helps to find and cite
# content — sections with their pages, cut boundaries, text-quality caveats — and nothing
# about the local disk. The console validation table still reports sizes.

INDEX_SUFFIXES = ("json", "md", "txt")


def _page(section: Section, branch: str) -> int | None:
    return None if branch == "B" else section.page + 1


def _manifest_payload(result: SplitResult) -> dict:
    return {
        "source_file": result.info.path.name,
        "total_pages": result.info.pages,
        "toc_source": result.info.toc_source,
        "ocr_applied": result.ocr_applied,
        "parts": [
            {
                "file": part.file,
                "pages_original": (
                    None if result.branch == "B" else [part.first_page + 1, part.last_page + 1]
                ),
                "chapters": [
                    {"title": s.title, "page": _page(s, result.branch)} for s in part.sections
                ],
                "forced_split": part.forced_split,
                "forced_split_reason": part.forced_split_reason,
                "section_split": part.section_split,
                "continues_from": part.continues_from,
                "continues_in": part.continues_in,
            }
            for part in result.parts
        ],
    }


def _caveats(result: SplitResult) -> list[str]:
    info = result.info
    lines: list[str] = []
    if info.toc_source == "bookmarks":
        line = "Section titles come from the PDF's bookmarks."
        if info.renamed_sections:
            line += (
                f" {info.renamed_sections} of them were file names and were replaced with the"
                " heading printed on their page; a bare number or drawing code is a bookmark"
                " whose page has no readable heading."
            )
        lines.append(line)
    elif info.toc_source == "heuristic":
        lines.append(
            "Section titles were inferred from font size: expect some to be missing and a few"
            " to be figure labels rather than headings."
        )
    else:
        lines.append("Section titles come from a supplied toc.json.")
    if result.ocr_applied:
        lines.append(
            f"The text layer was produced by OCR ({result.ocr_engine}): numbers, part codes,"
            " units and quoted wording may be misrecognised — check the page image before"
            " relying on them."
        )
    return lines


def _span(part: Part) -> str:
    return f"{part.first_page + 1}–{part.last_page + 1}"


def _continuation_note(part: Part) -> str | None:
    if not part.continues_in:
        return None
    what = "a table, list or figure" if part.forced_split else "a section"
    return f"The last page cuts {what} in two; it continues in `{part.continues_in}`."


def _index_markdown(result: SplitResult) -> str:
    info, branch = result.info, result.branch
    count = len(result.parts)
    kind = ("PDF part" if branch == "A" else "Markdown file") + ("s" if count != 1 else "")
    out = [f"# {info.path.name} — index", ""]
    intro = f"{info.pages} pages, split into {count} {kind} for this Project."
    if branch == "A":
        intro += (
            " All page numbers are those of the original document: page K inside a part is"
            " original page (the part's first page + K − 1)."
        )
    out += [intro, "", *(f"- {line}" for line in _caveats(result)), ""]

    if branch == "A":
        out += ["| Part | Pages | Opens with | File |", "|---:|---|---|---|"]
        for number, part in enumerate(result.parts, start=1):
            out.append(f"| {number} | {_span(part)} | {part.chapters[0]} | `{part.file}` |")
        out.append("")

    for number, part in enumerate(result.parts, start=1):
        heading = f"## Part {number}"
        if branch == "A":
            heading += f" · pages {_span(part)}"
        out += [heading, "", f"`{part.file}`", ""]
        for section in part.sections:
            indent = "  " * (max(1, section.level) - 1)
            if branch == "B":
                out.append(f"{indent}- {section.title}")
            elif section.page < part.first_page:
                out.append(f"{indent}- {section.title} — continued from p. {section.page + 1}")
            else:
                out.append(f"{indent}- p. {section.page + 1} — {section.title}")
        if part.continues_from:
            out += ["", f"> Opens mid-way: the first page continues `{part.continues_from}`."]
        if note := _continuation_note(part):
            out += ["", f"> {note}"]
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def _index_text(result: SplitResult) -> str:
    """The same index as plain text: no markup, one line per section, easy to grep."""
    info, branch = result.info, result.branch
    out = [f"{info.path.name} — index", ""]
    count = len(result.parts)
    out.append(f"{info.pages} pages, {count} part{'s' if count != 1 else ''}.")
    if branch == "A":
        out.append(
            "Page numbers are the original document's; page K inside a part ="
            " the part's first page + K - 1."
        )
    out += [*_caveats(result), ""]
    for number, part in enumerate(result.parts, start=1):
        span = f"  pages {part.first_page + 1}-{part.last_page + 1}" if branch == "A" else ""
        out.append(f"PART {number}{span}  {part.file}")
        for section in part.sections:
            indent = "  " * max(1, section.level)
            if branch == "B":
                out.append(f"{indent}{section.title}")
            elif section.page < part.first_page:
                out.append(f"{indent}(continued from p.{section.page + 1}) {section.title}")
            else:
                out.append(f"{indent}p.{section.page + 1:<5} {section.title}")
        if part.continues_from:
            out.append(f"  <- opens mid-way, continues {part.continues_from}")
        if part.continues_in:
            out.append(f"  -> cut at the end, continues in {part.continues_in}")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def write_manifest(result: SplitResult) -> None:
    """Three renderings of one index; which to upload is the operator's call.

    json for structured lookup, md for Claude to read as a table of contents, txt for the
    same content without markup.
    """
    renderings = {
        "json": json.dumps(_manifest_payload(result), ensure_ascii=False, indent=2) + "\n",
        "md": _index_markdown(result),
        "txt": _index_text(result),
    }
    for suffix, text in renderings.items():
        (result.result_dir / f"{result.info.slug}--manifest.{suffix}").write_text(
            text, encoding="utf-8"
        )


def _check_index(result: SplitResult, names: list[str]) -> tuple[str, str, str]:
    """All three renderings exist, the json lists exactly the delivered files, and the md
    and txt mention every one of them."""
    paths = {s: result.result_dir / f"{result.info.slug}--manifest.{s}" for s in INDEX_SUFFIXES}
    missing = [s for s, path in paths.items() if not path.is_file()]
    if missing:
        return ("index files", "fail", f"missing manifest.{', manifest.'.join(missing)}")
    try:
        listed = [p["file"] for p in json.loads(paths["json"].read_text("utf-8"))["parts"]]
    except (ValueError, KeyError, TypeError) as exc:
        return ("index files", "fail", f"manifest.json unreadable ({exc})")
    if listed != names:
        return ("index files", "fail", "manifest.json parts differ from the delivered files")
    for suffix in ("md", "txt"):
        text = paths[suffix].read_text("utf-8")
        absent = [name for name in names if name not in text]
        if absent:
            return ("index files", "fail", f"manifest.{suffix} omits {absent[0]}")
    return ("index files", "pass", f"json, md, txt list all {len(names)} files")


def validate(result: SplitResult, cfg: Config) -> list[tuple[str, str, str]]:
    checks: list[tuple[str, str, str]] = []
    limit = cfg.max_part_mb * MB
    oversized = [p.file for p in result.parts if p.size_bytes > limit and not p.forced_split]
    checks.append(
        (
            "size limit",
            "pass" if not oversized else "fail",
            f"max {max((p.size_bytes for p in result.parts), default=0) / MB:.2f} MB "
            f"of {cfg.max_part_mb} MB",
        )
    )
    if result.branch == "A":
        long_parts = [
            p.file
            for p in result.parts
            if (p.last_page - p.first_page + 1) > cfg.max_part_pages and not p.forced_split
        ]
        pages_max = max(
            (p.last_page - p.first_page + 1 for p in result.parts),
            default=0,
        )
        checks.append(
            (
                "page limit",
                "pass" if not long_parts else "fail",
                f"max {pages_max} of {cfg.max_part_pages} pages",
            )
        )
        covered = sum(p.last_page - p.first_page + 1 for p in result.parts)
        ordered = all(
            result.parts[i].last_page + 1 == result.parts[i + 1].first_page
            for i in range(len(result.parts) - 1)
        )
        checks.append(
            (
                "coverage",
                "pass" if covered == result.info.pages and ordered else "fail",
                f"{covered} of {result.info.pages} pages, "
                f"{'no gaps or overlaps' if ordered else 'gap or overlap detected'}",
            )
        )
        expected_marks = sum(
            1
            for section in result.info.sections
            for part in result.parts
            if part.first_page <= section.page <= part.last_page
        )
        carried = 0
        for part in result.parts:
            path = result.result_dir / part.file
            if not path.is_file():
                continue
            doc = pymupdf.open(path)
            carried += len(doc.get_toc(simple=True))
            doc.close()
        checks.append(
            (
                "outline carried",
                "pass" if carried >= expected_marks else "fail",
                f"{carried} of {expected_marks} bookmarks re-attached to the parts",
            )
        )
    else:
        checks.append(("page limit", "n/a", "Branch B, Markdown output"))
        checks.append(("coverage", "n/a", "Branch B, pages_original is null"))
        checks.append(("outline carried", "n/a", "Branch B, Markdown output"))

    names = [p.file for p in result.parts]
    checks.append(
        (
            "unique names",
            "pass" if len(names) == len(set(names)) else "fail",
            f"{len(names)} files",
        )
    )
    present = [name for name in names if (result.result_dir / name).is_file()]
    checks.append(
        (
            "files in place",
            "pass" if len(present) == len(names) else "fail",
            f"{len(present)} of {len(names)} in {result.result_dir}",
        )
    )
    checks.append(_check_index(result, names))
    checks.append(
        (
            "source intact",
            "pass" if result.info.path.stat().st_size == result.info.size_bytes else "fail",
            f"{result.info.size_bytes} bytes at intake",
        )
    )
    return checks


def _branch_b(doc: pymupdf.Document, result: SplitResult, cfg: Config) -> None:
    blocks = extract_blocks(doc)
    markdown = blocks_to_markdown(blocks, result.info.path.stem)
    limit = int(cfg.max_part_mb * MB)
    single = result.result_dir / f"{result.info.slug}--document.md"
    payload = markdown.encode("utf-8")
    if len(payload) <= limit:
        single.write_bytes(payload)
        result.parts.append(
            Part(
                file=single.name,
                first_page=0,
                last_page=doc.page_count - 1,
                size_bytes=len(payload),
                sections=_part_sections(result.info.sections, 0, doc.page_count - 1),
            )
        )
        return

    lines = markdown.splitlines()
    # The document title is the only H1, so splitting on "# " alone would yield one file:
    # cut on the shallowest heading level that actually repeats in the text.
    marker = next(
        (m for m in ("# ", "## ", "### ") if sum(line.startswith(m) for line in lines) > 1),
        "# ",
    )
    chunks: list[tuple[str, list[str]]] = []
    current_title, current_lines = result.info.path.stem, []
    for line in lines:
        if line.startswith(marker):
            if current_lines:
                chunks.append((current_title, current_lines))
            current_title, current_lines = line[len(marker) :].strip(), [line]
        else:
            current_lines.append(line)
    chunks.append((current_title, current_lines))

    used: set[str] = set()
    for index, (title, lines) in enumerate(chunks, start=1):
        name = f"{result.info.slug}--{index:02d}_{_unique_slug(title, used)}.md"
        path = result.result_dir / name
        data = ("\n".join(lines).strip() + "\n").encode("utf-8")
        path.write_bytes(data)
        result.parts.append(
            Part(
                file=name,
                first_page=0,
                last_page=doc.page_count - 1,
                size_bytes=len(data),
                sections=[Section(0, title, 1)],
            )
        )


def _clear_previous_run(result_dir: Path, slug: str) -> int:
    """A re-run with different limits produces different file names; leaving the old ones
    behind would put stale parts next to the new set and skew the validation counts.

    Only what this command writes for this slug is removed — result/ is flat and shared, so a
    translation, a compressed copy, or another document's parts belong to someone else and stay.
    """
    patterns = (
        f"{slug}--part_*.pdf",
        *(f"{slug}--manifest.{suffix}" for suffix in INDEX_SUFFIXES),
        f"{slug}--document.md",
        f"{slug}--[0-9][0-9]_*.md",
    )
    removed = 0
    for pattern in patterns:
        for path in result_dir.glob(pattern):
            if path.is_file():
                path.unlink()
                removed += 1
    return removed


def split_source(source: Path, cfg: Config, doc_info: DocInfo) -> SplitResult:
    result_dir = cfg.result_dir
    result_dir.mkdir(parents=True, exist_ok=True)
    result = SplitResult(info=doc_info, branch="A", result_dir=result_dir)
    result.replaced = _clear_previous_run(result_dir, doc_info.slug)

    branch_b = doc_info.kind == "TextBased" and not doc_info.has_tables and not doc_info.has_images
    if branch_b:
        result.branch = "B"
        doc = open_doc(source)
        try:
            _branch_b(doc, result, cfg)
        finally:
            doc.close()
        write_manifest(result)
        return result

    cfg.work_dir.mkdir(parents=True, exist_ok=True)
    limit_bytes = int(cfg.max_part_mb * MB)
    staged = cfg.work_dir / f"{doc_info.slug}--staged.pdf"
    compressed = compress.compress_file(
        source,
        staged,
        target_dpi=cfg.target_dpi,
        jpeg_quality=cfg.jpeg_quality,
        verify_dpi=cfg.verify_dpi,
        verify_sample=cfg.verify_sample_pages,
        work_dir=cfg.work_dir,
    )
    result.compressed_from = compressed.size_in
    result.compressed_to = compressed.size_out
    if compressed.lossy_applied:
        result.notes.append(
            f"lossy pass applied before splitting: {compressed.images_recoded} images "
            f"downsampled to {cfg.target_dpi} dpi / JPEG q{cfg.jpeg_quality}"
        )

    doc = open_doc(staged)
    try:
        continues = continuation_pages(doc)
        total = doc.page_count
    finally:
        doc.close()
    section_pages = {s.page for s in doc_info.sections} | {0}

    probe = cfg.work_dir / f"{doc_info.slug}--probe.pdf"
    plan = _plan_parts(
        staged, total, section_pages, continues, cfg.max_part_pages, limit_bytes, probe
    )
    if probe.exists():
        probe.unlink()

    used: set[str] = set()
    for index, (first, last, section_split, forced, reason, cut_inside) in enumerate(plan, start=1):
        sections = _part_sections(doc_info.sections, first, last)
        # named after the first section that opens here, not the one it merely continues
        opener = next((s for s in sections if s.page >= first), sections[0])
        name = f"{doc_info.slug}--part_{index:03d}_{_unique_slug(opener.title, used)}.pdf"
        path = result_dir / name
        size = _write_range(staged, first, last, path, doc_info.sections)

        if size > limit_bytes and not forced:
            # The staged source is already downsampled, so this pass only restructures the part;
            # it still helps, because a slice drops resources the whole document shared.
            shrunk = compress.compress_file(
                path,
                path,
                target_dpi=cfg.target_dpi,
                jpeg_quality=cfg.jpeg_quality,
                verify_dpi=cfg.verify_dpi,
                verify_sample=cfg.verify_sample_pages,
                work_dir=cfg.work_dir,
            )
            size = shrunk.size_out
            if size > limit_bytes:
                forced = True
                reason = f"part still {size / MB:.2f} MB after recompression"
            else:
                result.notes.append(f"{name}: recompressed to fit {cfg.max_part_mb} MB")

        result.parts.append(
            Part(
                file=name,
                first_page=first,
                last_page=last,
                size_bytes=size,
                sections=sections,
                forced_split=forced,
                forced_split_reason=reason,
                section_split=section_split,
                cut_inside=cut_inside,
            )
        )

    for part, following in pairwise(result.parts):
        if part.cut_inside:
            part.continues_in = following.file
            following.continues_from = part.file

    if staged.exists():
        staged.unlink()
    write_manifest(result)
    return result
