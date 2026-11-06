# BLE IMU Monitor

BLE IMU Monitor is a Flutter app for streaming motion data from one compatible
`XIAO-IMU-RAW` sensor at a time. It plots raw IMU and auxiliary ADC readings,
estimates dominant frequencies in two configurable bands, and exports raw IMU
samples or frequency estimates to CSV.

[Run the app](#run-the-app) · [Connect a sensor](#connect-a-sensor) ·
[Use the dashboard](#use-the-dashboard) · [Analyze motion](#analyze-motion) ·
[Export CSV](#export-csv) · [BLE protocol](#ble-protocol)

## Run the app

You need a BLE-capable host and a powered sensor running firmware that implements
the [BLE protocol](#ble-protocol) below. The firmware is maintained separately.
To build from source, follow the [Flutter installation guide](https://docs.flutter.dev/install)
for your target and use an SDK compatible with this checkout's `pubspec.lock`.

From the project directory:

```sh
flutter doctor -v
flutter pub get
flutter devices
```

| Target | Run from the project directory |
| --- | --- |
| Web | `flutter run -d chrome` |
| Android or iOS | `flutter run -d DEVICE_ID` (use the ID from `flutter devices`) |
| macOS | `flutter run -d macos` |
| Windows | `flutter run -d windows` |
| Linux | `flutter run -d linux` |

Use a physical device for mobile BLE testing. For web deployment, run
`flutter build web` and serve `build/web` over HTTPS. Local development can use
`localhost`. Use Chrome on a host that supports
[Web Bluetooth](https://developer.chrome.com/docs/capabilities/bluetooth#security-requirements).

## Connect a sensor

1. Turn on Bluetooth and power on the sensor. Grant Bluetooth or Nearby Devices
   access if your OS prompts for it.
2. Select **Find devices**. On native platforms, **Available IMU sensors** lists
   devices whose advertised name starts with `XIAO-IMU-RAW` or whose advertisement
   contains a supported service UUID. On the web, select the sensor in Chrome's
   Bluetooth chooser to add it to the app's list.
3. Select **Connect** on the sensor card. Once setup finishes, the dashboard
   opens and starts receiving raw IMU data. Use the disconnect button in the app
   bar when finished.

If the sensor does not appear, move it closer, check that it is advertising,
disconnect it from any other client, and scan again. If a subscription times out
or the dashboard reports a stalled stream, disconnect and reconnect before
retrying. For repeated packet loss, try a lower requested rate and check the
received rate and device telemetry.

## Use the dashboard

| Section | What you can do |
| --- | --- |
| **Device telemetry** | View IMU state, battery, reported sample and notification rates, uptime, and drop or recovery counters. Enable **Device status** under **BLE subscriptions** if telemetry is off. Status starts off on Windows. |
| **Raw ICM-20948 Data** | Inspect the latest accelerometer values in g and gyroscope values in °/s, plus their raw counts. Full Raw v1 packets also carry magnetometer and temperature counts. |
| **Raw data visualization** | Select multiple signals to plot, set the **Chart time window**, and choose how much raw data the **IMU history buffer** retains (1–60 minutes, default 10 minutes). |
| **ADC auxiliary** | Enable **Auxiliary sensor** under **BLE subscriptions** and select any of the eight channels. The chart shares the raw IMU time window. The buffer is measured in samples (default 6,000). ADC requires compatible firmware and a negotiated ATT MTU of at least 25. |
| **Control Commands** | Set the requested notification rate (1–200 Hz, default 45 Hz) or status update period (250–5,000 ms, default 1,000 ms). You can also enable **Slow/Debug Mode**, request **Reinit IMU**, or confirm **Power Off**. |

The requested rate is the setting sent to the sensor. Actual sample and BLE
notification rates depend on the device and connection. The app follows the
system light or dark theme and supports larger text and screen-reader labels.

## Analyze motion

1. Keep **IMU raw** enabled and open **Analyze IMU data** from the app bar.
2. Select **Acceleration** or **Angular velocity** and collect several seconds of
   steady motion. The app estimates a candidate peak for each band using up to
   eight seconds of recent samples and reports the observed sample rate and
   Nyquist limit.
3. Adjust the ranges under **Frequency bands** and select **Apply bands**. The
   defaults are **1–5 Hz** for percussion and **6.5–10 Hz** for vibration.
4. Use **Frequency history** to show either or both bands. Set a display window
   from 10 seconds to 5 minutes and a history buffer from 1 to 60 minutes.

History records at most one new estimate per second when fresh samples arrive
and retains up to 3,600 estimates. The chart leaves gaps when estimates are
unavailable or when the selected signal or band settings change. Candidate
peaks describe periodic motion in the selected signal and are not a clinical
assessment.

## Export CSV

| Data | Timed recording | Export the retained buffer |
| --- | --- | --- |
| Raw IMU samples | In **Raw data visualization**, choose a **Recording duration** and select **Record CSV**. The app saves when the timer ends. | **Save buffer CSV** exports the raw history retained by the IMU buffer setting. |
| Frequency estimates | In **IMU frequency analysis**, choose a **Recording duration** and select **Record CSV**. The app saves when the timer ends, or when you select **Stop and save**. | **Save buffer CSV** exports the estimates retained by the frequency history setting. |

Raw IMU CSV contains one row per received and accepted sample, with receive time,
device timestamp, sequence, flags, sensor counts, and scaled accelerometer and
gyroscope values. Fields absent from compact packets are blank. The raw history
can retain samples across connections, so use a timed recording for a separate
file per sensor. Keep the sensor connected until that recording finishes.

Frequency CSV contains one row per estimate and band, with the selected signal,
band bounds, sample rate, candidate peak, and the reason when a peak is
unavailable. Save the frequency history before leaving the analysis page or
disconnecting. If a connection ends during a frequency recording, select
**Save recording CSV** on that page to save the partial recording.

Chrome downloads the file. Android, iOS, macOS, and Windows use a native save
dialog. The pinned save plugin does not implement that dialog on Linux. The ADC
chart displays live readings and has no CSV export control.

## BLE protocol

The app acts as a BLE central and subscribes to notifications. UUIDs are shown
in full below. Multi-byte values in packets and commands use little-endian
order, and offsets are zero-based.

| Stream or action | Service UUID | Characteristic UUID |
| --- | --- | --- |
| Raw IMU | `8f7c0001-4f54-4d55-8000-5849414f494d` | `8f7c0099-4f54-4d55-8000-5849414f494d` |
| Auxiliary ADC | `8f7c0010-4f54-4d55-8000-5849414f494d` | `8f7c0011-4f54-4d55-8000-5849414f494d` |
| Device status | `8f7c0020-4f54-4d55-8000-5849414f494d` | `8f7c0021-4f54-4d55-8000-5849414f494d` |
| Control writes | `8f7c0020-4f54-4d55-8000-5849414f494d` | `8f7c0022-4f54-4d55-8000-5849414f494d` |

### Control commands

| Command | Bytes in wire order |
| --- | --- |
| Set notification rate | `01` followed by an unsigned 16-bit rate in Hz (1–200) |
| Set status update period | `02` followed by an unsigned 16-bit period in ms (250–60,000 on the wire) |
| Set slow/debug mode | `04 00` for off, `04 01` for on |
| Request power-off | `05 A5 5A` |
| Request sensor recovery | `06` |

### Notification layouts

In the tables, `u8`, `u16`, and `u32` are unsigned integers, and `i16` and
`i32` are signed integers of the indicated bit width. Firmware can use the
compact IMU and status packets when the negotiated ATT payload cannot fit the
full version and compact fallback is enabled.

<details>
<summary>Raw IMU v1 and v2</summary>

Both versions use the Raw IMU characteristic. The app accepts **36 bytes** for
full v1 and **20 bytes** for compact v2.

| Field | Full v1 offset and type | Compact v2 offset and type |
| --- | --- | --- |
| Version | 0, `u8` = 1 | 0, `u8` = 2 |
| Flags | 1, `u8` | 1, `u8` |
| Accelerometer / gyroscope range codes | 2 / 3, `u8` each | Packed into flags |
| Sequence | 4, `u32` | 2, `u16` |
| Device timestamp (ms) | 8, `u32` | 4, `u32` |
| Accelerometer X / Y / Z | 12 / 14 / 16, `i16` each | 8 / 10 / 12, `i16` each |
| Gyroscope X / Y / Z | 18 / 20 / 22, `i16` each | 14 / 16 / 18, `i16` each |
| Magnetometer X / Y / Z | 24 / 26 / 28, `i16` each | — |
| Temperature counts | 30, `i16` | — |
| Measured rate (Hz) | 32, `u16` | — |
| Reserved | 34, `u16` = 0 | — |

Flags at bits 0–2 indicate sample, accelerometer, and gyroscope validity in
both versions. In full v1, bits 3–6 indicate magnetometer validity, temperature
validity, magnetometer overflow, and DMP active, respectively. Bit 7 must be
zero. In compact v2, bit 3 indicates DMP active, bits 4–5 hold the accelerometer
range code, and bits 6–7 hold the gyroscope range code. Codes 0–3 represent
±2/4/8/16 g and ±250/500/1000/2000 °/s, respectively.

</details>

<details>
<summary>Device status v1 and v2</summary>

Both versions use the Device status characteristic. Full v1 has **64 bytes**;
compact v2 has **20 bytes**. The table includes firmware fields even where the
app does not display them.

| Field | Full v1 offset and type | Compact v2 offset and type |
| --- | --- | --- |
| Version | 0, `u8` = 1 | 0, `u8` = 2 |
| Board ID | 1, `u8` (1 = XIAO ESP32-C3, 2 = XIAO ESP32-S3) | — |
| System flags | 2, `u8` | 1, `u8` |
| IMU state | 3, `u8` | 15, `u8` |
| Uptime (ms) | 4, `u32` | 2, `u32` |
| Requested rate (Hz) | 8, `u16` | 6, `u16` |
| Sensor sample rate (Hz) | 10, `u16` | 8, `u16` |
| BLE notification rate (Hz) | 12, `u16` | 10, `u16` |
| Status period (ms) | 14, `u16` | — |
| Battery (mV) | 16, `u16` | 12, `u16` |
| Battery (%) | 18, `u8` | 14, `u8` |
| IMU `WHO_AM_I` | 19, `u8` | — |
| Negotiated ATT MTU | 20, `u16` | 16, `u16` |
| BLE connection handle | 22, `u16` | — |
| Free / minimum free heap (bytes) | 24 / 28, `u32` each | — |
| Published / dropped sample counts | 32 / 36, `u32` each | — |
| Dropped notifications | 40, `u32` | 18, `u8` (saturating) |
| FIFO overflows / I²C errors | 44 / 48, `u32` each | 19, combined saturating `u8` |
| IMU reinitializations | 52, `u32` | — |
| Last error | 56, `i32` | — |
| Firmware major / minor / patch | 60 / 61 / 62, `u8` each | — |
| BLE PHY (0 = unknown) | 63, `u8` | — |

</details>

<details>
<summary>Auxiliary ADC v1</summary>

The payload is exactly **22 bytes**, so a notification requires an ATT MTU of
at least **25**.

| Field | Offset and type |
| --- | --- |
| Version | 0, `u8` = 1 |
| Sequence | 1, `u8` |
| Device timestamp (ms) | 2, `u32` |
| Channel 1–8 raw counts | 6 / 8 / 10 / 12 / 14 / 16 / 18 / 20, `i16` each |

</details>

## Development

```sh
flutter analyze
flutter test
flutter test --platform chrome test/web_scan_test.dart
```

Run with `--dart-define=BLE_DIAGNOSTICS=true` to log received raw packet counts,
inferred sequence gaps, and the age of the latest notification.

The Flutter dashboard and BLE lifecycle live in [lib/main.dart](lib/main.dart).
See [protocol.dart](lib/models/protocol.dart) and
[adc_history.dart](lib/models/adc_history.dart) for the decoders, and
[imu_frequency_analysis.dart](lib/models/imu_frequency_analysis.dart) for the
frequency estimator. See [HANDOFF.md](HANDOFF.md) for cross-machine test results
and outstanding hardware issues.
