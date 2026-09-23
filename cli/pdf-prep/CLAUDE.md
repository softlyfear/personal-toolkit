# CLAUDE.md — cli/pdf-prep

Loaded when work touches this directory; the repository-wide rules are in `/.claude/CLAUDE.md`.

## What is easy to break

The second cli tool: compress / split-for-a-Claude-Project / translate, `task/` in, `result/` out —
flat, no per-document subfolders; every output name carries the source slug. Unlike `claude-auto-ping` it is a *packaged* uv project (`package` defaults to true, hatchling,
`src/pdfprep/`, `[project.scripts] pdf-prep`), because the launcher needs a console entry point.
Points that are easy to break:

- `install.sh` runs **from a copy on disk only** — it refuses a `wget`-piped invocation because it
  resolves the project directory from `BASH_SOURCE[0]`. It is Bash, so it is inside `.claude/lint.sh`.
  It writes `PDFPREP_HOME` into the generated `~/.local/bin/pdf-prep` launcher; that is what makes
  `task/`/`result/` resolve from any working directory.
- `torch`/`torchvision` live in four mutually exclusive dependency groups (`cpu`, `cuda`,
  `rocm-linux`, `rocm-windows`), each pinned to its own index in `[tool.uv.sources]`. They are listed
  at all only because sources apply to **direct** dependencies — as transitive deps of `easyocr` the
  pin is ignored and PyPI's CUDA wheels land whatever the machine has. `cpu` is the default group, so
  a bare `uv run` is safe; a GPU build survives only because the launcher that `install.sh` writes passes
  `--no-default-groups --group <build>` — any `uv run` without those flags re-syncs to `cpu`.
  `install.sh` picks the build from the hardware and then proves it on the device (conv + LSTM, what
  EasyOCR is made of), falling back to `cpu`. `rocm-windows` comes from AMD's flat index
  (`repo.radeon.com`, Python 3.12 only), and its `rocm-sdk-*` deps are listed in the group for the
  same direct-dependency reason. `ocr.py` picks the device at run time and moves to the CPU on a GPU
  `RuntimeError` (out of memory, a kernel ROCm lacks). A GPU reader that is already loaded is reused
  without re-checking free memory: its own allocation reads as "not free" and silently pushed every
  document after the first onto the CPU.
- `PYMUPDF_MESSAGE=fd:2` is set in `src/pdfprep/__init__.py` before PyMuPDF loads: MuPDF's notices
  otherwise land on stdout, where the report tables are written.
- Compression has one mode: a lossless pass, then rasters above `target_dpi` re-encoded at
  `jpeg_quality` (200 dpi / q85). It is verified, not assumed: a lossless output must pass
  pixel-identity, text-identity, geometry and feature-count checks, or it is not delivered. A lossy
  output falls back to the lossless one on failure, and an output that is not smaller is discarded
  in favour of the source. `compress` writes `result/<source file name>` unchanged, so it refuses to
  run when that path is the source itself. A lossless output that fails pixel identity is redone
  without `remove_unreferenced_resources()`: pruning a resources dict a page shares with a
  transparency-group form (WeasyPrint) shifts MuPDF's blending by one grey level. `split` treats a
  rejected compression as an optimisation lost and cuts the source as is.
- OCR inserts words with `insert_text`, not `insert_textbox`: a textbox silently drops a word that
  does not fit its own bounding box, which produced an empty text layer for a whole document.
- Parts are built with `Pdf.add_pages_from()`, never `pages.extend()`: the latter drops AcroForm
  fields and named destinations (pikepdf says so via `PageCopyWarning`). The matching outline slice
  is re-attached per part with `set_toc`, whose levels must be renormalised — a slice of a larger
  document routinely starts below level 1 or skips a level, and `set_toc` rejects both.
- `--ocr always` is the default for `split` and `translate` (user's call, 2026-09-23: one run, no
  flags). It OCRs only pages without a *readable* text layer — `pdfdoc.text_layer()` also counts a
  layer of undecoded glyph codes (fonts with no Unicode map, typical of schematics) as unreadable —
  so typeset pages cost nothing. `auto` still exists for a quick run: only a document with no text
  at all.
- LLM providers live in one file with one rule: Claude (`claude-cli`) is the default and needs no
  key; every other backend reads its key from an environment variable only. Resolution order for
  every setting is CLI flag > `PDFPREP_*` env > `config.toml` > built-in default.
- `split` deletes its **own** previous output for that source before writing
  (`_clear_previous_run`), because a re-run with other limits produces other file names and the
  stale parts would be validated as if they belonged to the new set. The pattern list is deliberately
  narrow and slug-scoped: `result/` is shared, so another document's parts, a translation or a
  compressed copy are not ours to delete.
- The split index is written for Claude *inside* a claude.ai Project, not for the local disk:
  `<slug>--manifest.{json,md,txt}` are three renderings of one index for different readers, not
  copies of each other. No paths, no sizes — a Project has no folders, and sizes only matter before
  upload. `chapters` are `{title, page}` objects with the *original* page; `continues_in` /
  `continues_from` link parts whose boundary cuts a section or a table.
  `claude-project-instructions.md` is the matching Project prompt; change both together.
- Section titles (`pdfdoc._page_headings`) err towards returning nothing — a wrong title in the
  index misleads more than a missing one. The body size is the median **weighted by characters**:
  counted per line, footers and drawing labels dominate and every label looks like a heading. Lines
  with fewer than 3 letters are dropped **before** grouping by size, or a bullet glyph set at the
  heading's size hides the heading. Text on a quarter of the pages or more is a running header or
  logo, and so is a line that *starts* with one: a footer and its page number are one line on some
  pages and two on others. Before the heuristic, a printed contents page (dot leaders) is tried:
  each entry must be found on its page under one printed-to-physical offset (60% or the contents
  are dropped), and contents ending before mid-document are dropped — in a merged manual they
  index one volume and would swallow the rest into their last section. Numbered headings ("2.1 …")
  only need to be larger than the body, not 15% larger, and several may share a page — but only
  those on the longest ascending chain of numbers across the document count: procedure steps
  restart at "1." and diagram callouts come in any order. A numbered line is never the wrapped tail
  of the line above it. Bookmarks named after files (`95587112.pdf`, common in merged manuals) take the heading
  printed on their page. After OCR the section map is rebuilt (`remap_sections`): the one built at
  intake came from a scan with no text.
- `task/`, `result/`, `.work/` and `config.toml` are gitignored (`.gitkeep` files excepted) — the
  user's own documents must never enter a commit.
