import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

/// Shared brand mark — the "Signal Spark" icon (a hex badge with a
/// heartbeat-style pulse line through it) plus a two-tone "Wyze"/"Sales"
/// wordmark, mirroring the split-colour treatment SeaWyze uses for its own
/// name ("Sea" navy + "Wyze" teal). Used on both the Login screen and the
/// sidebar so the two places that show branding stay in sync automatically.
///
/// 2026-08-27 — replaces the original placeholder (an outlined circle around
/// a reused `Icons.show_chart`, flagged from the start as "to be designed
/// later" per Wyzesales_Rebuild_Decisions.md Section 6). Craig reviewed 4
/// code-built concepts (an "Ascending W" bar mark, a "Growth Ring" arrow,
/// a "Wyze Aperture" eye/trend-line, and this "Signal Spark" hex+pulse) plus
/// a gold-ring variant of the W, and picked this one: "a hex badge — the
/// visual language of a trusted, actively-monitored data platform — with a
/// pulse line reading as 'live analytics.'" The one trade-off flagged and
/// accepted: unlike the W-based concepts, this mark doesn't reference
/// "Wyze"/"Sales" on its own — it's meant to be read together with the
/// wordmark it's always paired with here, not standalone.
///
/// Drawn with a `CustomPainter` (`_SignalSparkPainter` below) rather than an
/// icon font glyph or an imported SVG/image asset — plain `Path` fills and
/// strokes over a 72x72 design grid, scaled to whatever `iconSize` is
/// requested, so it stays crisp at both the small sidebar mark and a
/// favicon-sized rendering with no bundled asset file to keep in sync.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.iconSize = 40, this.fontSize = 26, this.onDark = false});

  /// Width/height of the icon mark.
  final double iconSize;

  /// Font size of the "Wyze"/"Sales" wordmark text.
  final double fontSize;

  /// True when rendering against the dark navy sidebar — swaps the "Wyze"
  /// half of the wordmark from navy to white so it stays legible, and swaps
  /// the icon's hex badge from a solid navy fill to a white outline for the
  /// same reason (see _SignalSparkPainter's doc comment). The gold pulse
  /// line and the "Sales" half of the wordmark stay gold either way, since
  /// gold already reads fine against both the light background and navy
  /// elsewhere in this theme.
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: iconSize,
          height: iconSize,
          child: CustomPaint(
            painter: _SignalSparkPainter(
              onDark: onDark,
              hexColor: onDark ? Colors.white : AppColors.lightText,
              pulseColor: AppColors.teal,
            ),
          ),
        ),
        SizedBox(width: iconSize * 0.28),
        RichText(
          text: TextSpan(
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, height: 1),
            children: [
              TextSpan(text: 'Wyze', style: TextStyle(color: onDark ? Colors.white : AppColors.lightText)),
              const TextSpan(text: 'Sales', style: TextStyle(color: AppColors.teal)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Draws the "Signal Spark" mark: a hexagon badge (solid-filled on light
/// grounds, outline-only on dark — a filled hex would read as a flat navy
/// blob against the already-dark sidebar) with a 6-point pulse/heartbeat
/// line through its middle in the brand gold.
///
/// Coordinates are lifted directly from the concept board's 0-72 SVG design
/// grid and scaled by `size.width / 72` — same numbers Craig actually
/// reviewed and picked, not a re-interpretation of them in Flutter's own
/// coordinate system.
class _SignalSparkPainter extends CustomPainter {
  const _SignalSparkPainter({required this.onDark, required this.hexColor, required this.pulseColor});

  final bool onDark;
  final Color hexColor;
  final Color pulseColor;

  static const List<Offset> _hexPoints = [
    Offset(36, 5),
    Offset(64, 20),
    Offset(64, 52),
    Offset(36, 67),
    Offset(8, 52),
    Offset(8, 20),
  ];

  static const List<Offset> _pulsePoints = [
    Offset(16, 42),
    Offset(27, 42),
    Offset(32, 30),
    Offset(40, 48),
    Offset(45, 38),
    Offset(56, 38),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 72;

    final hexPath = Path()..addPolygon(_hexPoints.map((p) => p * scale).toList(), true);
    final hexPaint = Paint()..color = hexColor;
    if (onDark) {
      hexPaint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4 * scale;
    } else {
      hexPaint.style = PaintingStyle.fill;
    }
    canvas.drawPath(hexPath, hexPaint);

    final scaledPulse = _pulsePoints.map((p) => p * scale).toList();
    final pulsePath = Path()..moveTo(scaledPulse.first.dx, scaledPulse.first.dy);
    for (final point in scaledPulse.skip(1)) {
      pulsePath.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      pulsePath,
      Paint()
        ..color = pulseColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.5 * scale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SignalSparkPainter oldDelegate) =>
      onDark != oldDelegate.onDark || hexColor != oldDelegate.hexColor || pulseColor != oldDelegate.pulseColor;
}
