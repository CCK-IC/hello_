import 'package:flutter/material.dart';

class EulerChart extends StatelessWidget {
  final List<double> rollHistory;
  final List<double> pitchHistory;
  final List<double> yawHistory;

  const EulerChart({
    super.key,
    required this.rollHistory,
    required this.pitchHistory,
    required this.yawHistory,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222D),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: const [
              _Legend(label: "Roll (X)", color: Colors.redAccent),
              _Legend(label: "Pitch (Y)", color: Colors.greenAccent),
              _Legend(label: "Yaw (Z)", color: Colors.blueAccent),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: CustomPaint(
              painter: _EulerChartPainter(
                rollHistory: rollHistory,
                pitchHistory: pitchHistory,
                yawHistory: yawHistory,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final String label;
  final Color color;
  const _Legend({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(width: 12, height: 4, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }
}

class _EulerChartPainter extends CustomPainter {
  final List<double> rollHistory;
  final List<double> pitchHistory;
  final List<double> yawHistory;

  _EulerChartPainter({
    required this.rollHistory,
    required this.pitchHistory,
    required this.yawHistory,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final midY = h / 2;

    // Draw 0-degree horizon and grid
    final gridPaint = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, midY), Offset(w, midY), gridPaint);
    canvas.drawLine(Offset(0, h * 0.25), Offset(w, h * 0.25), gridPaint);
    canvas.drawLine(Offset(0, h * 0.75), Offset(w, h * 0.75), gridPaint);

    void drawLine(List<double> values, Color color) {
      if (values.length < 2) return;
      final path = Path();
      final step = w / (values.length - 1);

      for (int i = 0; i < values.length; i++) {
        // Range is -180 deg to +180 deg
        final deg = values[i].clamp(-180.0, 180.0);
        final y = midY - (deg / 180.0) * (h / 2 * 0.9);
        final x = i * step;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }

    drawLine(rollHistory, Colors.redAccent);
    drawLine(pitchHistory, Colors.greenAccent);
    drawLine(yawHistory, Colors.blueAccent);
  }

  @override
  bool shouldRepaint(covariant _EulerChartPainter oldDelegate) => true;
}