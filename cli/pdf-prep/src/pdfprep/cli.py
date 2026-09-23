"""Command line: task/ in, result/ out.

pdf-prep split      compress, then cut into upload-ready parts for a Claude Project
pdf-prep compress   compress only
pdf-prep translate  translate through the configured LLM provider
pdf-prep ocr        add a text layer to scans
pdf-prep doctor     check the environment, the paths and the provider
"""

from __future__ import annotations

import argparse
import shutil
import sys
from dataclasses import replace
from pathlib import Path

from pdfprep import __version__, compress, ocr, pdfdoc, split, translate
from pdfprep.config import PROVIDERS, Config, load
from pdfprep.fonts import find_font
from pdfprep.pdfdoc import MB, DocInfo
from pdfprep.providers import build
from pdfprep.ui import PdfPrepError, error, info, ok, step, table, warn


def _sources(cfg: Config, scope: list[str] | None) -> list[Path]:
    cfg.task_dir.mkdir(parents=True, exist_ok=True)
    found = pdfdoc.discover(cfg.task_dir, scope)
    if not found:
        raise PdfPrepError(f"No PDF found in {cfg.task_dir} — put your files there and re-run")
    info(f"task dir:   {cfg.task_dir}")
    info(f"result dir: {cfg.result_dir}")
    for path in found:
        info(f"  found {path.relative_to(cfg.task_dir)} ({path.stat().st_size / MB:.2f} MB)")
    return found


def _inspect_all(sources: list[Path], cfg: Config) -> tuple[dict[Path, DocInfo], list[str]]:
    infos: dict[Path, DocInfo] = {}
    skipped: list[str] = []
    slugs = pdfdoc.unique_slugs(sources, cfg.task_dir)
    for source in sources:
        try:
            infos[source] = replace(pdfdoc.inspect(source), slug=slugs[source])
        except PdfPrepError as exc:
            warn(f"skipped: {exc}")
            skipped.append(str(exc))
    return infos, skipped


def _print_checks(title: str, checks: list[tuple[str, str, str]]) -> bool:
    print(f"\n### {title}")
    print(
        table(
            [[name, status, detail] for name, status, detail in checks],
            ["check", "result", "measured"],
        )
    )
    return not any(status == "fail" for _, status, _ in checks)


def _maybe_ocr(
    source: Path, doc_info: DocInfo, cfg: Config, mode: str = "always"
) -> tuple[Path, int, str | None]:
    # always is the default: only pages without a readable text layer are OCR'd, so a typeset
    # page costs nothing, while the drawings and scans of a Mixed document become searchable
    wanted = mode == "always" or (mode == "auto" and doc_info.kind in ("Scanned", "ImageBased"))
    if not cfg.ocr_enabled or mode == "never" or not wanted:
        return source, 0, None
    if doc_info.text_pages == doc_info.pages:
        info(f"{source.name}: every page already has text, OCR skipped")
        return source, 0, None
    cfg.work_dir.mkdir(parents=True, exist_ok=True)
    target = cfg.work_dir / f"{doc_info.slug}--ocr.pdf"
    missing = doc_info.pages - doc_info.text_pages
    step(f"{source.name}: OCR on {missing} pages without a readable text layer")
    pages, engine = ocr.add_text_layer(
        source, target, cfg.ocr_languages, cfg.work_dir, cfg.ocr_device
    )
    ok(f"{source.name}: OCR added a text layer to {pages} pages ({engine})")
    return target, pages, engine


def _drop_staged(staged: Path, source: Path) -> None:
    # the OCR'd copy is as large as the source and one is left per document otherwise
    if staged != source:
        staged.unlink(missing_ok=True)


def _compressed_copy(source: Path, doc_info: DocInfo, cfg: Config) -> Path:
    """A compressed copy in the work dir, for commands whose output embeds the source pages."""
    target = cfg.work_dir / f"{doc_info.slug}--compressed.pdf"
    step(f"{source.name}: compressing at {cfg.target_dpi} dpi / q{cfg.jpeg_quality} first")
    result = compress.compress_file(
        source,
        target,
        target_dpi=cfg.target_dpi,
        jpeg_quality=cfg.jpeg_quality,
        verify_dpi=cfg.verify_dpi,
        verify_sample=cfg.verify_sample_pages,
        work_dir=cfg.work_dir,
    )
    info(f"{source.name}: {result.size_in / MB:.2f} MB → {result.size_out / MB:.2f} MB")
    return target


def cmd_split(args, cfg: Config) -> int:
    sources = _sources(cfg, args.scope)
    infos, skipped = _inspect_all(sources, cfg)
    failures = 0
    for source in sources:
        doc_info = infos.get(source)
        if doc_info is None:
            continue
        step(
            f"{source.name}: {doc_info.pages} pages, {doc_info.kind}, "
            f"toc from {doc_info.toc_source}"
        )
        if doc_info.toc_source == "heuristic":
            warn(f"{source.name}: sections inferred from font size — check the part boundaries")
        if doc_info.renamed_sections:
            info(
                f"{source.name}: {doc_info.renamed_sections} bookmarks were file names, "
                "renamed after the heading on their page"
            )
        staged = source
        try:
            staged, ocr_pages, engine = _maybe_ocr(source, doc_info, cfg, args.ocr)
            if engine:
                doc_info = pdfdoc.remap_sections(doc_info, staged)
                info(
                    f"{source.name}: {len(doc_info.sections)} sections re-read from the OCR "
                    f"text layer ({doc_info.toc_source})"
                )
            result = split.split_source(staged, cfg, doc_info)
            if engine:
                result.ocr_applied = True
                result.ocr_engine = engine
                result.notes.append(f"OCR text layer added to {ocr_pages} pages")
                split.write_manifest(result)
        except PdfPrepError as exc:
            error(str(exc))
            failures += 1
            continue
        finally:
            _drop_staged(staged, source)

        print(f"\n## {source.name} → {result.result_dir}")
        summary = f"branch {result.branch} · {len(result.parts)} parts"
        if result.branch == "A":
            summary += (
                f" · {result.compressed_from / MB:.2f} MB → "
                f"{result.compressed_to / MB:.2f} MB before split"
            )
        print(summary)
        if result.branch == "A":
            print()
            print(
                table(
                    [
                        [
                            part.file,
                            f"{part.first_page + 1}-{part.last_page + 1}",
                            f"{part.size_bytes / MB:.2f}",
                            part.chapters[0],
                        ]
                        for part in result.parts
                    ],
                    ["part", "pages", "size_mb", "starting section"],
                )
            )
        if not _print_checks("validation", split.validate(result, cfg)):
            failures += 1
        for part in result.parts:
            if part.forced_split:
                warn(f"{part.file}: forced split — {part.forced_split_reason}")
            elif part.section_split:
                warn(f"{part.file}: cut inside a section — none starts within the limits")
        for note in result.notes:
            info(note)
        if result.replaced:
            info(f"{result.replaced} file(s) from a previous run were removed first")
        ok(f"{source.name}: done")
    if skipped:
        warn(f"{len(skipped)} source(s) skipped")
    return 1 if failures else 0


def cmd_compress(args, cfg: Config) -> int:
    sources = _sources(cfg, args.scope)
    failures = 0
    rows: list[list[str]] = []
    for source in sources:
        cfg.result_dir.mkdir(parents=True, exist_ok=True)
        # same name and subfolder as in task/: flat, two manual.pdf would overwrite each other
        dst = cfg.result_dir / source.relative_to(cfg.task_dir)
        # The output keeps the source name, so a result dir pointed at task/ would eat the original.
        if dst.resolve() == source.resolve():
            error(f"{source.name}: result dir is the source dir — refusing to overwrite the source")
            failures += 1
            continue
        step(f"{source.name}: compressing at {cfg.target_dpi} dpi / q{cfg.jpeg_quality}")
        try:
            result = compress.compress_file(
                source,
                dst,
                target_dpi=cfg.target_dpi,
                jpeg_quality=cfg.jpeg_quality,
                verify_dpi=cfg.verify_dpi,
                verify_sample=cfg.verify_sample_pages,
                work_dir=cfg.work_dir,
            )
        except PdfPrepError as exc:
            error(str(exc))
            failures += 1
            continue
        rows.append(
            [
                str(source.relative_to(cfg.task_dir)),
                f"{result.size_in / MB:.2f}",
                f"{result.size_out / MB:.2f}",
                f"{result.reduction_pct:.2f}%",
                "lossy" if result.lossy_applied else "lossless",
            ]
        )
        _print_checks(f"acceptance · {source.name}", result.acceptance.rows())
        if result.no_gain:
            warn(f"{source.name}: no gain — the source was kept as the deliverable")
        ok(f"{source.name} → {dst}")
    if rows:
        print("\n### files")
        print(table(rows, ["source", "in_mb", "out_mb", "reduction", "mode"]))
    return 1 if failures else 0


def cmd_ocr(args, cfg: Config) -> int:
    sources = _sources(cfg, args.scope)
    failures = 0
    slugs = pdfdoc.unique_slugs(sources, cfg.task_dir)
    for source in sources:
        slug = slugs[source]
        cfg.result_dir.mkdir(parents=True, exist_ok=True)
        dst = cfg.result_dir / f"{slug}--ocr.pdf"
        step(f"{source.name}: OCR ({', '.join(cfg.ocr_languages)})")
        try:
            pages, engine = ocr.add_text_layer(
                source, dst, cfg.ocr_languages, cfg.work_dir, cfg.ocr_device
            )
        except PdfPrepError as exc:
            error(str(exc))
            failures += 1
            continue
        if pages == 0:
            info(f"{source.name}: nothing to OCR — copied unchanged")
        ok(f"{source.name}: {pages} pages gained a text layer ({engine}) → {dst}")
    return 1 if failures else 0


def cmd_translate(args, cfg: Config) -> int:
    sources = _sources(cfg, args.scope)
    infos, _ = _inspect_all(sources, cfg)
    glossary = ""
    if args.glossary:
        path = Path(args.glossary).expanduser()
        if not path.is_file():
            raise PdfPrepError(f"Glossary file not found: {path}")
        glossary = path.read_text(encoding="utf-8")
    provider = build(cfg.llm)
    info(f"provider: {provider.name} · model: {provider.model}")

    failures = 0
    for source in sources:
        doc_info = infos.get(source)
        if doc_info is None:
            continue
        staged = compressed = source
        try:
            staged, ocr_pages, engine = _maybe_ocr(source, doc_info, cfg, args.ocr)
            # only the pdf format carries the source pages into the output; markdown and docx
            # hold text alone, so compressing for them would cost minutes and save nothing
            if args.format == "pdf":
                compressed = _compressed_copy(staged, doc_info, cfg)
            step(f"{source.name}: translating into {args.lang} as {args.format}")
            result = translate.translate_source(
                compressed,
                cfg,
                doc_info,
                provider=provider,
                target_lang=args.lang,
                output_format=args.format,
                glossary=glossary,
                page_range=args.pages,
                resume=not args.no_resume,
            )
            if engine:
                result.notes.append(f"OCR text layer added to {ocr_pages} pages ({engine})")
        except PdfPrepError as exc:
            error(str(exc))
            failures += 1
            continue
        finally:
            _drop_staged(staged, source)
            _drop_staged(compressed, source)

        print(f"\n## {source.name} → {result.result_dir}")
        print(
            f"{result.blocks_translated}/{result.blocks_total} blocks · {result.chunks} chunks · "
            f"{result.retries} retries · {provider.name}/{provider.model}"
        )
        gates = translate.quality_gates(result)
        status, detail = translate.verify_urls(result.result_dir / f"{doc_info.slug}--blocks.json")
        gates.append(("url preservation", status, detail))
        if not _print_checks("quality gates", gates):
            failures += 1
        for finding in result.injection_findings[:10]:
            warn(f"embedded instruction ignored — {finding}")
        for note in result.notes:
            info(note)
        for path in result.outputs:
            ok(f"written: {path}")
    return 1 if failures else 0


def cmd_list(args, cfg: Config) -> int:
    sources = _sources(cfg, args.scope)
    infos, _ = _inspect_all(sources, cfg)
    print()
    print(
        table(
            [
                [
                    path.name,
                    str(infos[path].pages),
                    f"{infos[path].size_bytes / MB:.2f}",
                    infos[path].kind,
                    infos[path].toc_source,
                ]
                for path in sources
                if path in infos
            ],
            ["file", "pages", "size_mb", "type", "sections"],
        )
    )
    return 0


def cmd_doctor(args, cfg: Config) -> int:
    checks: list[tuple[str, str, str]] = []
    checks.append(("python", "pass", sys.version.split()[0]))
    checks.append(("project home", "pass", str(cfg.home)))
    for name, path in (("task dir", cfg.task_dir), ("result dir", cfg.result_dir)):
        path.mkdir(parents=True, exist_ok=True)
        probe = path / ".pdfprep-write-test"
        try:
            probe.write_text("ok", encoding="utf-8")
            probe.unlink()
            checks.append((name, "pass", f"{path} (writable)"))
        except OSError as exc:
            checks.append((name, "fail", f"{path}: {exc}"))

    for module in ("pymupdf", "pikepdf", "PIL", "docx"):
        try:
            __import__(module)
            checks.append((f"import {module}", "pass", ""))
        except ImportError as exc:
            checks.append((f"import {module}", "fail", str(exc)[:80]))
    if cfg.ocr_enabled:
        try:
            __import__("easyocr")
            checks.append(("import easyocr", "pass", ", ".join(cfg.ocr_languages)))
        except ImportError as exc:
            checks.append(("import easyocr", "fail", str(exc)[:80]))
        usable, detail = ocr.gpu_status()
        if cfg.ocr_device == "cpu":
            checks.append(("ocr device", "pass", "cpu (forced in config)"))
        elif usable:
            checks.append(("ocr device", "pass", f"gpu · {detail}"))
        else:
            checks.append(("ocr device", "pass", f"cpu · {detail}"))

    font = find_font()
    checks.append(
        ("unicode font", "pass" if font else "fail", str(font) if font else "set PDFPREP_FONT")
    )
    claude = shutil.which("claude")
    checks.append(("claude CLI", "pass" if claude else "n/a", claude or "not on PATH"))

    if args.llm:
        try:
            checks.append(("llm provider", "pass", build(cfg.llm).check()))
        except PdfPrepError as exc:
            checks.append(("llm provider", "fail", str(exc)[:160]))
    else:
        checks.append(
            (
                "llm provider",
                "not run",
                f"{cfg.llm.provider}/{cfg.llm.model} — add --llm to call it",
            )
        )

    passed = _print_checks("doctor", checks)
    return 0 if passed else 1


def build_parser() -> argparse.ArgumentParser:
    # Shared flags live on the subcommands only: adding them to both parsers would let the
    # subparser's None default overwrite a value given before the subcommand.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--task-dir", help="override the input directory (default: task/)")
    common.add_argument("--result-dir", help="override the output directory (default: result/)")
    common.add_argument("--scope", nargs="*", help="process only files or folders matching these")
    common.add_argument("--provider", choices=PROVIDERS, help="LLM provider (default: claude-cli)")
    common.add_argument("--model", help="LLM model id for the chosen provider")

    parser = argparse.ArgumentParser(prog="pdf-prep", description=__doc__.splitlines()[0])
    parser.add_argument("--version", action="version", version=f"pdf-prep {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    split_cmd = sub.add_parser(
        "split", parents=[common], help="compress, then cut into upload-ready parts"
    )
    split_cmd.add_argument("--max-part-mb", type=float)
    split_cmd.add_argument("--max-part-pages", type=int)
    split_cmd.add_argument(
        "--ocr",
        choices=("auto", "always", "never"),
        default="always",
        help="always (default): every page that lacks a readable text layer; "
        "auto: only a document with none at all",
    )
    split_cmd.set_defaults(func=cmd_split)

    compress_cmd = sub.add_parser("compress", parents=[common], help="compress only")
    compress_cmd.set_defaults(func=cmd_compress)

    ocr_cmd = sub.add_parser("ocr", parents=[common], help="add a text layer to scans")
    ocr_cmd.set_defaults(func=cmd_ocr)

    translate_cmd = sub.add_parser(
        "translate", parents=[common], help="translate through the LLM provider"
    )
    translate_cmd.add_argument("--lang", required=True, help="target language, e.g. russian")
    translate_cmd.add_argument("--format", choices=translate.FORMATS, default="markdown")
    translate_cmd.add_argument("--pages", help="page range, e.g. 1-20")
    translate_cmd.add_argument("--glossary", help="file with protected terms and rules")
    translate_cmd.add_argument("--no-resume", action="store_true", help="ignore the checkpoint")
    translate_cmd.add_argument(
        "--ocr",
        choices=("auto", "always", "never"),
        default="always",
        help="always (default): every page that lacks a readable text layer; "
        "auto: only a document with none at all",
    )
    translate_cmd.set_defaults(func=cmd_translate)

    list_cmd = sub.add_parser(
        "list", parents=[common], help="show what is in task/ without touching it"
    )
    list_cmd.set_defaults(func=cmd_list)

    doctor_cmd = sub.add_parser(
        "doctor", parents=[common], help="check the environment and the provider"
    )
    doctor_cmd.add_argument(
        "--llm", action="store_true", help="also send one probe to the provider"
    )
    doctor_cmd.set_defaults(func=cmd_doctor)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    # Report tables go to stdout, progress to stderr; without this they interleave wrongly
    sys.stdout.reconfigure(line_buffering=True)
    try:
        cfg = load(
            task_dir=args.task_dir,
            result_dir=args.result_dir,
            max_part_mb=getattr(args, "max_part_mb", None),
            max_part_pages=getattr(args, "max_part_pages", None),
            provider=args.provider,
            model=args.model,
        )
        return args.func(args, cfg)
    except PdfPrepError as exc:
        error(str(exc))
        return 1
    except KeyboardInterrupt:
        error("interrupted")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
