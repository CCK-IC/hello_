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

## Windows investigation, 2026-10-30

- Checkout: Windows app branch `NO_DMP`, starting commit `038250c`; subsequent changes are recorded in Git.
  Flutter 3.47.5, universal_ble 3.1.1, Windows 10.0.26200.9168.
  Sensor firmware version and serial logs were not available.
- A native Flutter probe found the powered XIAO-IMU-RAW. One connection attempt
  timed out after 30 seconds while the plugin waited in WinRT
  `BluetoothLEDevice.GetGattServicesAsync(Uncached)`. A later attempt connected,
  discovered seven services and received 152 raw notifications over 15 seconds
  at approximately 10 Hz, then disconnected. Reconnect stalled at the same
  uncached service query and timed out after 90 seconds. No command or 25 Hz
  run was tested. A longer timeout alone did not solve reconnect reliability.
- universal_ble invalidates a pending connection on disconnect, but a timed-out
  underlying WinRT service query may remain in flight; investigate the plugin,
  Windows Bluetooth adapter and firmware serial disconnect logs before retrying
  repeatedly or attributing the failure to subscriptions.
- The app now prevents overlapping subscription changes per stream, ignores
  stale completions after disconnect, and blocks further changes to a stream
  after a timeout until reconnect. Chrome scan UI now releases its scanning
  state when the device chooser closes and does not queue a stop behind it.
  These address distinct lifecycle defects; neither proves the Windows link
  failure is fixed.
- Flutter Windows and web release builds passed. The three subscription-gate
  unit tests passed. The Chrome widget test runner stalled before loading, and
  the computer-use runtime failed to start with Windows error 1385, so Windows
  Chrome hardware testing remains outstanding. Flutter analysis retains six
  pre-existing lint findings.
- Next: gather firmware serial logs and Windows/plugin logs during the stalled
  WinRT query; reproduce on another Windows Bluetooth adapter if available.
  Then verify Windows native and Chrome scan, connection, streaming at 10 and
  25 Hz, command, disconnect and reconnect, recording durations and drops.
  Test the Chrome chooser widget test on a working browser test runner.

## Follow-up Windows hardware test, 2026-10-30

- The Windows command sandbox and computer-use runtime still failed to start
  with CreateProcessWithLogonW error 1385; elevated commands worked. The
  browser widget-test runner again stalled while loading.
- With COM4 monitoring open (opening it reset the ESP32-C3), a fresh native
  connection succeeded in 2.63 seconds. At 10 Hz it delivered 27 raw
  notifications and then stopped after about 3 seconds. Firmware repeatedly
  logged raw notification enqueue failure rc=6 (BLE_HS_ENOMEM); raw drop count
  reached 168 and firmware reported supervision timeout reason 0x0208 around
  22 seconds after connection. Windows had not emitted a disconnect event
  by 45 seconds. A later scan did not find the device within 20 seconds, so
  25 Hz was not verified. Do not assume this was a UI-only freeze.
- The Windows firmware checkout at
  C:/Users/ckchow/Desktop/Project_local/@DEV/ESP-IDF/xiao_imu_ble is on main
  at eacc082, with an existing modified sdkconfig.defaults. It does not contain
  the observed enqueue-failure log and is not the handoff's f97e7c8 revision.
  Remote main points to 92468d5; f97e7c8 is not in this checkout. Obtain the
  matching source before modifying or flashing firmware; preserve local edits.
- The app now warns after 10 seconds without raw notifications while the
  stream is enabled, without assuming disconnect or automatically retrying.
  The rate control distinguishes the rate to send from a rate actually sent.
  Opt-in diagnostics (`--dart-define=BLE_DIAGNOSTICS=true`; use two ASCII
  hyphens) report raw notifications, inferred gaps and last-packet age.
  These changes improve diagnosis and recovery but do not fix NimBLE
  buffer exhaustion.
- Flutter tests: 10 VM tests passed; web and Windows release builds passed (Windows passed after stopping an abandoned probe build). Chrome hardware testing was handed to the user via a local
  diagnostic server; capture its result and firmware logs when available.
  Existing Flutter analysis has six pre-existing diagnostics.

- The user identified C:/Users/ckchow/Desktop/Glove_Firmware as an imported
  repository. It is a different repository at 848bcc7; f97e7c8 and the exact
  enqueue-failure log are absent. Existing edits to main/Kconfig.projbuild and
  main/imu/imu_manager.c were preserved. Its source cannot be assumed to
  match the flashed sensor. See the Chrome retest below.

## Chrome connection log follow-up, 2026-10-30

- User reported Chrome `UniversalBleException` with `Could not connect to device ... for unknown reason`, before physical-connection, discovery or subscription logs. A previous `connected=true packets=0` line alone does not prove setup completed.
- universal_ble 3.1.1 uses flutter_web_bluetooth 1.2.0 for `gatt.connect()`. That dependency replaces a browser DOM NetworkError with a generic message and drops the original details. The specific cause is unknown. A fresh attempt after a sensor restart, paired with firmware logs, is needed. Avoid modifying the Pub cache.

## Chrome retest, 2026-10-30

- After the user selected XIAO-IMU-RAW in Chrome's Bluetooth picker, the app connected and completed setup. Raw IMU streaming continued for over one minute at a requested 25 Hz; the displayed buffer grew from 111 to 1,888 samples, and the displayed raw rate was 25–26 Hz. No stall was observed during this run.
- Device status notifications were disabled; dashboard drop counters were not live and must not be interpreted as zero drops. No serial log, sequence-gap total, command, disconnect or reconnect test was captured. Native reliability and the previously observed firmware buffer exhaustion remain unresolved.

## AUX ADC visualization

- Added an AUX v1 decoder and an eight-channel raw-count chart to the dashboard. Enable the auxiliary subscription; notifications require an ATT MTU of at least 25. The 22-byte firmware packet uses signed 16-bit channel values.
- IMU history duration and ADC history sample limits are selectable. Control selections survive dashboard rebuilds and are reapplied on reconnect.
- On macOS Chrome, a live sensor delivered all eight ADC channel values; selection and both buffer controls worked. A 14 Hz setting survived scrolling and reconnect, and ADC notifications resumed. The reported drop counter stayed at zero during the observed session. A resized IMU buffer CSV download completed; its contents were not inspected because macOS denied access to Downloads.
- Android requests a larger MTU before enabling AUX; this and Windows/native BLE remain unverified on hardware. Web, Windows and macOS manage MTU outside the app.
- Ten automated tests and the web build passed after the MTU and partial slow-mode failure fixes. On the final build, the identified ADC test sensor connected after a fresh scan, displayed all eight ADC channels, and stayed connected while slow mode was toggled on and off. The rate returned to 10 Hz and the drop counter remained zero. Two XIAO-IMU-RAW devices appeared in Chrome, so verify the selected device. The ADC values observed were static; electrical input changes were not tested.

## Windows and Mac integration, 2026-10-30

- Integrated Windows app commit `47e79cb` with the Mac ADC, buffer and persistent-control changes. The last successfully sent rate now survives dashboard rebuilds and resets for each new connection. A timed-out raw unsubscribe resumes stall monitoring while blocking further changes until reconnect.
- On the Mac, 23 VM tests passed, including a simulated unsubscribe-timeout regression, as did the Chrome chooser test. The web release build passed. Flutter analysis reports the same six pre-existing warning/info findings.
- The combined build has not been tested with BLE hardware. Windows native disconnects and the firmware buffer exhaustion documented above remain unresolved; the tests do not establish Windows hardware stability.
