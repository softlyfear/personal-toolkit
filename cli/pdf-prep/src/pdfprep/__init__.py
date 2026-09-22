"""Local PDF toolbox: compress, split for Claude Projects, translate."""

import os

# MuPDF writes its own notices to stdout, where this tool writes its report tables.
os.environ.setdefault("PYMUPDF_MESSAGE", "fd:2")

__version__ = "0.1.0"
