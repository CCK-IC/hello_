# BLE project handoff

Last updated: 2026-10-30. Update this file after each meaningful test or change,
including the result, relevant commit, and remaining work. Share the updated
file through the repository's normal Git workflow so other checkouts receive it.

The app and sensor firmware are separate repositories. Mac and Windows also use separate checkouts: verify each checkout's repository, branch, commits, and local changes before transferring work. A commit in one checkout does not automatically update another.

## Known work

- App `8f3296c` stabilized Mac Chrome BLE streaming and controls; `f086047` subsequently attempted to improve the Windows BLE connection lifecycle. The latter is **not verified on Windows native or Chrome hardware**.
- The firmware repository on this Mac currently has HEAD `f97e7c83cabda4158e3f3f6879b34a17116fdc50` (`Refactor sensor firmware and stabilize BLE streaming`). An earlier session reported firmware commit `6b8093b`; it exists locally, but check the destination checkout's history rather than assuming its state.
- Mac Chrome testing with the board nearby succeeded at 10 Hz: a recovery command completed, streaming continued for a minute, and the reported drop counter did not increase. Earlier tests saw radio timeouts and BLE buffer exhaustion; 25 Hz still showed occasional drops. The app defaults to 10 Hz on Mac Chrome and 25 Hz on Windows.
- Firmware changes include requesting a longer BLE supervision timeout and clearing stale subscriptions on disconnect. Build and flash state on another machine or board must be checked independently.

## Next session

1. Inspect both checkouts and bring the intended app and firmware commits into the Windows environment using the project's normal workflow. Preserve any local changes.
2. With the sensor nearby, test Windows native and Chrome separately: scan, connect, discover services, stream, send a command, and confirm the connection remains stable. Record duration, stream rate, sequence gaps, and drop-counter changes. Exercise disconnect and reconnect as well.
3. If a disconnect or loss recurs, collect app logs and firmware serial logs, including disconnect reason, negotiated connection parameters, and notification errors. Compare results at 10 Hz and 25 Hz before changing defaults. Fix the observed cause and repeat both client tests.
4. Run the relevant Flutter analysis/build and firmware checks for any changes. Record tested versions, results, and remaining limitations here for the next session.
