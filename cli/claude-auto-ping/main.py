#!/usr/bin/env python3
"""Ping Claude Code once per scheduled slot (MSK) — each message opens a new 5-hour session window."""

import argparse
import logging
import subprocess
import time
from datetime import datetime, timedelta
from logging.handlers import RotatingFileHandler
from pathlib import Path
from zoneinfo import ZoneInfo

MSK = ZoneInfo("Europe/Moscow")
SLOTS = ("07:00", "12:01", "17:02", "22:03")  # MSK
DEFAULT_MODEL = "haiku"  # Claude Code alias — always the latest haiku
MESSAGE = "hi"
TIMEOUT_S = 300
ATTEMPTS = 3
RETRY_DELAY_S = 120
LOG_PATH = Path(__file__).resolve().with_name("ping.log")
LOG_MAX_BYTES = 1_000_000
LOG_BACKUPS = 2
POLL_S = 60

log = logging.getLogger("claude_auto_ping")


def next_slot(now: datetime) -> datetime:
    """Next slot strictly in the future (MSK)."""
    for hhmm in SLOTS:
        h, m = (int(x) for x in hhmm.split(":"))
        at = now.replace(hour=h, minute=m, second=0, microsecond=0)
        if at > now:
            return at
    h, m = (int(x) for x in SLOTS[0].split(":"))
    return now.replace(hour=h, minute=m, second=0, microsecond=0) + timedelta(days=1)


def sleep_until(target: datetime) -> None:
    """Short steps against the wall clock: time.sleep() is monotonic and stands still
    during suspend, so one multi-hour sleep would fire hours late after a lid close."""
    while (left := (target - datetime.now(MSK)).total_seconds()) > 0:
        time.sleep(min(left, POLL_S))


def setup_logging() -> None:
    formatter = logging.Formatter(
        "%(asctime)s MSK %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S"
    )
    # MSK so log lines match the slots on any server TZ; use the record's own time, not now()
    formatter.converter = lambda secs: datetime.fromtimestamp(secs, MSK).timetuple()
    handlers: list[logging.Handler] = [logging.StreamHandler()]
    # A read-only checkout must not take the unit down into a Restart=always loop: journald keeps the log
    file_error: OSError | None = None
    try:
        handlers.append(
            RotatingFileHandler(
                LOG_PATH,
                maxBytes=LOG_MAX_BYTES,
                backupCount=LOG_BACKUPS,
                encoding="utf-8",
            )
        )
    except OSError as exc:
        file_error = exc
    for handler in handlers:
        handler.setFormatter(formatter)
    logging.basicConfig(level=logging.INFO, handlers=handlers)
    if file_error is not None:
        log.warning("file logging off (%s): %s", LOG_PATH, file_error)


def ping(claude: str, model: str) -> bool:
    """Send one message in a fresh Claude Code session; True = session window opened."""
    started = time.monotonic()
    try:
        proc = subprocess.run(
            # --no-session-persistence: ping sessions are not saved to ~/.claude and don't pile up
            [claude, "-p", MESSAGE, "--model", model, "--no-session-persistence"],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_S,
            check=False,
        )
    except FileNotFoundError:
        log.error("claude binary not found: %s", claude)
        return False
    except subprocess.TimeoutExpired:
        log.error("no reply within %ss", TIMEOUT_S)
        return False
    took = time.monotonic() - started
    if proc.returncode != 0:
        # claude -p reports a refusal (bad model, usage limit, no login) on stdout, not stderr
        reason = " ".join((proc.stdout + " " + proc.stderr).split())[:300]
        log.error(
            "exit %s after %.1fs · %s", proc.returncode, took, reason or "no output"
        )
        return False
    log.info(
        "window opened in %.1fs · reply: %s", took, " ".join(proc.stdout.split())[:120]
    )
    return True


def ping_with_retry(claude: str, model: str) -> bool:
    for attempt in range(1, ATTEMPTS + 1):
        if ping(claude, model):
            return True
        if attempt < ATTEMPTS:
            log.warning(
                "attempt %s/%s failed, retrying in %ss",
                attempt,
                ATTEMPTS,
                RETRY_DELAY_S,
            )
            sleep_until(datetime.now(MSK) + timedelta(seconds=RETRY_DELAY_S))
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help="Claude Code model (default: the haiku alias — always the latest)",
    )
    parser.add_argument(
        "--claude", default="claude", help="path to the claude binary if not in PATH"
    )
    parser.add_argument(
        "--once", action="store_true", help="send one message now and exit (smoke test)"
    )
    args = parser.parse_args()

    setup_logging()

    if args.once:
        return 0 if ping(args.claude, args.model) else 1

    log.info("start · model=%s · MSK slots: %s", args.model, ", ".join(SLOTS))
    while True:
        target = next_slot(datetime.now(MSK))
        log.info("next ping %s MSK", target.strftime("%d.%m %H:%M"))
        sleep_until(target)
        if not ping_with_retry(args.claude, args.model):
            log.error("slot missed: all %s attempts failed", ATTEMPTS)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log.info("stopped")
