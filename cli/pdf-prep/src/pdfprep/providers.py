"""LLM providers.

The rule, in one place: every model call in this project goes through `Provider.complete`.
Claude is the default and needs no API key — it drives the `claude` CLI on the user's
subscription. Any other backend is opt-in through config/flags and reads its key from an
environment variable only, never from a file or a command line.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass

from pdfprep.config import ANTHROPIC_API, CLAUDE_CLI, OPENAI_COMPATIBLE, LlmConfig
from pdfprep.ui import PdfPrepError

# Resolved to the family's newest model, the way the `claude` CLI treats these aliases
CLAUDE_FAMILIES = ("opus", "sonnet", "haiku")


@dataclass
class Provider:
    name: str
    model: str

    def complete(self, system: str, user: str) -> str:
        raise NotImplementedError

    def check(self) -> str:
        """Return a human-readable readiness line, or raise PdfPrepError."""
        raise NotImplementedError


class ClaudeCliProvider(Provider):
    def __init__(self, cfg: LlmConfig) -> None:
        super().__init__(CLAUDE_CLI, cfg.model)
        self.timeout_s = cfg.timeout_s

    def _binary(self) -> str:
        binary = shutil.which("claude")
        if not binary:
            raise PdfPrepError(
                "The `claude` CLI is not on PATH. Install it with "
                "`curl -fsSL https://claude.ai/install.sh | bash`, run `claude` once to log in, "
                "or switch provider with --provider anthropic-api"
            )
        return binary

    def complete(self, system: str, user: str) -> str:
        command = [
            self._binary(),
            "-p",
            user,
            "--model",
            self.model,
            # Replace Claude Code's agent prompt, tools, MCP, skills and user settings: ~30k
            # tokens of subscription limit per call otherwise, and the user's `language`
            # setting would compete with the target language
            "--system-prompt",
            system,
            "--tools",
            "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--setting-sources",
            "project",
            # Translation runs hundreds of one-shot calls; persisted sessions would pile up
            "--no-session-persistence",
        ]
        try:
            done = subprocess.run(
                command,
                # Keep CLAUDE.md files of the caller's working directory out of the context
                cwd=tempfile.gettempdir(),
                capture_output=True,
                text=True,
                timeout=self.timeout_s,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise PdfPrepError(f"claude CLI timed out after {self.timeout_s}s") from exc
        if done.returncode != 0:
            detail = (done.stderr or done.stdout or "").strip()[:400]
            raise PdfPrepError(f"claude CLI exited {done.returncode}: {detail}")
        return done.stdout.strip()

    def check(self) -> str:
        reply = self.complete("Answer with the single word: ready", "ready?")
        return f"{self.name} · model {self.model} · reply: {reply[:60]}"


class AnthropicApiProvider(Provider):
    def __init__(self, cfg: LlmConfig) -> None:
        super().__init__(ANTHROPIC_API, cfg.model)
        self.cfg = cfg

    def _client(self):
        try:
            from anthropic import Anthropic
        except ImportError as exc:
            raise PdfPrepError("The `anthropic` package is not installed — run `uv sync`") from exc
        key = os.environ.get(self.cfg.api_key_env or "ANTHROPIC_API_KEY", "")
        if not key:
            raise PdfPrepError(
                f"Environment variable {self.cfg.api_key_env or 'ANTHROPIC_API_KEY'} is empty"
            )
        kwargs = {"api_key": key, "timeout": float(self.cfg.timeout_s)}
        if self.cfg.base_url:
            kwargs["base_url"] = self.cfg.base_url
        return Anthropic(**kwargs)

    def _resolve_model(self, client) -> str:
        if self.model in CLAUDE_FAMILIES:
            prefix = f"claude-{self.model}-"
            family = [m for m in client.models.list() if m.id.startswith(prefix)]
            if not family:
                raise PdfPrepError(f"No {self.model} model is available to this API key")
            self.model = max(family, key=lambda m: m.created_at).id
        return self.model

    def complete(self, system: str, user: str) -> str:
        client = self._client()
        message = client.messages.create(
            model=self._resolve_model(client),
            max_tokens=self.cfg.max_tokens,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
        return "".join(block.text for block in message.content if block.type == "text").strip()

    def check(self) -> str:
        reply = self.complete("Answer with the single word: ready", "ready?")
        return f"{self.name} · model {self.model} · reply: {reply[:60]}"


class OpenAiCompatibleProvider(Provider):
    def __init__(self, cfg: LlmConfig) -> None:
        super().__init__(OPENAI_COMPATIBLE, cfg.model)
        self.cfg = cfg

    def _client(self):
        try:
            from openai import OpenAI
        except ImportError as exc:
            raise PdfPrepError("The `openai` package is not installed — run `uv sync`") from exc
        key = os.environ.get(self.cfg.api_key_env or "OPENAI_API_KEY", "")
        if not key:
            raise PdfPrepError(
                f"Environment variable {self.cfg.api_key_env or 'OPENAI_API_KEY'} is empty"
            )
        kwargs = {"api_key": key, "timeout": float(self.cfg.timeout_s)}
        if self.cfg.base_url:
            kwargs["base_url"] = self.cfg.base_url
        return OpenAI(**kwargs)

    def complete(self, system: str, user: str) -> str:
        response = self._client().chat.completions.create(
            model=self.model,
            max_tokens=self.cfg.max_tokens,
            messages=[
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        )
        return (response.choices[0].message.content or "").strip()

    def check(self) -> str:
        reply = self.complete("Answer with the single word: ready", "ready?")
        return f"{self.name} · model {self.model} · reply: {reply[:60]}"


def build(cfg: LlmConfig) -> Provider:
    if cfg.provider == CLAUDE_CLI:
        return ClaudeCliProvider(cfg)
    if cfg.provider == ANTHROPIC_API:
        return AnthropicApiProvider(cfg)
    if cfg.provider == OPENAI_COMPATIBLE:
        return OpenAiCompatibleProvider(cfg)
    raise PdfPrepError(f"Unknown provider {cfg.provider!r}")
