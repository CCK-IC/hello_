import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/protocol.dart';

enum DeviceStatusConnection { disconnected, connecting, connected }

typedef DeviceStatusSnapshot = ({
  DeviceStatusConnection connection,
  String? deviceName,
  DeviceStatus? telemetry,
  int? imuSampleRateHz,
  int? adcSampleRateHz,
  bool statusEnabled,
  bool rawEnabled,
  bool adcEnabled,
  bool rawStalled,
});

/// Live device and stream status for an [AppBar.bottom].
class DeviceStatusTopBar extends StatelessWidget
    implements PreferredSizeWidget {
  const DeviceStatusTopBar({
    super.key,
    required this.listenable,
    required this.textScaler,
  });

  final ValueListenable<DeviceStatusSnapshot> listenable;

  /// Use the same scaler as the surrounding [MediaQuery].
  final TextScaler textScaler;

  static const _metricSize = 12.0;
  static const _headerSize = 14.0;
  static const _lineHeight = 1.25;

  double get _metricHeight => textScaler.scale(_metricSize) * _lineHeight + 4;
  double get _headerHeight => math.max(
        kMinInteractiveDimension,
        textScaler.scale(_headerSize) * _lineHeight + 8,
      );

  @override
  Size get preferredSize =>
      Size.fromHeight(_headerHeight + 3 * _metricHeight + 5);

  void _showDetails(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _DeviceStatusDetails(listenable: listenable),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final metricStyle =
        (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
      color: colors.onSurface,
      fontSize: _metricSize,
      height: _lineHeight,
      letterSpacing: 0,
    );
    final headerStyle = metricStyle.copyWith(
        fontSize: _headerSize, fontWeight: FontWeight.w600);

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: Material(
        color: colors.surfaceContainerLow,
        child: Container(
          height: preferredSize.height,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: DefaultTextStyle(
              style: metricStyle,
              child: ValueListenableBuilder<DeviceStatusSnapshot>(
                valueListenable: listenable,
                builder: (context, snapshot, detailsButton) => Column(
                  children: [
                    SizedBox(
                      height: _headerHeight,
                      child: Row(
                        children: [
                          Expanded(
                            child: DefaultTextStyle(
                              style: headerStyle,
                              child: _Reading(
                                label: 'Bluetooth',
                                text: snapshot.connectionTitle,
                                spokenValue: snapshot.connectionDescription,
                                liveRegion: true,
                                icon: switch (snapshot.connection) {
                                  DeviceStatusConnection.disconnected =>
                                    Icons.bluetooth_disabled,
                                  DeviceStatusConnection.connecting =>
                                    Icons.bluetooth_searching,
                                  DeviceStatusConnection.connected =>
                                    Icons.bluetooth_connected,
                                },
                                iconColor: snapshot.isConnected
                                    ? colors.primary
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          detailsButton!,
                        ],
                      ),
                    ),
                    SizedBox(
                      height: _metricHeight,
                      child: _DeviceSummary(snapshot: snapshot),
                    ),
                    for (final stream in ['IMU', 'ADC'])
                      SizedBox(
                        height: _metricHeight,
                        child: _RateRow(
                          stream: stream,
                          labelWidth: textScaler.scale(_metricSize) * 2.25,
                          sampleRate: stream == 'IMU'
                              ? snapshot.imuRate
                              : snapshot.adcRate,
                          notificationRate: stream == 'IMU'
                              ? snapshot.status?.notificationRate
                              : snapshot.status?.adcNotificationRate,
                          sampleUnavailable: snapshot.sampleUnavailable(stream),
                          notificationUnavailable: snapshot.statusMessage,
                        ),
                      ),
                  ],
                ),
                child: Tooltip(
                  message: 'Device status details',
                  excludeFromSemantics: true,
                  child: TextButton(
                    onPressed: () => _showDetails(context),
                    style: TextButton.styleFrom(
                      textStyle: headerStyle,
                      minimumSize: const Size.square(kMinInteractiveDimension),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('Details',
                        semanticsLabel: 'Device status details'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

extension on DeviceStatusSnapshot {
  bool get isConnected => connection == DeviceStatusConnection.connected;

  DeviceStatus? get status => isConnected && statusEnabled ? telemetry : null;

  String get connectionLabel => switch (connection) {
        DeviceStatusConnection.disconnected => 'Disconnected',
        DeviceStatusConnection.connecting => 'Connecting',
        DeviceStatusConnection.connected => 'Connected',
      };

  String? get displayName {
    final name = deviceName?.trim();
    return name == null || name.isEmpty ? null : name;
  }

  String get connectionTitle =>
      isConnected ? displayName ?? connectionLabel : connectionLabel;

  String get connectionDescription {
    final name = displayName;
    if (connection == DeviceStatusConnection.disconnected || name == null) {
      return connectionLabel;
    }
    return '$connectionLabel to $name';
  }

  /// The device-reported IMU rate can describe DMP when raw sampling is off.
  int? get imuRate {
    if (!isConnected) return null;
    return (rawEnabled && !rawStalled ? imuSampleRateHz : null) ??
        status?.actualSensorRate;
  }

  int? get adcRate => isConnected && adcEnabled ? adcSampleRateHz : null;

  String? get statusMessage {
    if (!isConnected) return connectionLabel;
    if (!statusEnabled) return 'Status disabled';
    if (status == null) return 'Waiting for status';
    return null;
  }

  String get rawStreamState => switch ((rawEnabled, rawStalled)) {
        (false, _) => 'Disabled',
        (true, true) => 'Stalled',
        (true, false) => 'Enabled',
      };

  String sampleUnavailable(String stream) {
    if (!isConnected) return connectionLabel;
    if (stream == 'ADC') {
      return adcEnabled ? 'Unavailable' : 'ADC stream disabled';
    }
    if (rawStalled && rawEnabled) return 'Raw IMU stream stalled';
    return rawEnabled ? 'Unavailable' : 'Raw IMU stream disabled';
  }
}

class _DeviceSummary extends StatelessWidget {
  const _DeviceSummary({required this.snapshot});

  final DeviceStatusSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final status = snapshot.status;
    final battery = status?.batteryPercent;
    final colors = Theme.of(context).colorScheme;
    final stalled =
        snapshot.isConnected && snapshot.rawEnabled && snapshot.rawStalled;

    return Row(
      children: [
        _Reading(
          label: 'Battery',
          text: battery == null ? '—' : '$battery%',
          spokenValue:
              battery == null ? snapshot.statusMessage : '$battery percent',
          icon: switch (battery) {
            null => Icons.battery_unknown,
            0 => Icons.battery_0_bar,
            <= 15 => Icons.battery_1_bar,
            <= 30 => Icons.battery_2_bar,
            <= 45 => Icons.battery_3_bar,
            <= 60 => Icons.battery_4_bar,
            <= 75 => Icons.battery_5_bar,
            <= 90 => Icons.battery_6_bar,
            _ => Icons.battery_full,
          },
          iconColor: battery != null && battery <= 15 ? colors.error : null,
        ),
        const SizedBox(width: 12),
        if (status == null && snapshot.isConnected)
          Expanded(
            child: Text(snapshot.statusMessage!,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          )
        else
          Expanded(
            child: _Reading(
              label: 'IMU state',
              text: 'IMU ${status?.imuStateString.toLowerCase() ?? '—'}',
              spokenValue: status?.imuStateString.toLowerCase() ??
                  snapshot.connectionLabel,
            ),
          ),
        if (stalled)
          _Reading(
            label: 'Raw IMU stream stalled',
            icon: Icons.warning_amber_rounded,
            iconColor: colors.error,
          ),
      ],
    );
  }
}

class _RateRow extends StatelessWidget {
  const _RateRow({
    required this.stream,
    required this.labelWidth,
    required this.sampleRate,
    required this.notificationRate,
    required this.sampleUnavailable,
    required this.notificationUnavailable,
  });

  final String stream;
  final double labelWidth;
  final int? sampleRate;
  final int? notificationRate;
  final String sampleUnavailable;
  final String? notificationUnavailable;

  @override
  Widget build(BuildContext context) {
    final legacyUnavailable =
        notificationRate == null && notificationUnavailable == null;
    return Row(
      children: [
        ExcludeSemantics(
          child: SizedBox(
            width: labelWidth,
            child: Text(stream,
                style: const TextStyle(fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ),
        Expanded(
          flex: 44,
          child: _Reading(
            label: '$stream sample rate',
            text: '${sampleRate ?? '—'} Hz',
            spokenValue:
                sampleRate == null ? sampleUnavailable : '$sampleRate hertz',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 56,
          child: _Reading(
            label: '$stream BLE notification rate',
            text:
                '${notificationRate ?? (legacyUnavailable ? 'N/A' : '—')} pkt/s',
            spokenValue: notificationRate == null
                ? notificationUnavailable ?? 'Unavailable on this firmware'
                : '$notificationRate packets per second',
          ),
        ),
      ],
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading({
    required this.label,
    this.text,
    this.spokenValue,
    this.icon,
    this.iconColor,
    this.liveRegion = false,
  });

  final String label;
  final String? text;
  final String? spokenValue;
  final IconData? icon;
  final Color? iconColor;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final value = spokenValue ?? text;
    final reading =
        Text(text ?? '', maxLines: 1, overflow: TextOverflow.ellipsis);
    return Semantics(
      container: true,
      excludeSemantics: true,
      liveRegion: liveRegion,
      label: label,
      value: value,
      child: Tooltip(
        message: value == null ? label : '$label · $value',
        excludeFromSemantics: true,
        child: icon == null
            ? reading
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: iconColor),
                  if (text != null) ...[
                    const SizedBox(width: 4),
                    Flexible(child: reading),
                  ],
                ],
              ),
      ),
    );
  }
}

class _DeviceStatusDetails extends StatelessWidget {
  const _DeviceStatusDetails({required this.listenable});

  final ValueListenable<DeviceStatusSnapshot> listenable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Device status details'),
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      content: SizedBox(
        width: 360,
        child: ValueListenableBuilder<DeviceStatusSnapshot>(
          valueListenable: listenable,
          builder: (context, snapshot, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value) in _readings(snapshot))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Semantics(
                    container: true,
                    excludeSemantics: true,
                    label: label,
                    value: value,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: theme.textTheme.labelMedium),
                        Text(value, style: theme.textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            minimumSize: const Size.square(kMinInteractiveDimension),
          ),
          child: const Text('Close'),
        ),
      ],
    );
  }

  List<(String, String)> _readings(DeviceStatusSnapshot snapshot) {
    final status = snapshot.status;
    final imuRate = snapshot.imuRate;
    final adcRate = snapshot.adcRate;
    final adcNotificationRate = status?.adcNotificationRate;
    return [
      ('Bluetooth', snapshot.connectionDescription),
      if (snapshot.isConnected) ...[
        if (snapshot.statusMessage case final message?)
          ('Device status', message),
        ('Raw IMU stream', snapshot.rawStreamState),
        ('ADC stream', snapshot.adcEnabled ? 'Enabled' : 'Disabled'),
        if (status == null || imuRate != status.actualSensorRate)
          (
            'IMU sample rate',
            imuRate == null ? snapshot.sampleUnavailable('IMU') : '$imuRate Hz'
          ),
        (
          'ADC sample rate',
          adcRate == null ? snapshot.sampleUnavailable('ADC') : '$adcRate Hz'
        ),
      ],
      if (status != null) ...[
        ('Board', status.boardName),
        (
          'Firmware',
          status.version == 2 ? 'Unavailable' : status.firmwareVersion
        ),
        ('Battery charge', '${status.batteryPercent}%'),
        ('Battery voltage', '${status.batteryMilliVolts} mV'),
        ('IMU state', status.imuStateString.toLowerCase()),
        ('Requested IMU sample rate', '${status.requestedRate} Hz'),
        ('Device-reported IMU sample rate', '${status.actualSensorRate} Hz'),
        ('IMU BLE notification rate', '${status.notificationRate} packets/s'),
        (
          'ADC BLE notification rate',
          adcNotificationRate == null
              ? 'Unavailable on this firmware'
              : '$adcNotificationRate packets/s',
        ),
        ('Uptime', '${(status.uptimeMs / 1000).toStringAsFixed(1)} s'),
        ('ATT MTU', '${status.attMtu} bytes'),
        ('Dropped notifications', '${status.droppedNotifications}'),
        (
          'Discarded sensor samples',
          status.version == 3
              ? '${status.bufferDroppedSamples}'
              : 'Unavailable',
        ),
        if (status.version == 2)
          ('Combined FIFO and I2C errors', '${status.fifoRecoveries}')
        else ...[
          ('FIFO recoveries', '${status.fifoRecoveries}'),
          ('I2C errors', '${status.i2cErrors}'),
        ],
      ],
    ];
  }
}
