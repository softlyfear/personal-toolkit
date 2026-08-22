
| Scenario | Result | Note |
|---|---|---|
| 01_FRESH_FULL_RUN | FAIL | exit=1, expected 0 (see /work/results/20260818_175554/01_FRESH_FULL_RUN.log) |
| 02_REBOOT_REQUIRED | FAIL | exit=1, expected 0 (see /work/results/20260818_175554/02_REBOOT_REQUIRED.log) |
| 03_NONROOT_SUDO | FAIL | exit=1, expected 0 (see /work/results/20260818_175554/03_NONROOT_SUDO.log) |
| 04_NONROOT_NO_SUDO | FAIL | wrong/missing error message |
| 05_IDEMPOTENT_RERUN | FAIL | run1=1 run2=1 (expected both 0) |
| INSTALL_SYSUPDATE_FRESH_AND_IDEMPOTENT | FAIL | fresh install exit=1 (see /work/results/20260818_175554/INSTALL_SYSUPDATE_FRESH_AND_IDEMPOTENT_fresh.log) |
| 06_INSTALL_SYSUPDATE_MISSING_WGET | FAIL | wrong/missing error message |
| 07_INSTALL_SYSUPDATE_NONROOT_SUDO | FAIL | exit=1, expected 0 (see /work/results/20260818_175554/07_INSTALL_SYSUPDATE_NONROOT_SUDO.log) |
| 08_INSTALL_SYSUPDATE_NONROOT_NO_SUDO | FAIL | wrong/missing error message |
