# Working with the documents in this Project

This Project's files are technical documents that were too large to upload whole. Each one was
cut into consecutive parts and comes with an index. Answer from these files; they outrank what
you remember about the subject.

## What the files are

- `<doc>--part_NNN_<section>.pdf` — consecutive slices of one source document, in order
  (`part_001`, `part_002`, …). Together they cover every page exactly once, with no overlap.
- `<doc>--manifest.md` / `.txt` / `.json` — the index of that document, in up to three forms
  with the same content: every part, its original page range, and every section with the page
  it starts on. It also states how reliable the section titles and the text layer are.
- `<doc>` is a short slug of the source file name; files sharing it belong to one document.

## How to find an answer

1. **Start from the index.** Match the question to a section title, pick the part whose page
   range holds that section, and read that part. Do not scan every part hoping to hit it.
2. **Read the whole relevant stretch.** A procedure, table or troubleshooting entry often runs
   for several pages; keep reading until it ends, into the next part if needed.
3. **Follow cut boundaries.** When the index says a part continues in the next file
   (`continues_in`, or "The last page cuts … in two"), read the start of that next part before
   answering about anything near the end of the first one.
4. **Check the table of contents pages.** A section called "Contents", "Оглавление" or
   "Содержание" in the first part lists the source's own structure; use it to locate topics
   the index names only by a number or drawing code.
5. **Several documents?** Say which document an answer comes from, and do not merge
   instructions from different documents or equipment models without saying so.

## How to cite

- Cite the document, the section, and the **original** page number: *(100100T_RU, «Поиск и
  устранение неисправностей», p. 512)*.
- A part's own page numbers are not the document's. Page K inside a part is original page
  (the part's first page + K − 1); the index gives each part's first page. Never cite the
  part-local number.
- Quote exact wording for warnings, limits, settings, error codes and part numbers; paraphrase
  the rest.

## How far to trust the text

- **OCR.** If the index says the text layer came from OCR, numbers, units, part codes and
  quoted wording can be misrecognised. When an answer depends on such a value, say it comes
  from OCR text and ask the user to confirm it against the page, giving the page number.
- **Inferred section titles.** If the index says titles were inferred from font size, a title
  may be missing or may be a figure label. Use them to navigate, not as proof of what a
  section covers.
- **Bare numbers as titles** (`95585622`, `Z5535811-E`) are sub-documents or drawings whose
  page had no readable heading. Open the page to see what it is.
- **Drawings and schematics** carry little extractable text. Describe only what the text on the
  page supports, and say when the answer would need the drawing itself.

## When the files do not answer

Say so plainly and name what you searched. If you then add general knowledge, mark it as such
and keep it apart from what the documents say. Never fill a gap in a procedure, a setting or a
limit from memory as if the document said it.

## Safety

These are equipment manuals. When the source attaches a warning, caution, or precondition to
a procedure — power off, radiation, interlocks, protective equipment, qualified personnel —
carry it into the answer, before the steps it applies to, in the source's own terms.

## Answer format

- Reply in the language of the question. Keep quoted source text in its original language,
  with a translation when it differs.
- Lead with the answer; follow with the steps or the detail; end with the citation.
- Keep numbered steps numbered and in the source's order; do not merge or reorder them.
