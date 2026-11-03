#!/usr/bin/env python3
"""Ping Codex CLI through a ChatGPT login at four fixed Moscow-time slots."""

from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import tempfile
import time
from datetime import datetime, timedelta
from logging.handlers import RotatingFileHandler
from pathlib import Path
from zoneinfo import ZoneInfo

MSK = ZoneInfo("Europe/Moscow")
SLOTS = ("07:00", "12:01", "17:02", "22:03")
DEFAULT_MODEL = "gpt-6.1-sol"
MESSAGE = "hi"
TIMEOUT_S = 300
ATTEMPTS = 3
RETRY_DELAY_S = 120
POLL_S = 60
LOG_PATH = Path(__file__).resolve().with_name("ping.log")
DISABLED_FEATURES = (
    "shell_tool",
    "plugins",
    "apps",
    "hooks",
    "multi_agent",
    "memories",
    "computer_use",
    "image_generation",
    "browser_use",
    "in_app_browser",
    "skill_search",
    "view_image",
    "sleep_tool",
    "tool_suggest",
)
AUTH_FAILURES = (
    "not logged in",
    "unauthorized",
    "401 unauthorized",
    "refresh token",
    "refresh_token",
    "authentication failed",
    "please log in",
    "please login",
    "sign in again",
)
log = logging.getLogger("codex_auto_ping")


class AuthError(Exception):
    """A ChatGPT login needs user attention; retries cannot supply one."""


def codex_env() -> dict[str, str]:
    env = os.environ.copy()
    for key in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_THREAD_ID", "CODEX_SESSION_ID"):
        env.pop(key, None)
    return env


def check_login(codex: str, env: dict[str, str], cwd: str) -> None:
    result = subprocess.run(
        [codex, "login", "status"],
        cwd=cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    # Checking first avoids changing credentials with forced_login_method on an API-key account.
    if result.returncode != 0 or "Logged in using ChatGPT" not in result.stdout + result.stderr:
        raise AuthError("a saved ChatGPT login is required; API-key login is not used")


def skills_override(env: dict[str, str]) -> str:
    codex_home = Path(env.get("CODEX_HOME", str(Path.home() / ".codex")))
    paths = set()
    for root in (Path.home() / ".agents/skills", codex_home / "skills", Path("/etc/codex/skills")):
        if root.is_dir():
            paths.update(str(path.resolve()) for path in root.rglob("SKILL.md"))
    rules = ",".join("{path=" + json.dumps(path) + ",enabled=false}" for path in sorted(paths))
    return "skills.config=[" + rules + "]"


def ping_command(codex: str, model: str, instructions: Path, env: dict[str, str]) -> list[str]:
    command = [
        codex,
        "exec",
        "--ignore-user-config",
        "--ephemeral",
        "--skip-git-repo-check",
        "--sandbox",
        "read-only",
        "--json",
        "--model",
        model,
    ]
    settings = [
        "project_doc_max_bytes=0",
        'model_reasoning_effort="low"',
        'web_search="disabled"',
        "model_instructions_file=" + json.dumps(str(instructions)),
        skills_override(env),
        *(f"features.{feature}=false" for feature in DISABLED_FEATURES),
    ]
    for setting in settings:
        command.extend(("-c", setting))
    command.append(MESSAGE)
    return command


def completed_reply(output: str) -> tuple[str, dict]:
    reply = ""
    usage = None
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "item.completed":
            item = event.get("item", {})
            if isinstance(item, dict) and item.get("type") == "agent_message":
                text = item.get("text")
                if isinstance(text, str):
                    reply = text
        elif event.get("type") == "turn.completed":
            value = event.get("usage")
            usage = value if isinstance(value, dict) else {}
    return (reply, usage) if reply.strip() and usage is not None else ("", {})


def ping(codex: str, model: str) -> bool:
    env = codex_env()
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="codex-auto-ping-") as cwd:
            check_login(codex, env, cwd)
            instructions = Path(cwd) / "instructions.txt"
            instructions.write_text("Reply with exactly OK. Do not call tools or inspect files.\n")
            result = subprocess.run(
                ping_command(codex, model, instructions, env),
                cwd=cwd,
                env=env,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_S,
                check=False,
            )
    except OSError as exc:
        log.error("cannot run codex: %s", exc)
        return False
    except subprocess.TimeoutExpired:
        log.error("codex did not finish within its timeout")
        return False
    reason = result.stdout + " " + result.stderr
    if any(marker in reason.casefold() for marker in AUTH_FAILURES):
        raise AuthError("Codex rejected the saved login")
    reply, usage = completed_reply(result.stdout)
    if result.returncode != 0 or not reply:
        log.error("ping failed (exit %s): %s", result.returncode, " ".join(reason.split())[-300:])
        return False
    log.info(
        "ping sent in %.1fs · input=%s · output=%s · reply: %s",
        time.monotonic() - started,
        usage.get("input_tokens", "?"),
        usage.get("output_tokens", "?"),
        " ".join(reply.split())[:120],
    )
    return True


def next_slot(now: datetime) -> datetime:
    for hhmm in SLOTS:
        hour, minute = (int(part) for part in hhmm.split(":"))
        target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if target > now:
            return target
    hour, minute = (int(part) for part in SLOTS[0].split(":"))
    return now.replace(hour=hour, minute=minute, second=0, microsecond=0) + timedelta(days=1)


def sleep_until(target: datetime) -> None:
    # A long monotonic sleep stands still during suspend; the schedule follows the wall clock.
    while (left := (target - datetime.now(MSK)).total_seconds()) > 0:
        time.sleep(min(left, POLL_S))


def setup_logging() -> None:
    formatter = logging.Formatter("%(asctime)s MSK %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S")
    formatter.converter = lambda secs: datetime.fromtimestamp(secs, MSK).timetuple()
    handlers: list[logging.Handler] = [logging.StreamHandler()]
    file_error = None
    try:
        handlers.append(
            RotatingFileHandler(LOG_PATH, maxBytes=1_000_000, backupCount=2, encoding="utf-8")
        )
    except OSError as exc:
        file_error = exc
    for handler in handlers:
        handler.setFormatter(formatter)
    logging.basicConfig(level=logging.INFO, handlers=handlers)
    if file_error is not None:
        log.warning("file logging off (%s): %s", LOG_PATH, file_error)


def ping_with_retry(codex: str, model: str) -> bool:
    for attempt in range(1, ATTEMPTS + 1):
        try:
            if ping(codex, model):
                return True
        except AuthError as exc:
            log.error("login needs attention, no retry: %s · run `codex login --device-auth`", exc)
            return False
        if attempt < ATTEMPTS:
            log.warning("attempt %s/%s failed, retrying in %ss", attempt, ATTEMPTS, RETRY_DELAY_S)
            sleep_until(datetime.now(MSK) + timedelta(seconds=RETRY_DELAY_S))
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Codex model (default: %(default)s)")
    parser.add_argument("--codex", default="codex", help="Codex executable (default: PATH)")
    parser.add_argument("--once", action="store_true", help="send one message now and exit")
    args = parser.parse_args()
    setup_logging()
    if args.once:
        try:
            return 0 if ping(args.codex, args.model) else 1
        except AuthError as exc:
            log.error("login needs attention: %s · run `codex login --device-auth`", exc)
            return 1
    log.info("start · model=%s · auth: ChatGPT · MSK slots: %s", args.model, ", ".join(SLOTS))
    while True:
        target = next_slot(datetime.now(MSK))
        log.info("next ping %s MSK", target.strftime("%d.%m %H:%M"))
        sleep_until(target)
        if not ping_with_retry(args.codex, args.model):
            log.error("slot missed")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log.info("stopped")
