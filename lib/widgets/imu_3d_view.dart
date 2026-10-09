import 'dart:math' as math;
import 'package:flutter/material.dart';

class Imu3dView extends StatelessWidget {
  final double q0, q1, q2, q3; // w, x, y, z

  const Imu3dView({
    super.key,
    required this.q0,
    required this.q1,
    required this.q2,
    required this.q3,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, double.infinity),
      painter: _Imu3dPainter(q0: q0, q1: q1, q2: q2, q3: q3),
    );
  }
}

class _Imu3dPainter extends CustomPainter {
  final double q0, q1, q2, q3;

  _Imu3dPainter({
    required this.q0,
    required this.q1,
    required this.q2,
    required this.q3,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale = math.min(size.width, size.height) * 0.35;

    // Normalize quaternion
    final norm = math.sqrt(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3);
    final w = norm > 0 ? q0 / norm : 1.0;
    final x = norm > 0 ? q1 / norm : 0.0;
    final y = norm > 0 ? q2 / norm : 0.0;
    final z = norm > 0 ? q3 / norm : 0.0;

    // Rotation Matrix
    final r00 = 1 - 2 * (y * y + z * z);
    final r01 = 2 * (x * y - w * z);
    final r02 = 2 * (x * z + w * y);

    final r10 = 2 * (x * y + w * z);
    final r11 = 1 - 2 * (x * x + z * z);
    final r12 = 2 * (y * z - w * x);

    final r20 = 2 * (x * z - w * y);
    final r21 = 2 * (y * z + w * x);
    final r22 = 1 - 2 * (x * x + y * y);

    Offset project(double px, double py, double pz) {
      // Rotate
      final rx = r00 * px + r01 * py + r02 * pz;
      final ry = r10 * px + r11 * py + r12 * pz;
      final rz = r20 * px + r21 * py + r22 * pz;

      // Weak perspective projection (camera along Z)
      const distance = 4.0;
      final pScale = scale / (distance - rz * 0.5);
      return Offset(center.dx + rx * pScale, center.dy - ry * pScale);
    }

    // Draw reference coordinate grid
    final gridPaint = Paint()
      ..color = Colors.blueGrey.withOpacity(0.15)
      ..strokeWidth = 1;
    canvas.drawCircle(center, scale * 0.9, gridPaint);

    // Cube vertices (Board dimensions)
    const dx = 1.0; // Length
    const dy = 0.6; // Width
    const dz = 0.15; // Height

    final vertices = [
      [-dx, -dy, -dz],
      [dx, -dy, -dz],
      [dx, dy, -dz],
      [-dx, dy, -dz],
      [-dx, -dy, dz],
      [dx, -dy, dz],
      [dx, dy, dz],
      [-dx, dy, dz],
    ];

    final projected = vertices.map((v) => project(v[0], v[1], v[2])).toList();

    // Define 6 Faces
    final faces = [
      [0, 1, 2, 3, Colors.blueGrey.shade800], // Bottom
      [4, 5, 6, 7, Colors.cyan.shade600],     // Top (Sensor face)
      [0, 1, 5, 4, Colors.blue.shade700],     // Front
      [2, 3, 7, 6, Colors.indigo.shade700],   // Back
      [0, 3, 7, 4, Colors.teal.shade700],     // Left
      [1, 2, 6, 5, Colors.blueGrey.shade600], // Right
    ];

    for (final face in faces) {
      final path = Path()
        ..moveTo(projected[face[0] as int].dx, projected[face[0] as int].dy)
        ..lineTo(projected[face[1] as int].dx, projected[face[1] as int].dy)
        ..lineTo(projected[face[2] as int].dx, projected[face[2] as int].dy)
        ..lineTo(projected[face[3] as int].dx, projected[face[3] as int].dy)
        ..close();

      canvas.drawPath(
        path,
        Paint()
          ..color = (face[4] as Color).withOpacity(0.85)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white24
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }

    // Draw Body Coordinate Axes (X: Red, Y: Green, Z: Blue)
    void drawAxis(double ax, double ay, double az, Color color) {
      final pEnd = project(ax * 1.5, ay * 1.5, az * 1.5);
      canvas.drawLine(
        center,
        pEnd,
        Paint()
          ..color = color
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    drawAxis(1.0, 0.0, 0.0, Colors.redAccent);   // X
    drawAxis(0.0, 1.0, 0.0, Colors.greenAccent); // Y
    drawAxis(0.0, 0.0, 1.0, Colors.blueAccent);  // Z
  }

  @override
  bool shouldRepaint(covariant _Imu3dPainter oldDelegate) {
    return oldDelegate.q0 != q0 ||
        oldDelegate.q1 != q1 ||
        oldDelegate.q2 != q2 ||
        oldDelegate.q3 != q3;
  }
}