import 'package:flutter/material.dart';

class TrendSeries {
  final String label;
  final Color color;

  /// One entry per category (e.g. fiscal month), aligned by index to the
  /// chart's `categories` list. `null` means "no data yet" (e.g. a month in
  /// the current, still-partial fiscal year) rather than zero — the line
  /// breaks across a gap instead of dropping to the axis.
  final List<num?> values;

  const TrendSeries({required this.label, required this.color, required this.values});
}

const double _leftMargin = 60;
const double _rightMargin = 12;
const double _topPadding = 12;
const double _bottomMargin = 26;

/// A small, dependency-free multi-line trend chart. Same reasoning as
/// SimpleBarChart (see that widget's own comment): no third-party charting
/// package, since this project has no way to verify one actually compiles
/// from this sandbox — a real Flutter SDK only exists on Craig's machine.
/// Built for Sales Analysis' Graph tab, which used to show a plain table
/// with a comment promising "a visual trend line is planned for a later
/// pass" (Craig asked for it directly, 2026-08-26).
///
/// Hover (desktop/web) or tap (touch) highlights the nearest category with a
/// vertical guide line and a detail row above the chart listing every
/// series' value for that point — deliberately simple rather than a
/// floating tooltip, which would need overlay positioning this sandbox has
/// no way to visually check.
class TrendLineChart extends StatefulWidget {
  const TrendLineChart({
    super.key,
    required this.categories,
    required this.series,
    required this.axisValueFormatter,
    required this.detailValueFormatter,
  });

  final List<String> categories;
  final List<TrendSeries> series;

  /// Short form for gridline labels (e.g. "R1.2M") — axis space is tight.
  final String Function(num) axisValueFormatter;

  /// Full-precision form for the hover/tap detail row (e.g. "R 1 234 567").
  final String Function(num) detailValueFormatter;

  @override
  State<TrendLineChart> createState() => _TrendLineChartState();
}

class _TrendLineChartState extends State<TrendLineChart> {
  int? _hoverIndex;

  void _updateHover(Offset localPosition, Size size) {
    if (widget.categories.isEmpty) return;
    final plotWidth = size.width - _leftMargin - _rightMargin;
    if (plotWidth <= 0) return;
    final relative = ((localPosition.dx - _leftMargin) / plotWidth).clamp(0.0, 1.0);
    final count = widget.categories.length;
    // Written as explicit comparisons rather than a second `.clamp()` call —
    // `num.clamp()` returns `num` even when called on an already-rounded
    // int, and this project has no live analyzer here to double-check an
    // implicit num->int downcast actually resolves the way intended.
    final rounded = count == 1 ? 0 : (relative * (count - 1)).round();
    final index = rounded < 0 ? 0 : (rounded > count - 1 ? count - 1 : rounded);
    if (index != _hoverIndex) setState(() => _hoverIndex = index);
  }

  int? _lastIndexWithData() {
    for (var i = widget.categories.length - 1; i >= 0; i--) {
      for (final s in widget.series) {
        if (i < s.values.length && s.values[i] != null) return i;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final activeIndex = _hoverIndex ?? _lastIndexWithData();
    final textTheme = Theme.of(context).textTheme;
    final gridColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    final axisTextColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 20,
          child: activeIndex == null
              ? null
              : Row(
                  children: [
                    Text('${widget.categories[activeIndex]}:  ', style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    Expanded(
                      child: Wrap(
                        spacing: 16,
                        children: [
                          for (final s in widget.series)
                            if (activeIndex < s.values.length && s.values[activeIndex] != null)
                              Text(
                                '${s.label}  ${widget.detailValueFormatter(s.values[activeIndex]!)}',
                                style: textTheme.bodyMedium?.copyWith(color: s.color, fontWeight: FontWeight.w600),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              return MouseRegion(
                onHover: (event) => _updateHover(event.localPosition, size),
                onExit: (_) => setState(() => _hoverIndex = null),
                child: GestureDetector(
                  onTapDown: (details) => _updateHover(details.localPosition, size),
                  onPanUpdate: (details) => _updateHover(details.localPosition, size),
                  child: CustomPaint(
                    size: size,
                    painter: _TrendLinePainter(
                      categories: widget.categories,
                      series: widget.series,
                      hoverIndex: _hoverIndex,
                      gridColor: gridColor,
                      axisTextColor: axisTextColor,
                      axisValueFormatter: widget.axisValueFormatter,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            for (final s in widget.series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text(s.label, style: textTheme.bodyMedium),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _TrendLinePainter extends CustomPainter {
  final List<String> categories;
  final List<TrendSeries> series;
  final int? hoverIndex;
  final Color gridColor;
  final Color axisTextColor;
  final String Function(num) axisValueFormatter;

  _TrendLinePainter({
    required this.categories,
    required this.series,
    required this.hoverIndex,
    required this.gridColor,
    required this.axisTextColor,
    required this.axisValueFormatter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const plotLeft = _leftMargin;
    const plotTop = _topPadding;
    final plotWidth = size.width - _leftMargin - _rightMargin;
    final plotHeight = size.height - _topPadding - _bottomMargin;
    if (plotWidth <= 0 || plotHeight <= 0 || categories.isEmpty) return;
    final plotBottom = plotTop + plotHeight;

    double minValue = 0;
    double maxValue = 0;
    for (final s in series) {
      for (final v in s.values) {
        if (v == null) continue;
        final d = v.toDouble();
        if (d < minValue) minValue = d;
        if (d > maxValue) maxValue = d;
      }
    }
    if (maxValue == minValue) maxValue = minValue + 1;
    final range = maxValue - minValue;
    final paddedMax = maxValue + range * 0.1;
    final paddedMin = minValue < 0 ? minValue - range * 0.1 : 0.0;
    final paddedRange = paddedMax - paddedMin == 0 ? 1.0 : paddedMax - paddedMin;

    double xFor(int index) {
      if (categories.length == 1) return plotLeft + plotWidth / 2;
      return plotLeft + plotWidth * index / (categories.length - 1);
    }

    double yFor(num value) {
      final t = (value.toDouble() - paddedMin) / paddedRange;
      return plotBottom - t * plotHeight;
    }

    // Gridlines + y-axis labels (5 evenly spaced levels).
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    const gridLevels = 4;
    for (var i = 0; i <= gridLevels; i++) {
      final value = paddedMin + paddedRange * i / gridLevels;
      final y = yFor(value);
      canvas.drawLine(Offset(plotLeft, y), Offset(plotLeft + plotWidth, y), gridPaint);
      final label = TextPainter(
        text: TextSpan(text: axisValueFormatter(value), style: TextStyle(color: axisTextColor, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: _leftMargin - 8);
      label.paint(canvas, Offset(plotLeft - 8 - label.width, y - label.height / 2));
    }

    // Hover guide line, drawn under the series lines so markers stay on top.
    if (hoverIndex != null) {
      final x = xFor(hoverIndex!);
      final guidePaint = Paint()
        ..color = axisTextColor.withValues(alpha: 0.4)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(x, plotTop), Offset(x, plotBottom), guidePaint);
    }

    // Series lines + markers, breaking the path across null (no-data) gaps.
    // Each contiguous run of points is drawn as a smooth Catmull-Rom curve
    // rather than straight lineTo segments — Craig, 2026-08-26: "Format
    // line chart to be rounded and not pointy." The curve still passes
    // exactly through every plotted value (only the joints between them are
    // rounded), so the hover markers below still land precisely on the
    // curve.
    for (final s in series) {
      final linePaint = Paint()
        ..color = s.color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      var run = <Offset>[];
      void flushRun() {
        _drawSmoothPath(canvas, run, linePaint);
        run = [];
      }

      for (var i = 0; i < categories.length; i++) {
        final value = i < s.values.length ? s.values[i] : null;
        if (value == null) {
          flushRun();
          continue;
        }
        run.add(Offset(xFor(i), yFor(value)));
      }
      flushRun();

      final markerPaint = Paint()..color = s.color;
      for (var i = 0; i < categories.length; i++) {
        final value = i < s.values.length ? s.values[i] : null;
        if (value == null) continue;
        final point = Offset(xFor(i), yFor(value));
        final isHovered = hoverIndex == i;
        canvas.drawCircle(point, isHovered ? 5 : 3, markerPaint);
        if (isHovered) {
          canvas.drawCircle(point, 5, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
        }
      }
    }

    // X-axis category labels.
    for (var i = 0; i < categories.length; i++) {
      final x = xFor(i);
      final label = TextPainter(
        text: TextSpan(text: categories[i], style: TextStyle(color: axisTextColor, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(x - label.width / 2, plotBottom + 8));
    }
  }

  @override
  bool shouldRepaint(covariant _TrendLinePainter oldDelegate) {
    return oldDelegate.hoverIndex != hoverIndex ||
        oldDelegate.series != series ||
        oldDelegate.categories != categories;
  }
}

/// Draws `points` as one smooth curve through every point — a Catmull-Rom
/// spline converted to cubic Bezier segments (the standard "cardinal spline"
/// construction, tension 1/6), rather than the straight `lineTo` chain this
/// replaced. Interior points use their two neighbours to shape each
/// segment's control points; the first/last point in a run reuse themselves
/// as their own missing neighbour, which is the usual boundary handling for
/// this construction and keeps the curve from overshooting at the ends of a
/// run. A run of 0-1 points has no line to draw (matches the old behaviour,
/// where a lone point produced only a `moveTo` and nothing visible).
void _drawSmoothPath(Canvas canvas, List<Offset> points, Paint paint) {
  if (points.length < 2) return;
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (var i = 0; i < points.length - 1; i++) {
    final p0 = i == 0 ? points[i] : points[i - 1];
    final p1 = points[i];
    final p2 = points[i + 1];
    final p3 = i + 2 < points.length ? points[i + 2] : points[i + 1];
    final control1 = Offset(p1.dx + (p2.dx - p0.dx) / 6, p1.dy + (p2.dy - p0.dy) / 6);
    final control2 = Offset(p2.dx - (p3.dx - p1.dx) / 6, p2.dy - (p3.dy - p1.dy) / 6);
    path.cubicTo(control1.dx, control1.dy, control2.dx, control2.dy, p2.dx, p2.dy);
  }
  canvas.drawPath(path, paint);
}
