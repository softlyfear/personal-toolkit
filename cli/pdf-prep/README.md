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

The heavy part is OCR: `easyocr` needs `torch`. `pyproject.toml` pins the **CPU** wheel index, so the
download is a few hundred MB instead of ~2.5 GB. EasyOCR model weights land in `.work/ocr-models` on first
use.

## Use

```bash
pdf-prep split                        # compress, then cut into upload-ready parts
pdf-prep compress --target-mb 20      # compress only
pdf-prep translate --lang russian     # translate (Claude CLI by default)
pdf-prep ocr                          # add a text layer to scans
pdf-prep list                         # what is in task/, without touching it
pdf-prep doctor --llm                 # check environment, paths, fonts and the provider
```

Every command reads all PDFs under `task/` (recursively) and writes to `result/<source-slug>/`.
`--scope manual vendor-a` limits a run to matching files or folders. Artifacts of earlier runs
(`--part_`, `--manifest.`, `--translated`) are never picked up as sources.

---

### 1. Split for a Claude Project

```bash
pdf-prep split
```

Each source gets its own `result/<slug>/` holding `<slug>--part_001_<Section>.pdf`, …, plus
`<slug>--manifest.json` and a byte-identical `<slug>--manifest.txt`.

Rules the splitter holds to:

- every part is within **30 MB** and **100 pages** (`[split]` in `config.toml`, or `--max-part-mb` /
  `--max-part-pages`);
- parts cover the source exactly once — no gaps, no overlaps;
- a boundary never cuts a table, a list or a figure away from its caption;
- a part starts at a section start. Sections come from `toc.json` next to the source, else PDF bookmarks,
  else font-size heuristics — the manifest records which, and a heuristic run is flagged.

A re-run replaces its own previous output for that source (parts, manifests, Markdown), because different
limits produce differently named files and stale parts would otherwise pile up. Output of the other
commands in the same folder — translations, compressed copies — is left alone.

Each part also carries the slice of the source outline that falls inside it, so bookmarks survive the split.
Interactive form fields and named destinations are copied with `add_pages_from`, not `pages.extend`, which
drops both.

Where no boundary satisfies all of that, the part is flagged in the manifest (`section_split` /
`forced_split` with a reason) rather than silently moved. A scanned source is OCR'd first so the sections
and protected blocks can be detected at all.

`--ocr auto` (default) only OCRs a document that has no text layer anywhere. A **mixed** document — typeset
pages plus drawings or scanned inserts — keeps those pages unreadable until you ask for it:

```bash
pdf-prep split --ocr always     # OCR every page that lacks a text layer, then split
pdf-prep split --ocr never      # skip OCR entirely
```

The document is compressed before it is cut, and a part that still exceeds 30 MB is downsampled on its own.
Every run ends with a validation table: size, pages, coverage, unique names, files in place, manifest pair,
source unchanged.

### 2. Compress only

```bash
pdf-prep compress                  # lossless unless config says otherwise
pdf-prep compress --target-mb 20   # allow the lossy pass if 20 MB is still exceeded
pdf-prep compress --profile lossless
```

Three profiles:

| Profile              | What it does                                                                                                                                                                                       |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lossless`           | Object/xref streams, stream recompression, image deduplication, orphan removal. Rendered pixels, extractable text and interactive content stay identical — and that is **verified**, not assumed.   |
| `balanced` (default) | Lossless always; raster downsampling (150 dpi, JPEG q80) only for a file or part that still misses its size target.                                                                                |
| `aggressive`         | Downsample every raster, then the lossless pass on top.                                                                                                                                            |

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
It covers paths, split limits, compression profile and dpi, OCR languages, and the LLM block. Every key has
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
- Deliverables go to `result/<slug>/`, not next to the source in `task/`, so sources stay a clean inbox.
  Sources are never modified — the validation table checks their byte size at the end.
