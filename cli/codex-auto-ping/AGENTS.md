# AGENTS.md — cli/codex-auto-ping

Follow the repository-wide rules in `../../AGENTS.md`.

This is a separate, non-packaged uv project. Keep it independent of `claude-auto-ping`:
the wget-piped installer downloads only its own `APP_FILES`, without cloning the repository.
A local installer can copy the same files from its own directory.

Use a systemd user unit, never root or cron. Keep the same MSK slots as `claude-auto-ping`.
`sleep_until` uses short wall-clock steps so suspend does not add hours of monotonic sleep.

Authentication belongs to the Codex CLI: require an existing ChatGPT login and let Codex refresh it.
Do not copy, parse, log or maintain OAuth tokens. Remove API-key environment variables from child
processes and reject API-key login before sending a request. Do not change `CODEX_HOME` to isolate
configuration: that also changes where authentication is found.

Pings use an ephemeral `codex exec` in a new temporary directory, with user configuration,
project instructions, skills, plugins and tools disabled. `model_instructions_file` replaces the
large built-in coding prompt. Keep the installer smoke test on `main.py --once` so these settings
cannot diverge. A successful ping needs an assistant message and a completed turn, not just exit 0.
Auth failures skip retries. Do not claim a ping resets or guarantees a new subscription window.

Tests: `.codex/testing/codex-auto-ping/`; run them explicitly as documented in README.md.
