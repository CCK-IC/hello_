import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/adc_history.dart';

/// Displays a bounded history of AUX readings. The parent rebuilds on updates.
class AdcChart extends StatefulWidget {
  final List<AdcHistoryPoint> history;
  final Duration visiblePeriod;
  const AdcChart(
      {super.key,
      required this.history,
      this.visiblePeriod = const Duration(seconds: 30)})
      : assert(visiblePeriod > Duration.zero);

  @override
  State<AdcChart> createState() => _AdcChartState();
}

class _AdcChartState extends State<AdcChart>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  static const _lightColors = [
    Color(0xFF9C322A),
    Color(0xFF276A38),
    Color(0xFF255C9B),
    Color(0xFF935016),
    Color(0xFF67429B),
    Color(0xFF006C69),
    Color(0xFF9D3268),
    Color(0xFF645614),
  ];
  static const _darkColors = [
    Color(0xFFFFB4AB),
    Color(0xFF9CDAA0),
    Color(0xFFA4C9FF),
    Color(0xFFFFB77F),
    Color(0xFFD5BBFF),
    Color(0xFF83D6D1),
    Color(0xFFFFB0D2),
    Color(0xFFD9C979),
  ];
  final selected = List<bool>.filled(8, true);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final now = DateTime.now();
    final start = now.subtract(widget.visiblePeriod);
    final points = widget.history
        .where(
            (p) => !p.receivedAt.isBefore(start) && !p.receivedAt.isAfter(now))
        .toList();
    final latest = widget.history.isEmpty ? null : widget.history.last.sample;
    final scheme = Theme.of(context).colorScheme;
    final colors =
        scheme.brightness == Brightness.dark ? _darkColors : _lightColors;
    final visibleChannels = [
      for (var i = 0; i < selected.length; i++)
        if (selected[i]) i + 1,
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        header: true,
        child: Text('ADC auxiliary · raw counts',
            style: Theme.of(context).textTheme.titleLarge),
      ),
      if (latest != null)
        Text(
            'Sequence ${latest.sequence} · device time ${latest.timestampMs} ms'),
      const SizedBox(height: 8),
      Wrap(
          spacing: 6,
          runSpacing: 4,
          children: List.generate(
              8,
              (i) => FilterChip(
                    label: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.circle, color: colors[i], size: 10),
                      const SizedBox(width: 6),
                      Flexible(
                          child: Text(
                              'CH${i + 1}: ${latest?.channels[i] ?? "—"}')),
                    ]),
                    selected: selected[i],
                    onSelected: (value) => setState(() => selected[i] = value),
                  ))),
      const SizedBox(height: 8),
      SizedBox(
          height: 220,
          width: double.infinity,
          child: visibleChannels.isEmpty
              ? const Center(
                  child: Text('Select a channel to show it on the chart.'))
              : points.isEmpty
                  ? const Center(
                      child: Text('Waiting for auxiliary ADC data...'))
                  : Semantics(
                      label:
                          'ADC chart, last ${widget.visiblePeriod.inSeconds} seconds. '
                          'Showing channels ${visibleChannels.join(', ')}.',
                      child: CustomPaint(
                        painter: _AdcPainter(points, List.of(selected), start,
                            now, scheme.onSurfaceVariant, colors),
                      ),
                    )),
    ]);
  }
}

class _AdcPainter extends CustomPainter {
  final List<AdcHistoryPoint> points;
  final List<bool> selected;
  final DateTime start, end;
  final Color foreground;
  final List<Color> colors;
  _AdcPainter(this.points, this.selected, this.start, this.end, this.foreground,
      this.colors);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 66 || size.height <= 30) return;
    final plot = Rect.fromLTRB(58, 8, size.width - 8, size.height - 24);
    var minValue = double.infinity, maxValue = double.negativeInfinity;
    for (final p in points) {
      for (var i = 0; i < 8; i++) {
        if (!selected[i]) continue;
        minValue = math.min(minValue, p.sample.channels[i].toDouble());
        maxValue = math.max(maxValue, p.sample.channels[i].toDouble());
      }
    }
    if (!minValue.isFinite) return;
    final pad = math.max(1.0, (maxValue - minValue) * 0.05);
    minValue -= pad;
    maxValue += pad;
    final grid = Paint()..color = foreground.withAlpha(46);
    void label(String text, Offset offset) {
      final painter = TextPainter(
          text: TextSpan(
              text: text, style: TextStyle(color: foreground, fontSize: 11)),
          textDirection: TextDirection.ltr)
        ..layout();
      painter.paint(canvas, offset);
      painter.dispose();
    }

    for (var i = 0; i <= 4; i++) {
      final y = plot.top + plot.height * i / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      label((maxValue - (maxValue - minValue) * i / 4).toStringAsFixed(0),
          Offset(0, y - 6));
    }
    label('-${end.difference(start).inSeconds}s',
        Offset(plot.left, plot.bottom + 5));
    label('now', Offset(plot.right - 20, plot.bottom + 5));
    canvas.save();
    canvas.clipRect(plot);
    final duration = end.difference(start).inMicroseconds;
    for (var channel = 0; channel < 8; channel++) {
      if (!selected[channel]) continue;
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final p = points[i];
        final x = plot.left +
            plot.width *
                p.receivedAt.difference(start).inMicroseconds /
                duration;
        final y = plot.bottom -
            plot.height *
                (p.sample.channels[channel] - minValue) /
                (maxValue - minValue);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        if (points.length == 1) {
          canvas.drawCircle(Offset(x, y), 2, Paint()..color = colors[channel]);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = colors[channel]
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AdcPainter oldDelegate) => true;
}
