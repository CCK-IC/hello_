import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/frequency_history.dart';

enum FrequencySeries { percussion, vibration }

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

  static const colors = <FrequencySeries, Color>{
    FrequencySeries.percussion: Color(0xFFC62828),
    FrequencySeries.vibration: Color(0xFF1565C0),
  };

  @override
  Widget build(BuildContext context) {
    final end = now ?? DateTime.now();
    final start = end.subtract(visiblePeriod);
    final points = history
        .where((p) => !p.timestamp.isBefore(start) && !p.timestamp.isAfter(end))
        .toList();
    if (selected.isEmpty) {
      return const SizedBox(
          height: 240,
          child: Center(child: Text('Select a frequency band to display.')));
    }
    if (!points.any(
        (point) => selected.any((series) => _value(point, series) != null))) {
      return const SizedBox(
          height: 240,
          child: Center(child: Text('Waiting for frequency estimates...')));
    }
    return SizedBox(
      height: 240,
      width: double.infinity,
      child: CustomPaint(
        painter: _FrequencyPainter(
            points: points,
            selected: selected,
            start: start,
            end: end,
            axisColor: Theme.of(context).colorScheme.onSurface),
      ),
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
  _FrequencyPainter(
      {required this.points,
      required this.selected,
      required this.start,
      required this.end,
      required this.axisColor});

  final List<FrequencyHistoryPoint> points;
  final Set<FrequencySeries> selected;
  final DateTime start;
  final DateTime end;
  final Color axisColor;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 46.0, right = 8.0, top = 12.0, bottom = 26.0;
    final plot = Rect.fromLTRB(left, top, math.max(left, size.width - right),
        math.max(top, size.height - bottom));
    final grid = Paint()
      ..color = axisColor.withAlpha(45)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }
    var maximum = 0.0;
    for (final point in points) {
      for (final series in selected) {
        final value = _value(point, series);
        if (value != null) maximum = math.max(maximum, value);
      }
    }
    maximum = maximum <= 0 ? 1 : maximum * 1.1;
    final elapsed =
        math.max(1, end.difference(start).inMicroseconds).toDouble();
    Offset position(FrequencyHistoryPoint point, double value) => Offset(
          plot.left +
              (point.timestamp.difference(start).inMicroseconds / elapsed)
                      .clamp(0.0, 1.0) *
                  plot.width,
          plot.bottom - value / maximum * plot.height,
        );

    canvas.save();
    canvas.clipRect(plot);
    for (final series in selected) {
      final paint = Paint()
        ..color = FrequencyHistoryChart.colors[series]!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..isAntiAlias = true;
      for (final segment in frequencyPlotSegments(points, series)) {
        final path = Path();
        var first = true;
        for (final point in segment) {
          final pos = position(point, _value(point, series)!);
          if (first) {
            path.moveTo(pos.dx, pos.dy);
            first = false;
          } else {
            path.lineTo(pos.dx, pos.dy);
          }
          canvas.drawCircle(pos, 1.7, Paint()..color = paint.color);
        }
        canvas.drawPath(path, paint);
      }
    }
    canvas.restore();
    _label(
        canvas, '${maximum.toStringAsFixed(1)} Hz', const Offset(2, top - 6));
    _label(canvas, '0 Hz', Offset(2, plot.bottom - 7));
    _label(canvas, '-${end.difference(start).inSeconds}s',
        Offset(plot.left, plot.bottom + 7));
    _label(canvas, 'now', Offset(plot.right - 22, plot.bottom + 7));
  }

  void _label(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
        text: TextSpan(
            text: text,
            style: TextStyle(color: axisColor.withAlpha(180), fontSize: 10)),
        textDirection: TextDirection.ltr)
      ..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _FrequencyPainter oldDelegate) => true;
}
