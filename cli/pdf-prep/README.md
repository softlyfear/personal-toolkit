# pdf-prep

> Local PDF toolbox: **compress**, **split for a Claude Project**, **translate**. Drop files into `task/`,
> run one command, take the deliverables out of `result/`.

Nothing leaves the machine except translation requests, and only to the provider you configured. Runs on
Linux and Windows, Python managed entirely by `uv`. Nothing is installed system-wide.

**Jump to:** [install](#install--one-command) · [split](#1-split-for-a-claude-project) ·
[compress](#2-compress-only) · [translate](#3-translate) · [providers](#llm-providers--the-rule) ·
[config](#configuration)

---

## Install — one command

From a clone (or from a copy of this directory placed anywhere):

```bash
bash cli/pdf-prep/install.sh
```

It installs `uv` if missing, creates `.venv` with every dependency, creates `task/`, `result/` and
`config.toml`, installs a `pdf-prep` launcher into `~/.local/bin`, and finishes by running `pdf-prep
doctor`. It downloads nothing from this repository — the directory it ships in is the whole application.
Re-run it to update after `git pull`.

The heavy part is OCR: `easyocr` needs `torch`, and OCR runs many times faster on a GPU. The installer
probes the machine and picks one torch build, all of it inside `.venv`:

| Build | When | Size |
| --- | --- | --- |
| `cuda` | NVIDIA, driver with CUDA 13+, compute capability 7.5+ | several GB |
| `rocm-linux` | Linux, Radeon RX 6800/6900, RX 7600+, RX 9000, Strix Halo | several GB |
| `rocm-windows` | Windows, Radeon RX 7600+ / RX 9000 / PRO W7000+ (AMD's own wheels, Python 3.12) | several GB |
| `cpu` | anything else, and the fallback | a few hundred MB |

A matching GPU is only a candidate: after the install the build must run a convolution and an LSTM on
the device, or the installer falls back to `cpu`. `PDFPREP_TORCH=cpu` skips the probe. The choice is
written into the `pdf-prep` launcher; `pdf-prep doctor` shows the device OCR will use, and
`[ocr] device` in `config.toml` can force `cpu`. A GPU that runs out of memory mid-document hands the
rest of it to the CPU. EasyOCR model weights land in `.work/ocr-models` on first use.

## Use

```bash
pdf-prep split                        # compress, then cut into upload-ready parts
pdf-prep compress                     # compress only
pdf-prep translate --lang russian     # translate (Claude CLI by default)
pdf-prep ocr                          # add a text layer to scans
pdf-prep list                         # what is in task/, without touching it
pdf-prep doctor --llm                 # check environment, paths, fonts and the provider
```

Every command reads all PDFs under `task/` (recursively) and writes straight into `result/`, flat —
no per-document subfolders. Every name carries the source slug, so outputs never collide; two sources
with the same name in different folders (`a/manual.pdf`, `b/manual.pdf`) get the folder in their slug.
`compress` is the exception: its output mirrors the source's folder.
`--scope manual vendor-a` limits a run to matching files or folders. Artifacts of earlier runs
(`--part_`, `--manifest.`, `--translated`) are never picked up as sources.

---

### 1. Split for a Claude Project

```bash
pdf-prep split
```

Each source produces `<slug>--part_001_<Section>.pdf`, …, plus an index in three forms, all directly in
`result/`:

| File | For |
| --- | --- |
| `<slug>--manifest.md` | Claude reading it as a table of contents: overview table, then every section with its page |
| `<slug>--manifest.txt` | the same, without markup |
| `<slug>--manifest.json` | structured lookup |

Upload whichever suits the Project; one is enough. The index holds only what helps *after* upload —
sections with their original page, cut boundaries (`continues_in` / `continues_from`), and caveats about
OCR text or guessed titles. Local-disk fields (paths, sizes) are left out: a Project has no folders, and
the 30 MB check happens here, in the validation table.

Paste [`claude-project-instructions.md`](claude-project-instructions.md) into the Project's
instructions: it tells Claude to navigate by the index, cite original page numbers, follow cut
boundaries, and flag OCR-derived values.

Rules the splitter holds to:

- every part is within **30 MB** and **100 pages** (`[split]` in `config.toml`, or `--max-part-mb` /
  `--max-part-pages`);
- parts cover the source exactly once — no gaps, no overlaps;
- a boundary never cuts a table, a list or a figure away from its caption;
- a part starts at a section start. Sections come from `toc.json` next to the source, else PDF bookmarks,
  else the printed table of contents, else font-size heuristics — the manifest records which, and a
  heuristic run is flagged. A printed contents entry is kept only if its title is found on the page it
  points to, and contents that stop before the second half of the document (one volume of a merged
  manual) are not used. A bookmark named after a file (`95587112.pdf`, common in merged manuals) is
  replaced with the heading printed on its page. The heuristic ignores text repeated on a quarter of the
  pages or more — running headers and logos — and a line that starts with such text, as a footer merged
  with its page number does.
  After OCR the section map is rebuilt from the new text layer.

A re-run replaces its own previous output for that source (parts, manifests, Markdown), because different
limits produce differently named files and stale parts would otherwise pile up. Output of the other
commands in the same folder — translations, compressed copies — is left alone.

Each part also carries the slice of the source outline that falls inside it, so bookmarks survive the split.
Interactive form fields and named destinations are copied with `add_pages_from`, not `pages.extend`, which
drops both.

Where no boundary satisfies all of that, the part is flagged in the manifest (`section_split` /
`forced_split` with a reason) rather than silently moved. A scanned source is OCR'd first so the sections
and protected blocks can be detected at all.

By default every page without a readable text layer is OCR'd before the split — scans, drawings, and pages
whose fonts extract as noise (no Unicode map). Typeset pages are left alone, so the cost is proportional to
the pages that actually need it: minutes of CPU for a manual with a few hundred drawings.

```bash
pdf-prep split --ocr auto       # OCR only a document that has no text layer at all
pdf-prep split --ocr never      # skip OCR entirely
```

The document is compressed before it is cut, and a part that still exceeds 30 MB is recompressed on its own.
Every run ends with a validation table: size, pages, coverage, unique names, files in place, index files
(all three present and listing every part), source unchanged.

### 2. Compress only

```bash
pdf-prep compress
```

The output keeps the source's file name and folder: `task/vendor/manual.pdf` becomes
`result/vendor/manual.pdf`. Two passes run
on every file:

| Pass       | What it does                                                                                                                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `lossless` | Object/xref streams, stream recompression, image deduplication, orphan removal. Rendered pixels, extractable text and interactive content stay identical — and that is **verified**, not assumed. |
| `lossy`    | Rasters above `target_dpi` (200) are re-encoded as JPEG at `jpeg_quality` (85). Text, vectors, annotations and the outline are untouched.                                                         |

The lossless result is the floor: the lossy output is delivered only when it is smaller *and* passes
acceptance. Tune `target_dpi` / `jpeg_quality` in `config.toml` if the default trade-off is wrong for your
documents — lower means smaller and softer.

Acceptance runs on the written file: page count and geometry, character-identical text, pixel identity
(lossless only, sampled pages at `verify_dpi`), annotation/embedded-file/outline counts, and render
integrity. A lossy output that fails is dropped back to the lossless one; a lossless one that fails is not
delivered at all. If the output is not smaller, the **source is kept** and the run reports "no gain" — a
bigger file is never presented as a win.

### 3. Translate

```bash
pdf-prep translate --lang russian --format markdown
pdf-prep translate --lang german --format docx --pages 1-40
pdf-prep translate --lang russian --format pdf --glossary terms.txt
```

Text is extracted into typed blocks with stable ids (`p12_b3`) and geometry, translated in chunks, then
rendered:

| Format     | Result                                                                                                                                                                                       |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `markdown` | Safest structurally, no visual fidelity                                                                                                                                                      |
| `docx`     | Headings, lists, paragraphs via `python-docx`                                                                                                                                                |
| `pdf`      | In-place overlay: source text boxes are erased and the translation drawn into the same boxes, shrinking the font before it overflows. Needs a TTF covering the target script (DejaVu/Liberation/Arial found automatically; otherwise set `PDFPREP_FONT`) |

A checkpoint is written after every chunk, so an interrupted run resumes where it stopped (`--no-resume` to
start over). Text inside the PDF is treated as **data**: instruction-like content is reported as an ignored
finding, never acted on. The run ends with quality gates: block coverage, unresolved blocks, deliverable
present, layout overflow, URL preservation.

---

## LLM providers — the rule

Only translation calls a model. One rule governs all of them:

> Claude is the default and needs no API key. Any other backend is opt-in, and its key is read from an
> environment variable only — never from a flag, a file or a command line.

| Provider               | How it authenticates                   | When to use it                    |
| ---------------------- | -------------------------------------- | --------------------------------- |
| `claude-cli` (default) | The `claude` CLI on your subscription  | No API key, no per-token cost     |
| `anthropic-api`        | `ANTHROPIC_API_KEY`                    | Scripted runs, no CLI installed   |
| `openai-compatible`    | `OPENAI_API_KEY` + `base_url`          | OpenAI, OpenRouter, a local server |

Resolution order for every setting: **CLI flag > `PDFPREP_*` env var > `config.toml` > built-in default**.

```bash
pdf-prep translate --lang russian --provider anthropic-api --model claude-sonnet-5
PDFPREP_LLM_PROVIDER=openai-compatible pdf-prep translate --lang russian
```

## Configuration

`config.toml` sits next to this README (gitignored, created from `config.example.toml` by the installer).
It covers paths, split limits, compression dpi and quality, OCR languages, and the LLM block. Every key has
an equivalent flag or `PDFPREP_*` variable.

---

## What this is not

- Not RAG chunking: parts never overlap, and no `chunks.jsonl`, embeddings or bbox coordinates are produced.
- Not a repair tool: an encrypted or corrupted source is reported and skipped, never "fixed".
- Not a system installer: no apt/brew/choco, no Docker, no system Python, no root.
- OCR quality and translation quality are **sampled estimates**, not guarantees. Structure is checked
  automatically; meaning is not.

## Deviations from the source prompts, on purpose

- Compression is applied to the whole document before splitting, and again to any single part that still
  misses the limit — instead of the "under 85% of a limit → compress and repack" loop. Same outcome, one
  pass, far fewer rewrites of the same pages.
- Pixel verification samples pages (`verify_sample_pages`, default 12) at `verify_dpi` (default 150) rather
  than rendering every page at 300 dpi. Set `verify_sample_pages = 0` for every page.
- Deliverables go to `result/`, not next to the source in `task/`, so sources stay a clean inbox.
  Sources are never modified — the validation table checks their byte size at the end.
