"""Compression: lossless restructuring, then a gentle raster downsample.

The lossless pass always runs and its result is the floor: the lossy output is accepted only
when it is both smaller and passes the acceptance checks, otherwise the lossless one is kept.
Any output larger than its input is discarded and the input is kept ("no gain").
"""

from __future__ import annotations

import hashlib
import io
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import pikepdf
import pymupdf
from PIL import Image

from pdfprep.ui import PdfPrepError, warn

MB = 1_000_000
Image.MAX_IMAGE_PIXELS = None


@dataclass
class Acceptance:
    checks: dict[str, tuple[str, str]] = field(default_factory=dict)

    def record(self, name: str, status: str, detail: str = "") -> None:
        self.checks[name] = (status, detail)

    @property
    def failed(self) -> list[str]:
        return [name for name, (status, _) in self.checks.items() if status == "fail"]

    def rows(self) -> list[list[str]]:
        return [[name, status, detail] for name, (status, detail) in self.checks.items()]


@dataclass
class CompressResult:
    size_in: int
    size_out: int
    lossy_applied: bool
    images_recoded: int
    acceptance: Acceptance
    no_gain: bool

    @property
    def reduction_pct(self) -> float:
        if self.size_in == 0:
            return 0.0
        return round((1 - self.size_out / self.size_in) * 100, 2)


def _dedupe_images(pdf: pikepdf.Pdf) -> int:
    """Repoint byte-identical image XObjects at one instance."""
    seen: dict[str, pikepdf.Object] = {}
    replaced = 0
    for page in pdf.pages:
        xobjects = page.get("/Resources", {}).get("/XObject", None)
        if xobjects is None:
            continue
        for name in list(xobjects.keys()):
            obj = xobjects[name]
            if obj.get("/Subtype") != "/Image":
                continue
            try:
                raw = bytes(obj.read_raw_bytes())
            except Exception:
                continue
            key = hashlib.sha256(
                raw
                + str(obj.get("/Width")).encode()
                + str(obj.get("/Height")).encode()
                + str(obj.get("/ColorSpace")).encode()
            ).hexdigest()
            first = seen.get(key)
            if first is None:
                seen[key] = obj
            elif first.objgen != obj.objgen:
                xobjects[name] = first
                replaced += 1
    return replaced


def lossless_pass(src: Path, dst: Path) -> int:
    """Structure-only rewrite. Returns the number of deduplicated image objects."""
    with pikepdf.open(src) as pdf:
        replaced = _dedupe_images(pdf)
        pdf.remove_unreferenced_resources()
        pdf.save(
            dst,
            compress_streams=True,
            recompress_flate=True,
            object_stream_mode=pikepdf.ObjectStreamMode.generate,
            deterministic_id=True,
        )
    return replaced


def _display_targets(path: Path, target_dpi: int) -> dict[int, int]:
    """PDF object number -> pixel width that renders at target_dpi where the image is placed."""
    targets: dict[int, int] = {}
    doc = pymupdf.open(path)
    try:
        for page in doc:
            # one content-stream pass per page; get_image_rects per image re-parses the page
            # each time and took minutes on a 1000-page manual
            for placed in page.get_image_info(xrefs=True):
                xref = placed.get("xref", 0)
                if not xref:
                    continue
                width_pt = pymupdf.Rect(placed["bbox"]).width
                want = max(64, int(width_pt / 72.0 * target_dpi))
                targets[xref] = max(targets.get(xref, 0), want)
    finally:
        doc.close()
    return targets


_BILEVEL_FILTERS = {"/CCITTFaxDecode", "/JBIG2Decode"}


def _is_bilevel(obj: pikepdf.Object) -> bool:
    """A 1-bit scan: CCITT/JBIG2 already store it smaller than any JPEG could, and a grey JPEG
    of text or line art only adds ringing. Decoding one to find that out costs minutes — a
    single A0 drawing is half a gigapixel — so the header alone decides."""
    filters = obj.get("/Filter")
    names = {str(f) for f in filters} if isinstance(filters, pikepdf.Array) else {str(filters)}
    return int(obj.get("/BitsPerComponent", 8)) == 1 or bool(names & _BILEVEL_FILTERS)


def _recode_image(obj: pikepdf.Object, target_px: int, quality: int) -> bool:
    if obj.get("/ImageMask", False) or _is_bilevel(obj):
        return False
    try:
        pillow = pikepdf.PdfImage(obj).as_pil_image()
    except Exception:
        return False
    if pillow.width <= target_px:
        return False
    if pillow.mode not in ("RGB", "L"):
        pillow = pillow.convert("L" if pillow.mode in ("1", "I;16", "I") else "RGB")
    # box-reduce by an integer factor first: LANCZOS over the full original is the slow part
    factor = pillow.width // (target_px * 2)
    if factor >= 2:
        pillow = pillow.reduce(factor)
    ratio = target_px / pillow.width
    resized = pillow.resize((target_px, max(1, int(pillow.height * ratio))), Image.LANCZOS)
    buffer = io.BytesIO()
    resized.save(buffer, format="JPEG", quality=quality, optimize=True, progressive=True)
    payload = buffer.getvalue()
    try:
        if len(payload) >= len(bytes(obj.read_raw_bytes())):
            return False
    except Exception:
        pass
    obj.write(payload, filter=pikepdf.Name("/DCTDecode"))
    obj.Width = resized.width
    obj.Height = resized.height
    obj.ColorSpace = pikepdf.Name("/DeviceGray" if resized.mode == "L" else "/DeviceRGB")
    obj.BitsPerComponent = 8
    for key in ("/Decode", "/DecodeParms", "/Interpolate"):
        if key in obj:
            del obj[key]
    return True


def lossy_pass(src: Path, dst: Path, target_dpi: int, quality: int) -> int:
    targets = _display_targets(src, target_dpi)
    recoded = 0
    with pikepdf.open(src) as pdf:
        for page in pdf.pages:
            xobjects = page.get("/Resources", {}).get("/XObject", None)
            if xobjects is None:
                continue
            for name in list(xobjects.keys()):
                obj = xobjects[name]
                if obj.get("/Subtype") != "/Image":
                    continue
                target = targets.get(obj.objgen[0])
                if target and _recode_image(obj, target, quality):
                    recoded += 1
        _dedupe_images(pdf)
        pdf.remove_unreferenced_resources()
        pdf.save(
            dst,
            compress_streams=True,
            recompress_flate=True,
            object_stream_mode=pikepdf.ObjectStreamMode.generate,
            deterministic_id=True,
        )
    return recoded


def _sample_pages(total: int, limit: int) -> list[int]:
    if limit <= 0 or total <= limit:
        return list(range(total))
    stride = total / limit
    return sorted({min(total - 1, int(index * stride)) for index in range(limit)})


def _feature_counts(doc: pymupdf.Document) -> tuple[int, int, int]:
    annotations = sum(len(list(page.annots() or [])) for page in doc)
    return annotations, doc.embfile_count(), len(doc.get_toc(simple=True))


def verify(src: Path, out: Path, *, dpi: int, sample: int, strict_pixels: bool) -> Acceptance:
    report = Acceptance()
    before = pymupdf.open(src)
    after = pymupdf.open(out)
    try:
        if before.page_count != after.page_count:
            report.record("structure", "fail", f"{before.page_count} vs {after.page_count} pages")
            return report
        geometry_ok = all(
            (
                round(before[i].rect.width, 2) == round(after[i].rect.width, 2)
                and round(before[i].rect.height, 2) == round(after[i].rect.height, 2)
                and before[i].rotation == after[i].rotation
            )
            for i in range(before.page_count)
        )
        report.record(
            "structure",
            "pass" if geometry_ok else "fail",
            f"{before.page_count} pages, sizes and rotation {'match' if geometry_ok else 'differ'}",
        )

        pages = _sample_pages(before.page_count, sample)
        mismatched = [i for i in pages if before[i].get_text("text") != after[i].get_text("text")]
        has_text = any(before[i].get_text("text").strip() for i in pages)
        if not has_text:
            report.record("text_identity", "n/a", "no text layer in the sampled pages")
        else:
            report.record(
                "text_identity",
                "pass" if not mismatched else "fail",
                f"{len(pages)} pages checked"
                + ("" if not mismatched else f", differs on {mismatched[:5]}"),
            )

        if strict_pixels:
            matrix = pymupdf.Matrix(dpi / 72.0, dpi / 72.0)
            differing = []
            for index in pages:
                kwargs = {"matrix": matrix, "colorspace": pymupdf.csRGB, "alpha": False}
                left = before[index].get_pixmap(**kwargs)
                right = after[index].get_pixmap(**kwargs)
                if hashlib.sha256(left.samples).digest() != hashlib.sha256(right.samples).digest():
                    differing.append(index)
                del left, right
            report.record(
                "pixel_identity",
                "pass" if not differing else "fail",
                f"{len(pages)} pages at {dpi} dpi"
                + ("" if not differing else f", differs on {differing[:5]}"),
            )
        else:
            report.record("pixel_identity", "n/a", "lossy pass applied, pixels change by design")

        try:
            counts_before = _feature_counts(before)
            counts_after = _feature_counts(after)
            report.record(
                "features",
                "pass" if counts_before == counts_after else "fail",
                f"annots/embedded/outline {counts_before} vs {counts_after}",
            )
        except Exception as exc:
            report.record("features", "not run", str(exc)[:80])

        report.record(
            "integrity",
            "pass"
            if all(after[i].get_pixmap(matrix=pymupdf.Matrix(0.2, 0.2)) for i in pages)
            else "fail",
            f"{len(pages)} pages rendered without error",
        )
    finally:
        before.close()
        after.close()
    return report


def compress_file(
    src: Path,
    dst: Path,
    *,
    target_dpi: int,
    jpeg_quality: int,
    verify_dpi: int,
    verify_sample: int,
    work_dir: Path,
) -> CompressResult:
    work_dir.mkdir(parents=True, exist_ok=True)
    size_in = src.stat().st_size
    stage = work_dir / f"{src.stem}.lossless.pdf"
    lossy = work_dir / f"{src.stem}.lossy.pdf"
    # a rejected run must not leave source-sized intermediates behind in the work dir
    try:
        try:
            lossless_pass(src, stage)
        except Exception as exc:
            raise PdfPrepError(f"{src.name}: lossless pass failed ({exc})") from exc

        accepted = stage
        lossy_applied = False
        try:
            recoded = lossy_pass(src, lossy, target_dpi, jpeg_quality)
        except Exception as exc:
            warn(f"{src.name}: lossy pass skipped ({exc})")
            recoded = 0
        if recoded and lossy.is_file() and lossy.stat().st_size < stage.stat().st_size:
            accepted = lossy
            lossy_applied = True
        elif lossy.is_file():
            lossy.unlink()

        report = verify(
            src,
            accepted,
            dpi=verify_dpi,
            sample=verify_sample,
            strict_pixels=not lossy_applied,
        )
        if report.failed:
            if lossy_applied:
                failed = ", ".join(report.failed)
                warn(f"{src.name}: lossy output rejected ({failed}), keeping lossless")
                accepted, lossy_applied = stage, False
                report = verify(
                    src, accepted, dpi=verify_dpi, sample=verify_sample, strict_pixels=True
                )
            if report.failed:
                failed = ", ".join(report.failed)
                raise PdfPrepError(
                    f"{src.name}: compression rejected by acceptance checks: {failed}"
                )

        size_out = accepted.stat().st_size
        no_gain = size_out >= size_in
        dst.parent.mkdir(parents=True, exist_ok=True)
        deliverable = src if no_gain else accepted
        # copyfile, not read_bytes/write_bytes: a 100 MB source would otherwise go through RAM.
        # src and dst are the same file when a part is recompressed in place and shows no gain.
        if not (dst.exists() and deliverable.samefile(dst)):
            shutil.copyfile(deliverable, dst)
    finally:
        for leftover in (stage, lossy):
            if leftover.exists() and leftover != dst:
                leftover.unlink()

    return CompressResult(
        size_in=size_in,
        size_out=dst.stat().st_size,
        lossy_applied=lossy_applied and not no_gain,
        images_recoded=recoded if lossy_applied and not no_gain else 0,
        acceptance=report,
        no_gain=no_gain,
    )
