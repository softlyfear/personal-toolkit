"""Configuration: built-in defaults, config.toml, environment, CLI flags.

Resolution order, applied to every single value: CLI flag > PDFPREP_* env var >
config.toml > built-in default. A provider block under [llm.<provider>] overrides the
flat [llm] keys for that provider only.
"""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from pdfprep.ui import PdfPrepError

CLAUDE_CLI = "claude-cli"
ANTHROPIC_API = "anthropic-api"
OPENAI_COMPATIBLE = "openai-compatible"
PROVIDERS = (CLAUDE_CLI, ANTHROPIC_API, OPENAI_COMPATIBLE)
OCR_DEVICES = ("auto", "gpu", "cpu")

DEFAULT_KEY_ENV = {
    CLAUDE_CLI: "",
    ANTHROPIC_API: "ANTHROPIC_API_KEY",
    OPENAI_COMPATIBLE: "OPENAI_API_KEY",
}
DEFAULT_MODEL = {
    CLAUDE_CLI: "sonnet",
    ANTHROPIC_API: "claude-sonnet-5",
    OPENAI_COMPATIBLE: "gpt-4.1",
}

DEFAULT_MAX_TOKENS = 8000
DEFAULT_TIMEOUT_S = 600
DEFAULT_CHUNK_CHARS = 6000


@dataclass(frozen=True)
class LlmConfig:
    provider: str = CLAUDE_CLI
    model: str = DEFAULT_MODEL[CLAUDE_CLI]
    api_key_env: str = ""
    base_url: str = ""
    max_tokens: int = DEFAULT_MAX_TOKENS
    timeout_s: int = DEFAULT_TIMEOUT_S
    chunk_chars: int = DEFAULT_CHUNK_CHARS


@dataclass(frozen=True)
class Config:
    home: Path
    task_dir: Path
    result_dir: Path
    work_dir: Path
    max_part_mb: float = 30.0
    max_part_pages: int = 100
    target_dpi: int = 200
    jpeg_quality: int = 85
    verify_sample_pages: int = 12
    verify_dpi: int = 150
    ocr_enabled: bool = True
    ocr_languages: tuple[str, ...] = ("en", "ru")
    ocr_device: str = "auto"  # auto | gpu | cpu
    llm: LlmConfig = field(default_factory=LlmConfig)


def find_home() -> Path:
    """Project directory holding task/, result/ and config.toml."""
    env = os.environ.get("PDFPREP_HOME")
    if env:
        return Path(env).expanduser().resolve()
    # src/pdfprep/config.py -> src/pdfprep -> src -> project
    packaged = Path(__file__).resolve().parents[2]
    if (packaged / "pyproject.toml").is_file():
        return packaged
    for candidate in [Path.cwd(), *Path.cwd().parents]:
        if (candidate / "pyproject.toml").is_file() and candidate.name == "pdf-prep":
            return candidate
    raise PdfPrepError(
        "Cannot locate the pdf-prep project directory — set PDFPREP_HOME to it "
        "or run the launcher created by install.sh"
    )


def _load_file(home: Path) -> dict:
    path = home / "config.toml"
    if not path.is_file():
        return {}
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise PdfPrepError(f"Cannot read {path}: {exc}") from exc


def _pick(cli, env_name: str, file_value, default):
    if cli is not None:
        return cli
    env = os.environ.get(env_name)
    if env not in (None, ""):
        return env
    if file_value is not None:
        return file_value
    return default


def _as_int(value, name: str) -> int:
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise PdfPrepError(f"{name} must be an integer, got {value!r}") from exc


def _as_float(value, name: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise PdfPrepError(f"{name} must be a number, got {value!r}") from exc


def _resolve_llm(data: dict, provider_cli: str | None, model_cli: str | None) -> LlmConfig:
    flat = data.get("llm", {}) if isinstance(data.get("llm"), dict) else {}
    provider = str(_pick(provider_cli, "PDFPREP_LLM_PROVIDER", flat.get("provider"), CLAUDE_CLI))
    if provider not in PROVIDERS:
        raise PdfPrepError(f"Unknown llm provider {provider!r}; expected one of {PROVIDERS}")

    block = flat.get(provider, {})
    if not isinstance(block, dict):
        block = {}

    def value(key, env_name, default):
        return _pick(None, env_name, block.get(key, flat.get(key)), default)

    model = _pick(model_cli, "PDFPREP_LLM_MODEL", block.get("model"), None)
    if model is None:
        model = flat.get("model") or DEFAULT_MODEL[provider]

    return LlmConfig(
        provider=provider,
        model=str(model),
        api_key_env=str(value("api_key_env", "PDFPREP_LLM_KEY_ENV", DEFAULT_KEY_ENV[provider])),
        base_url=str(value("base_url", "PDFPREP_LLM_BASE_URL", "")),
        max_tokens=_as_int(
            value("max_tokens", "PDFPREP_LLM_MAX_TOKENS", DEFAULT_MAX_TOKENS), "max_tokens"
        ),
        timeout_s=_as_int(
            value("timeout_s", "PDFPREP_LLM_TIMEOUT", DEFAULT_TIMEOUT_S), "timeout_s"
        ),
        chunk_chars=_as_int(
            value("chunk_chars", "PDFPREP_LLM_CHUNK_CHARS", DEFAULT_CHUNK_CHARS), "chunk_chars"
        ),
    )


def _ocr_device(value: object) -> str:
    device = str(value).strip().lower()
    if device not in OCR_DEVICES:
        raise PdfPrepError(f"ocr device must be one of {', '.join(OCR_DEVICES)}, got {value!r}")
    return device


def load(
    *,
    task_dir: str | None = None,
    result_dir: str | None = None,
    max_part_mb: float | None = None,
    max_part_pages: int | None = None,
    provider: str | None = None,
    model: str | None = None,
) -> Config:
    home = find_home()
    data = _load_file(home)
    paths = data.get("paths", {}) if isinstance(data.get("paths"), dict) else {}
    split = data.get("split", {}) if isinstance(data.get("split"), dict) else {}
    comp = data.get("compress", {}) if isinstance(data.get("compress"), dict) else {}
    ocr = data.get("ocr", {}) if isinstance(data.get("ocr"), dict) else {}

    languages = ocr.get("languages") or ["en", "ru"]
    if isinstance(languages, str):
        languages = [languages]

    return Config(
        home=home,
        task_dir=Path(
            str(_pick(task_dir, "PDFPREP_TASK_DIR", paths.get("task_dir"), home / "task"))
        ).expanduser(),
        result_dir=Path(
            str(_pick(result_dir, "PDFPREP_RESULT_DIR", paths.get("result_dir"), home / "result"))
        ).expanduser(),
        work_dir=home / ".work",
        max_part_mb=_as_float(
            _pick(max_part_mb, "PDFPREP_MAX_PART_MB", split.get("max_part_mb"), 30.0),
            "max_part_mb",
        ),
        max_part_pages=_as_int(
            _pick(max_part_pages, "PDFPREP_MAX_PART_PAGES", split.get("max_part_pages"), 100),
            "max_part_pages",
        ),
        target_dpi=_as_int(comp.get("target_dpi", 200), "target_dpi"),
        jpeg_quality=_as_int(comp.get("jpeg_quality", 85), "jpeg_quality"),
        verify_sample_pages=_as_int(comp.get("verify_sample_pages", 12), "verify_sample_pages"),
        verify_dpi=_as_int(comp.get("verify_dpi", 150), "verify_dpi"),
        ocr_enabled=bool(ocr.get("enabled", True)),
        ocr_languages=tuple(str(lang) for lang in languages),
        ocr_device=_ocr_device(_pick(None, "PDFPREP_OCR_DEVICE", ocr.get("device"), "auto")),
        llm=_resolve_llm(data, provider, model),
    )
