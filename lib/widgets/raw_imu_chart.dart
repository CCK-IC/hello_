import "dart:math" as math;

import "package:flutter/material.dart";

import "../models/raw_imu_history.dart";

class RawImuChart extends StatelessWidget {
  final List<RawImuHistoryPoint> history;
  final RawSensorType sensor;
  final Duration visiblePeriod;

  const RawImuChart({
    super.key,
    required this.history,
    required this.sensor,
    required this.visiblePeriod,
  });

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final start = now.subtract(visiblePeriod);
    final points = history
        .where((point) => !point.receivedAt.isBefore(start))
        .where((point) => point.valuesFor(sensor) != null)
        .toList(growable: false);

    if (points.length < 2) {
      return const SizedBox(
        height: 240,
        child: Center(child: Text("Waiting for raw sensor data...")),
      );
    }

    return SizedBox(
      height: 240,
      width: double.infinity,
      child: CustomPaint(
        painter: _RawImuChartPainter(
          points: points,
          sensor: sensor,
          start: start,
          end: now,
          gridColor: Colors.white12,
        ),
      ),
    );
  }
}

class _RawImuChartPainter extends CustomPainter {
  final List<RawImuHistoryPoint> points;
  final RawSensorType sensor;
  final DateTime start;
  final DateTime end;
  final Color gridColor;

  const _RawImuChartPainter({
    required this.points,
    required this.sensor,
    required this.start,
    required this.end,
    required this.gridColor,
  });

  static const _axisColors = [
    Colors.redAccent,
    Colors.greenAccent,
    Colors.lightBlueAccent,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const left = 46.0;
    const right = 8.0;
    const top = 12.0;
    const bottom = 26.0;

    final plot = Rect.fromLTRB(
      left,
      top,
      math.max(left, size.width - right),
      math.max(top, size.height - bottom),
    );

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(
        Offset(plot.left, y),
        Offset(plot.right, y),
        gridPaint,
      );
    }

    var minimum = double.infinity;
    var maximum = double.negativeInfinity;

    for (final point in points) {
      final values = point.valuesFor(sensor)!;
      for (final value in values) {
        minimum = math.min(minimum, value);
        maximum = math.max(maximum, value);
      }
    }

    if (minimum == maximum) {
      minimum -= 1;
      maximum += 1;
    } else {
      final padding = (maximum - minimum) * 0.1;
      minimum -= padding;
      maximum += padding;
    }

    final durationUs =
        math.max(1, end.difference(start).inMicroseconds).toDouble();

    double xFor(DateTime timestamp) {
      final elapsedUs = timestamp.difference(start).inMicroseconds;
      return plot.left +
          (elapsedUs / durationUs).clamp(0.0, 1.0) * plot.width;
    }

    double yFor(double value) {
      return plot.bottom -
          ((value - minimum) / (maximum - minimum)) * plot.height;
    }

    for (var axis = 0; axis < 3; axis++) {
      final path = Path();
      var started = false;

      for (final point in points) {
        final values = point.valuesFor(sensor);
        if (values == null) continue;

        final x = xFor(point.receivedAt);
        final y = yFor(values[axis]);

        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = _axisColors[axis]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..isAntiAlias = true,
      );
    }

    _drawText(
      canvas,
      maximum.toStringAsFixed(2),
      const Offset(2, top - 6),
    );
    _drawText(
      canvas,
      minimum.toStringAsFixed(2),
      Offset(2, plot.bottom - 7),
    );
    _drawText(
      canvas,
      "-${end.difference(start).inSeconds}s",
      Offset(plot.left, plot.bottom + 7),
    );
    _drawText(
      canvas,
      "now",
      Offset(plot.right - 22, plot.bottom + 7),
    );
  }

  void _drawText(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 10,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _RawImuChartPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.sensor != sensor ||
        oldDelegate.start != start ||
        oldDelegate.end != end;
  }
}