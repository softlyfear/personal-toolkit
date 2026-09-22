"""Logging helpers matching the [INFO]/[OK]/[WARN]/[ERROR] shape used across this repo."""

from __future__ import annotations

import os
import sys

_COLOR = sys.stderr.isatty() and os.environ.get("NO_COLOR") is None


def _emit(color: str, tag: str, message: str) -> None:
    text = f"[{tag}] {message}"
    print(f"\033[{color}m{text}\033[0m" if _COLOR else text, file=sys.stderr, flush=True)


def info(message: str) -> None:
    _emit("35", "INFO ", message)


def ok(message: str) -> None:
    _emit("32", "OK   ", message)


def warn(message: str) -> None:
    _emit("33", "WARN ", message)


def error(message: str) -> None:
    _emit("31", "ERROR", message)


def step(message: str) -> None:
    _emit("36", "STEP ", message)


class PdfPrepError(Exception):
    """Fatal, already-explained condition: the CLI prints it and exits non-zero."""


def table(rows: list[list[str]], headers: list[str]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    line = "| " + " | ".join(h.ljust(widths[i]) for i, h in enumerate(headers)) + " |"
    sep = "|" + "|".join("-" * (w + 2) for w in widths) + "|"
    body = [
        "| " + " | ".join(cell.ljust(widths[i]) for i, cell in enumerate(row)) + " |"
        for row in rows
    ]
    return "\n".join([line, sep, *body])
