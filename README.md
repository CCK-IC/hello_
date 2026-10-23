# hello_

A new Flutter project.


**BLE packet formatting**
---

# Full Status v1 packet

The Full Device Status characteristic UUID is:

```text
8f7c0021-4f54-4d55-8000-5849414f494d
```

Full Status v1 is a fixed-size, explicitly encoded binary packet containing runtime, BLE, IMU, battery, memory, and error diagnostics.

## Complete packet layout

| Offset | Size | Type | Field | Remark|
|---:|---:|---|---|---|
| 0 | 1 | `uint8` | Format version |
| 1 | 1 | `uint8` | Board identifier |
| 2 | 1 | `uint8` bit field | System flags |
| 3 | 1 | `uint8` | IMU state |
| 4 | 4 | `uint32_le` | Uptime in milliseconds |
| 8 | 2 | `uint16_le` | Requested IMU/notification rate in Hz |
| 10 | 2 | `uint16_le` | Measured sensor sample rate in Hz |
| 12 | 2 | `uint16_le` | Measured successful BLE notification rate in Hz |
| 14 | 2 | `uint16_le` | Status update period in milliseconds |
| 16 | 2 | `uint16_le` | Compensated battery voltage in millivolts |
| 18 | 1 | `uint8` | Estimated battery percentage | redundancy to be removed
| 19 | 1 | `uint8` | ICM-20948 `WHO_AM_I` value |
| 20 | 2 | `uint16_le` | Negotiated ATT MTU |
| 22 | 2 | `uint16_le` | BLE connection handle |
| 24 | 4 | `uint32_le` | Current free heap in bytes |
| 28 | 4 | `uint32_le` | Minimum free heap since startup in bytes |
| 32 | 4 | `uint32_le` | Published IMU sample count |
| 36 | 4 | `uint32_le` | Dropped IMU sample count |
| 40 | 4 | `uint32_le` | Dropped or failed notification count |
| 44 | 4 | `uint32_le` | FIFO overflow/recovery count |
| 48 | 4 | `uint32_le` | I2C error count |
| 52 | 4 | `uint32_le` | IMU reinitialization count |
| 56 | 4 | `int32_le` | Last application or ESP-IDF error code |
| 60 | 1 | `uint8` | Firmware major version |
| 61 | 1 | `uint8` | Firmware minor version |
| 62 | 1 | `uint8` | Firmware patch version |
| 63 | 1 | `uint8` | BLE PHY identifier; zero means unknown |
---

# Compact Status v2 packet

The Compact Device Status characteristic UUID is same as Full packet, switch Full/Compact according to MTU:
```text
8f7c0021-4f54-4d55-8000-5849414f494d 
```

Compact Status v2 is a fixed-size, simplified version of the Full Status binary packet containing runtime, BLE, IMU, battery.

## Complete packet layout

| Offset | Size | Type | Field | Remark|
|---:|---:|---|---|---|
| 0 | 1 | `uint8` | Format version |
| 1 | 1 | `uint8` bit field | System flags |
| 2 | 4 | `uint32_le` | Uptime in milliseconds |
| 6 | 2 | `uint16_le` | Requested IMU/notification rate in Hz |
| 8 | 2 | `uint16_le` | Measured sensor sample rate in Hz |
| 10 | 2 | `uint16_le` | Measured successful BLE notification rate in Hz |
| 12 | 2 | `uint16_le` | Compensated battery voltage in millivolts |
| 14 | 1 | `uint8` | Estimated battery percentage | Redundancy to be removed
| 15 | 1 | `uint8` | IMU state |
| 16 | 2 | `uint16_le` | Negotiated ATT MTU |
| 18 | 1 | `uint8` casted | Dropped or failed notification count |
| 19 | 1 | `uint8` casted | FIFO overflow/recovery + I2C error count |
---
# Full IMU RAW v1 packet

The Full IMU RAW data characteristic UUID is:

```text
8f7c0099-4f54-4d55-8000-5849414f494d
```

Full IMU RAW v1 is a fixed-size, explicitly encoded binary packet containing IMU status,  timestamp, Accelerometer range code,  Gyroscope range code, Packet sequence #,
Accelerometer - X, Accelerometer - Y, Accelerometer - Z,
Gyroscope - X, Gyroscope - Y, Gyroscope - Z, 
Magnetometer - X, Magnetomete r- Y, Magnetometer - Z, 
IMU Temperature, and Real-time Sampling rate.

## Complete packet layout

| Offset | Size | Type | Field | Remark|
|---:|---:|---|---|---|
| 0 | 1 | `uint8` | Format version |
| 1 | 1 | `uint8` | IMU state |
| 2 | 1 | `uint8`  | Accelerometer range code |
| 3 | 1 | `uint8` | Gyroscope range code |
| 4 | 4 | `uint32_le` | Packet sequence # |
| 8 | 4 | `uint32_le` | Packet Timestamp in milliseconds |
| 12 | 2 | `uint16_le` | Accelerometer - X Axis|
| 14 | 2 | `uint16_le` | Accelerometer - Y Axis |
| 16 | 2 | `uint16_le` | Accelerometer - Z Axis |
| 18 | 2 | `uint16_le` | Gyroscope - X Axis| 
| 19 | 2 | `uint16_le` | Gyroscope - Y Axis|
| 20 | 2 | `uint16_le` | Gyroscope - Z Axis|
| 22 | 2 | `uint16_le` | Magnetometer - X Axis|
| 24 | 2 | `uint16_le` | Magnetometer - Y Axis|
| 28 | 2 | `uint16_le` | Magnetometer - Z Axis|
| 30 | 2 | `uint16_le` | IMU Temperature |
| 32 | 2 | `uint16_le` | Real-time Sampling rate |
---
# Compact IMU RAW v2 packet

The Compact IMU RAW data characteristic UUID is same as Full packet, switch Full/Compact according to MTU:

```text
8f7c0099-4f54-4d55-8000-5849414f494d
```

Compact IMU RAW v2 is a fixed-size, simplified version of the Full IMU binary packet containing IMU status,  timestamp, Packet sequence #,
Accelerometer - X, Accelerometer - Y, Accelerometer - Z,
Gyroscope - X, Gyroscope - Y, Gyroscope - Z,

## Complete packet layout

| Offset | Size | Type | Field | Remark|
|---:|---:|---|---|---|
| 0 | 1 | `uint8` | Format version |
| 1 | 1 | `uint8` | IMU state |
| 2 | 2 | `uint16_le` | Packet sequence # |
| 4 | 4 | `uint32_le` | Packet Timestamp in milliseconds |
| 8 | 2 | `uint16_le` | Accelerometer - X Axis|
| 10 | 2 | `uint16_le` | Accelerometer - Y Axis |
| 12 | 2 | `uint16_le` | Accelerometer - Z Axis |
| 14 | 2 | `uint16_le` | Gyroscope - X Axis| 
| 16 | 2 | `uint16_le` | Gyroscope - Y Axis|
| 18 | 2 | `uint16_le` | Gyroscope - Z Axis|
---
# AUX(ADC) v1 packet

The AUX characteristic UUID is:

```text
8f7c0011-4f54-4d55-8000-5849414f494d
```

AUX v1 is a fixed-size, explicitly encoded binary packet containing IMU status,  timestamp, Packet sequence #,
Accelerometer - X, Accelerometer - Y, Accelerometer - Z,
Gyroscope - X, Gyroscope - Y, Gyroscope - Z,

## Complete packet layout

| Offset | Size | Type | Field | Remark|
|---:|---:|---|---|---|
| 0 | 1 | `uint8` | Format version |
| 1 | 1 | `uint8` |Packet sequence # | 
| 2 | 2 | `uint32_le` |Packet Timestamp in milliseconds |
| 6 | 4 | `uint16_le` | ADC CH1 value |
| 8 | 2 | `uint16_le` | ADC CH2 value |
| 10 | 2 | `uint16_le` | ADC CH3 value  |
| 12 | 2 | `uint16_le` | ADC CH4 value  |
| 14 | 2 | `uint16_le` | ADC CH5 value | 
| 16 | 2 | `uint16_le` | ADC CH6 value |
| 18 | 2 | `uint16_le` | ADC CH7 value |
| 20 | 2 | `uint16_le` | ADC CH8 value |