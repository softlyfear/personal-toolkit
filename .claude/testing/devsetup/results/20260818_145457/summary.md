
| Scenario | Result | Note |
|---|---|---|
| 01_HELP | PASS | — |
| 02_UNKNOWN_TOOL | PASS | — |
| 03_NO_ARGS_DEFAULT_ALL | FAIL | exit=1, expected 0 (see /work/results/20260818_145457/03_NO_ARGS_DEFAULT_ALL.log) |
| 04_GIT_ONLY | PASS | — |
| 05_MAKE_ONLY | PASS | — |
| 06_POSTGRESQL_ONLY | PASS | — |
| 07_DOCKER_ONLY | PASS | — |
| 08_MULTIPLE_TOOLS | PASS | — |
| 09_UV_ONLY | FAIL | exit=1, expected 0 (see /work/results/20260818_145457/09_UV_ONLY.log) |
| 10_INTERACTIVE_MIXED | PASS | — |
| 11_INTERACTIVE_NONE_SELECTED | PASS | — |
| 12_IDEMPOTENT_RERUN | PASS | — |
