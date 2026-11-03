"""Scheduling and subscription-only request behaviour without live model calls."""

from __future__ import annotations

import importlib.util
import json
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "codex_auto_ping", ROOT / "cli/codex-auto-ping/main.py"
)
ping = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ping)


def response(*events):
    return "\n".join(json.dumps(event) for event in events)


SUCCESS = response(
    {"type": "item.completed", "item": {"type": "agent_message", "text": "OK"}},
    {"type": "turn.completed", "usage": {"input_tokens": 100, "output_tokens": 5}},
)


@pytest.mark.parametrize(
    ("hour", "minute", "expected_day", "expected_hour", "expected_minute"),
    [(6, 59, 3, 7, 0), (7, 0, 3, 12, 1), (12, 1, 3, 17, 2), (17, 2, 3, 22, 3), (22, 3, 4, 7, 0)],
)
def test_next_slot_is_strictly_in_the_future(
    hour, minute, expected_day, expected_hour, expected_minute
):
    now = datetime(2026, 11, 3, hour, minute, tzinfo=ping.MSK)
    assert ping.next_slot(now) == datetime(
        2026, 11, expected_day, expected_hour, expected_minute, tzinfo=ping.MSK
    )


def test_suspend_does_not_leave_a_multi_hour_monotonic_sleep(monkeypatch):
    target = datetime(2026, 11, 3, 12, 1, tzinfo=ping.MSK)
    times = iter(
        [
            target - timedelta(seconds=130),
            target - timedelta(seconds=70),
            target + timedelta(hours=2),
        ]
    )

    class Clock:
        @staticmethod
        def now(_zone):
            return next(times)

    waits = []
    monkeypatch.setattr(ping, "datetime", Clock)
    monkeypatch.setattr(ping.time, "sleep", waits.append)
    ping.sleep_until(target)
    assert waits == [60, 60]


def test_a_ping_keeps_auth_home_but_drops_api_keys_and_cleans_its_directory(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-api-key")
    monkeypatch.setenv("CODEX_API_KEY", "test-codex-key")
    monkeypatch.setenv("CODEX_THREAD_ID", "parent-thread")
    monkeypatch.setattr(ping, "skills_override", lambda _env: "skills.config=[]")
    calls = []

    def run(args, **kwargs):
        calls.append((args, kwargs))
        assert "OPENAI_API_KEY" not in kwargs["env"]
        assert "CODEX_API_KEY" not in kwargs["env"]
        assert "CODEX_THREAD_ID" not in kwargs["env"]
        assert kwargs["env"].get("CODEX_HOME") == ping.os.environ.get("CODEX_HOME")
        assert Path(kwargs["cwd"]).is_dir()
        if args[1:3] == ["login", "status"]:
            return subprocess.CompletedProcess(args, 0, "", "Logged in using ChatGPT")
        assert (
            Path(kwargs["cwd"], "instructions.txt").read_text().startswith("Reply with exactly OK")
        )
        assert "--ignore-user-config" in args and "--ephemeral" in args
        assert args[args.index("--sandbox") + 1] == "read-only"
        assert "project_doc_max_bytes=0" in args and "features.shell_tool=false" in args
        assert kwargs["stdin"] == subprocess.DEVNULL
        return subprocess.CompletedProcess(args, 0, SUCCESS, "")

    monkeypatch.setattr(ping.subprocess, "run", run)
    assert ping.ping("/bin/test-codex", "test-model")
    assert len(calls) == 2
    assert not Path(calls[0][1]["cwd"]).exists()


@pytest.mark.parametrize("status", ["Not logged in", "Logged in using an API key"])
def test_no_model_request_is_sent_without_a_chatgpt_login(monkeypatch, status):
    calls = []

    def run(args, **_kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0, status, "")

    monkeypatch.setattr(ping.subprocess, "run", run)
    with pytest.raises(ping.AuthError):
        ping.ping("codex", "test-model")
    assert calls == [["codex", "login", "status"]]


@pytest.mark.parametrize(
    "output",
    [
        "",
        "OK",
        '{"type":"turn.completed"}',
        '{"type":"item.completed","item":null}',
        response({"type": "item.completed", "item": {"type": "agent_message", "text": "OK"}}),
    ],
)
def test_exit_zero_without_a_completed_assistant_response_is_not_success(output):
    assert ping.completed_reply(output) == ("", {})


def test_success_uses_the_assistant_message_and_reports_usage():
    assert ping.completed_reply("not JSON\n" + SUCCESS) == (
        "OK",
        {"input_tokens": 100, "output_tokens": 5},
    )


def test_auth_failures_do_not_retry(monkeypatch):
    calls = []

    def failed(*args):
        calls.append(args)
        raise ping.AuthError("expired login")

    monkeypatch.setattr(ping, "ping", failed)
    monkeypatch.setattr(ping, "sleep_until", lambda _target: pytest.fail("must not retry auth"))
    assert not ping.ping_with_retry("codex", "test-model")
    assert len(calls) == 1


def test_transient_failure_retries_with_a_limit(monkeypatch):
    outcomes = iter([False, False, True])
    waits = []
    monkeypatch.setattr(ping, "ping", lambda *_args: next(outcomes))
    monkeypatch.setattr(ping, "sleep_until", waits.append)
    assert ping.ping_with_retry("codex", "test-model")
    assert len(waits) == 2


def test_timeout_cleans_the_temporary_directory(monkeypatch):
    directories = []
    monkeypatch.setattr(ping, "skills_override", lambda _env: "skills.config=[]")

    def run(args, **kwargs):
        directories.append(kwargs["cwd"])
        if args[1] == "login":
            return subprocess.CompletedProcess(args, 0, "Logged in using ChatGPT", "")
        raise subprocess.TimeoutExpired(args, kwargs["timeout"])

    monkeypatch.setattr(ping.subprocess, "run", run)
    assert not ping.ping("codex", "test-model")
    assert all(not Path(directory).exists() for directory in directories)


def test_global_skill_catalog_is_disabled_without_reading_skill_contents(tmp_path, monkeypatch):
    skill = tmp_path / ".agents/skills/example/SKILL.md"
    skill.parent.mkdir(parents=True)
    skill.write_text("Skill body should not enter the prompt")
    monkeypatch.setattr(ping.Path, "home", lambda: tmp_path)
    setting = ping.skills_override({})
    assert str(skill) in setting and "enabled=false" in setting
    assert "Skill body" not in setting
