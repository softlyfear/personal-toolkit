
| Scenario | Result | Note |
|---|---|---|
| 01_TOO_FEW_ARGS | FAIL | verify failed, see /work/results/20260818_175554/01_TOO_FEW_ARGS.log |
| 02_INVALID_ACTION | FAIL | verify failed, see /work/results/20260818_175554/02_INVALID_ACTION.log |
| 03_INVALID_SERVICE | FAIL | verify failed, see /work/results/20260818_175554/03_INVALID_SERVICE.log |
| 04_STATUS_ALL_UNINSTALLED | FAIL | exit=1, expected 0 (see /work/results/20260818_175554/04_STATUS_ALL_UNINSTALLED.log) |
| 05_POSTGRESQL_LIFECYCLE | FAIL | stop failed |
| 06_DOCKER_LIFECYCLE | FAIL | stop failed |
| 07_ALL_TARGET_STATUS | FAIL | exit=1, expected 0 |
| INSTALL_SVCCTL_FRESH_AND_IDEMPOTENT | FAIL | fresh install exit=1 (see /work/results/20260818_175554/INSTALL_SVCCTL_FRESH_AND_IDEMPOTENT_fresh.log) |
| 08_INSTALL_SVCCTL_MISSING_WGET | FAIL | wrong/missing error message |
| 10_INSTALL_SVCCTL_NONROOT_NO_SUDO | FAIL | wrong/missing error message |
