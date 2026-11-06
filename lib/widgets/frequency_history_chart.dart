import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/frequency_history.dart';

enum FrequencySeries {
  percussion('Percussion band', Icons.circle),
  vibration('Vibration band', Icons.square);

  const FrequencySeries(this.label, this.marker);

  final String label;
  final IconData marker;

  Color color(ColorScheme scheme) => switch (this) {
        percussion => scheme.primary,
        vibration => scheme.tertiary,
      };
}

/// A rolling plot of candidate peaks. Missing estimates remain visible as gaps.
class FrequencyHistoryChart extends StatelessWidget {
  const FrequencyHistoryChart({
    super.key,
    required this.history,
    required this.visiblePeriod,
    required this.selected,
    this.now,
  });

  final List<FrequencyHistoryPoint> history;
  final Duration visiblePeriod;
  final Set<FrequencySeries> selected;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    if (selected.isEmpty) {
      return const _ChartMessage('Select a frequency band to display.');
    }
    final end = now ?? DateTime.now();
    final start = end.subtract(visiblePeriod);
    final points = history
        .where((p) => !p.timestamp.isBefore(start) && !p.timestamp.isAfter(end))
        .toList();
    final segments = {
      for (final series in FrequencySeries.values)
        if (selected.contains(series))
          series: frequencyPlotSegments(points, series),
    };
    if (segments.values.every((segments) => segments.isEmpty)) {
      return const _ChartMessage('Waiting for frequency estimates...');
    }

    var maximum = 0.0;
    final latest = <String>[];
    for (final entry in segments.entries) {
      final series = entry.key;
      if (entry.value.isEmpty) {
        latest.add('${series.label} has no estimate in this window.');
        continue;
      }
      for (final segment in entry.value) {
        for (final point in segment) {
          maximum = math.max(maximum, _value(point, series)!);
        }
      }
      final point = entry.value.last.last;
      final peak = _value(point, series)!.toStringAsFixed(2);
      final age = end.difference(point.timestamp).inSeconds;
      final when = switch (age) {
        0 => 'now',
        1 => '1 second ago',
        _ => '$age seconds ago',
      };
      latest.add(
          'The latest plotted peak for ${series.label} was $peak Hz, $when.');
    }
    maximum = maximum <= 0 ? 1 : maximum * 1.1;
    final maximumLabel = '${maximum.toStringAsFixed(1)} Hz';
    final duration = visiblePeriod.inSeconds;
    final timeSpan = duration == 1 ? '1 second' : '$duration seconds';
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      image: true,
      label: 'Frequency history over the last $timeSpan. '
          'The frequency axis runs from 0 Hz to $maximumLabel. '
          '${latest.join(' ')} '
          'Gaps mark missing estimates or changes in sensor or band settings.',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: _chartDecoration(scheme),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: DefaultTextStyle(
            style: theme.textTheme.bodySmall!.copyWith(color: scheme.onSurface),
            child: LayoutBuilder(builder: (context, constraints) {
              // The time axis always runs from oldest to newest, left to right.
              return Column(
                textDirection: TextDirection.ltr,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(maximumLabel),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: (constraints.maxWidth * 0.4).clamp(144.0, 260.0),
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _FrequencyPainter(
                        segments: segments,
                        period: visiblePeriod,
                        start: start,
                        maximum: maximum,
                        scheme: scheme,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text('0 Hz'),
                  Row(
                    textDirection: TextDirection.ltr,
                    children: [
                      Expanded(child: Text('-${duration}s')),
                      const Expanded(
                          child: Text('now', textAlign: TextAlign.right)),
                    ],
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }
}

BoxDecoration _chartDecoration(ColorScheme scheme) => BoxDecoration(
      color: scheme.surfaceContainerLowest,
      border: Border.all(color: scheme.outlineVariant),
      borderRadius: BorderRadius.circular(12),
    );

class _ChartMessage extends StatelessWidget {
  const _ChartMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 144),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      decoration: _chartDecoration(scheme),
      child: Text(message, textAlign: TextAlign.center),
    );
  }
}

double? _value(FrequencyHistoryPoint point, FrequencySeries series) {
  final index = series.index;
  if (point.analysis.error != null || point.analysis.bands.length <= index) {
    return null;
  }
  final value = point.analysis.bands[index].peakHz;
  return value != null && value.isFinite ? value : null;
}

bool _sameConfiguration(
    FrequencyHistoryPoint a, FrequencyHistoryPoint b, FrequencySeries series) {
  if (a.sensor != b.sensor ||
      a.analysis.bands.length <= series.index ||
      b.analysis.bands.length <= series.index) {
    return false;
  }
  final first = a.analysis.bands[series.index].band;
  final second = b.analysis.bands[series.index].band;
  return first.minHz == second.minHz && first.maxHz == second.maxHz;
}

/// Separates discontinuities so a missing estimate or new configuration is not
/// presented as an uninterrupted measurement.
List<List<FrequencyHistoryPoint>> frequencyPlotSegments(
    List<FrequencyHistoryPoint> points, FrequencySeries series) {
  final segments = <List<FrequencyHistoryPoint>>[];
  FrequencyHistoryPoint? previous;
  for (final point in points) {
    if (_value(point, series) == null) {
      previous = null;
      continue;
    }
    if (previous == null ||
        point.timestamp.difference(previous.timestamp) >
            const Duration(seconds: 2) ||
        !_sameConfiguration(previous, point, series)) {
      segments.add([]);
    }
    segments.last.add(point);
    previous = point;
  }
  return segments;
}

class _FrequencyPainter extends CustomPainter {
  _FrequencyPainter({
    required this.segments,
    required this.period,
    required this.start,
    required this.maximum,
    required this.scheme,
  });

  final Map<FrequencySeries, List<List<FrequencyHistoryPoint>>> segments;
  final Duration period;
  final DateTime start;
  final double maximum;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = (Offset.zero & size).deflate(4);
    if (plot.isEmpty) return;
    final grid = Paint()..color = scheme.outlineVariant;
    final axis = Paint()..color = scheme.outline;
    for (var i = 0; i < 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }
    canvas.drawLine(plot.topLeft, plot.bottomLeft, axis);
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axis);

    final elapsed = math.max(1, period.inMicroseconds);
    Offset position(FrequencyHistoryPoint point, double value) => Offset(
          plot.left +
              (point.timestamp.difference(start).inMicroseconds / elapsed)
                      .clamp(0.0, 1.0) *
                  plot.width,
          plot.bottom - (value / maximum).clamp(0.0, 1.0) * plot.height,
        );

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final entry in segments.entries) {
      final series = entry.key;
      final marker = Paint()..color = series.color(scheme);
      final line = Paint()
        ..color = marker.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round;
      for (final segment in entry.value) {
        final positions = [
          for (final point in segment) position(point, _value(point, series)!),
        ];
        if (positions.length > 1) {
          canvas.drawPath(Path()..addPolygon(positions, false), line);
        }
        for (final pos in positions) {
          if (series == FrequencySeries.percussion) {
            canvas.drawCircle(pos, 3, marker);
          } else {
            canvas.drawRect(
                Rect.fromCenter(center: pos, width: 5, height: 5), marker);
          }
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FrequencyPainter oldDelegate) => true;
}
