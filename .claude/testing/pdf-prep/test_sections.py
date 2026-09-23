"""Where split takes its section titles from: printed contents first, then font sizes."""

from __future__ import annotations

import pymupdf
from pdfprep import pdfdoc

from conftest import BODY, body_text

FOOTER = "Acme Detection Systems, Inc. - Proprietary"


def test_footer_merged_with_its_page_number_is_not_a_section(make_pdf) -> None:
    # "...Proprietary" and "Page N of 12" are two lines on most pages and one on the last few;
    # the merged line used to open a section on every page it appeared on
    def fill(page: pymupdf.Page, number: int) -> None:
        if number in (0, 6):
            page.insert_text((72, 100), f"Chapter {number // 6 + 1} Overview", fontsize=18)
        body_text(page)
        if number < 8:
            page.insert_text((72, 800), FOOTER, fontsize=14)
            page.insert_text((72, 816), f"Page {number + 1} of 12", fontsize=10)
        else:
            page.insert_text((72, 800), f"{FOOTER} Page {number + 1} of 12", fontsize=14)

    info = pdfdoc.inspect(make_pdf("footer", 12, fill))

    assert info.toc_source == "heuristic"
    assert [(s.page, s.title) for s in info.sections] == [
        (0, "Chapter 1 Overview"),
        (6, "Chapter 2 Overview"),
    ]


CONTENTS = [
    ("1.0", "Introduction", 1),
    ("1.1", "Safety Precautions", 2),
    ("2.0", "Installation", 5),
    ("2.1", "Mounting the Frame", 7),
    ("3.0", "Maintenance", 11),
    ("3.1", "Belt Replacement", 14),
]
# printed page 1 is the third sheet: a cover and the contents page come first
OFFSET = 2


def contents_pdf(make_pdf, entries, pages: int = 18):
    def fill(page: pymupdf.Page, number: int) -> None:
        if number == 1:
            page.insert_text((72, 80), "Contents", fontsize=16)
            y = 110
            for code, title, printed in entries:
                page.insert_text((72, y), code, fontsize=BODY)
                y += 14
                page.insert_text((72, y), f"{title} {'.' * 40} {printed}", fontsize=BODY)
                y += 14
            # a figure caption that wraps: its tail carries the leader and must not be a title
            page.insert_text(
                (72, y),
                "Figure 3 Frame bolts with the torque wrench and",
                fontsize=BODY,
            )
            page.insert_text((72, y + 14), f"extension fitted {'.' * 30} 6", fontsize=BODY)
            return
        body_text(page)
        for code, title, printed in entries:
            if printed - 1 + OFFSET == number:
                # headings at body size: invisible to the font-size heuristic
                page.insert_text((72, 110), f"{code} {title}", fontsize=BODY)

    return make_pdf("contents", pages, fill)


def test_printed_contents_give_the_sections_at_physical_pages(make_pdf) -> None:
    info = pdfdoc.inspect(contents_pdf(make_pdf, CONTENTS))

    assert info.toc_source == "contents"
    assert [(s.page, s.title, s.level) for s in info.sections[1:]] == [
        (printed - 1 + OFFSET, f"{code} {title}", 1 if code.endswith(".0") else 2)
        for code, title, printed in CONTENTS
    ]
    assert not any("extension" in s.title for s in info.sections)


def test_contents_of_one_volume_in_a_merged_document_are_not_used(make_pdf) -> None:
    # the last entry lands on page 16 of 60: the rest would fall into its section
    info = pdfdoc.inspect(contents_pdf(make_pdf, CONTENTS, pages=60))

    assert info.toc_source == "heuristic"


def test_numbered_headings_just_above_body_size_are_sections(make_pdf) -> None:
    # 12 pt headings over 11 pt text fall under the size heuristic's 15% margin, and three
    # headings at one size on one page read as a paragraph to it
    headings = {
        0: [("1 Operation", 14), ("1.1 Switching on", 12)],
        1: [("1.2 Loading trays", 12)],
        5: [("2 Maintenance", 14), ("2.1 Mechanical parts", 14), ("2.2 Electrical parts", 14)],
    }

    def fill(page: pymupdf.Page, number: int) -> None:
        y = 60
        for text, size in headings.get(number, []):
            page.insert_text((72, y), text, fontsize=size)
            y += 24
        if number == 3:
            # numbered list items are set at body size
            page.insert_text((72, y), "1. Check the power supply", fontsize=BODY)
            page.insert_text((72, y + 16), "2. Replace the fuse", fontsize=BODY)
        if number == 7:
            # wiring callouts on a diagram
            page.insert_text((72, y), "5 WHBK =COU+010-P4", fontsize=12)
            page.insert_text((72, y + 16), "24 V DC", fontsize=12)
        body_text(page, top=max(y, 140) + 40)

    info = pdfdoc.inspect(make_pdf("numbered", 8, fill))

    assert info.toc_source == "heuristic"
    assert [(s.page, s.level, s.title) for s in info.sections] == [
        (0, 1, "1 Operation"),
        (0, 2, "1.1 Switching on"),
        (1, 2, "1.2 Loading trays"),
        (5, 1, "2 Maintenance"),
        (5, 2, "2.1 Mechanical parts"),
        (5, 2, "2.2 Electrical parts"),
    ]


def test_a_numbered_line_is_never_the_wrapped_tail_of_the_one_above() -> None:
    lines = [(16.0, "5 MAINTENANCE STEPS"), (16.0, "6 APPENDIX")]

    assert pdfdoc._page_headings(lines, set(), 11.0) == ["5 MAINTENANCE STEPS", "6 APPENDIX"]
    assert pdfdoc._page_headings([(16.0, "HIGH VOLTAGE"), (16.0, "GENERATOR")], set(), 11.0) == [
        "HIGH VOLTAGE GENERATOR"
    ]


OUTLINE = [
    ("1 - INTRODUCTION", 2),
    ("2 - SAFETY PRECAUTIONS", 2),
    ("2.1 - Safety Labels Used", 3),
    ("3 - INSTALLATION and OPERATION", 4),
    ("3.1 - Assembly Procedure", 6),
    ("4 - MAINTENANCE", 9),
    ("4.1 - Cleaning", 11),
]


def test_an_outline_without_page_numbers_is_found_line_by_line(make_pdf) -> None:
    # a contents page that lists the numbered headings but no pages: each entry counts where
    # it opens a line of its own, not where a paragraph merely mentions it
    def fill(page: pymupdf.Page, number: int) -> None:
        if number == 0:
            page.insert_text((72, 100), "TRAY CARRIER", fontsize=24)
            page.insert_text(
                (72, 700), "Model MSTS-M, revision 3, issued for installers", fontsize=BODY
            )
            return
        if number == 1:
            for row, (title, _) in enumerate(OUTLINE):
                page.insert_text((72, 100 + row * 18), title, fontsize=BODY)
            return
        y = 100
        for title, target in OUTLINE:
            if target == number:
                page.insert_text((72, y), title.replace(" - ", "- "), fontsize=BODY)
                y += 20
        if number == 5:
            # between "3 -" on page 4 and the real "3.1 -" on page 6
            page.insert_text((72, y), "See 3.1 - Assembly Procedure before use.", fontsize=BODY)
        body_text(page, top=y + 30)

    info = pdfdoc.inspect(make_pdf("listing", 12, fill))

    assert info.toc_source == "contents"
    assert [(s.page, s.level, s.title) for s in info.sections] == [
        (0, 1, "TRAY CARRIER"),
        *((target, 2 if "." in title.split()[0] else 1, title) for title, target in OUTLINE),
    ]


def test_letter_spaced_text_is_read_as_words(make_pdf) -> None:
    def fill(page: pymupdf.Page, _number: int) -> None:
        page.insert_text((72, 100), "O P E R A T I N G     M A N U A L", fontsize=18)

    doc = pymupdf.open(make_pdf("spaced", 1, fill))

    assert pdfdoc._page_lines(doc[0]) == [(18.0, "OPERATING MANUAL")]
