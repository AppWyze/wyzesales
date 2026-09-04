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
    this.targetBars,
    this.targetShareBars,
    this.targetBasisBars,
    this.targetLabel,
    this.targetColor,
    this.targetTooltip,
  });

  final List<String> categories;
  final List<TrendSeries> series;

  /// Short form for gridline labels (e.g. "R1.2M") — axis space is tight.
  final String Function(num) axisValueFormatter;

  /// Full-precision form for the hover/tap detail row (e.g. "R 1 234 567").
  final String Function(num) detailValueFormatter;

  /// 2026-09-03, Craig — Sales Analysis's Graph tab: a light overlay bar per
  /// category showing Target, drawn behind the series lines. One entry per
  /// `categories` index, same as a `TrendSeries.values` list; `null` means
  /// no bar for that category (no target could be sourced or derived for
  /// it — see `core/utils/target_overlay.dart`), not a bar of height zero.
  /// Left null entirely to render no overlay at all (the chart's original,
  /// bars-free appearance).
  final List<num?>? targetBars;

  /// 2026-09-04: one entry per `categories` index, aligned to [targetBars]
  /// — the share (0.422 for "42.2%") actually applied to derive that
  /// month's bar, when it's a derived estimate rather than a real entered
  /// figure. Shown alongside the bar's own value in the hover/tap detail
  /// row (e.g. "Estimated Target (FY2027)  R675,974  (42.2% of Item:
  /// Multistage Vertical Pump)") so the reader doesn't have to
  /// reverse-engineer the percentage by hand. Leave null (or leave an
  /// individual entry null) to omit the share from that row entirely —
  /// a real, non-estimated target has no "share" to show.
  final List<double?>? targetShareBars;

  /// Paired with [targetShareBars]: which basis produced that month's
  /// figure (e.g. "Item: Multistage Vertical Pump" or "Company"). Shown
  /// together — a share with no basis label (or vice versa) is treated as
  /// "nothing to add," same as either being null.
  final List<String?>? targetBasisBars;

  /// Legend text for the overlay (e.g. "Target (FY2029)" or "Estimated
  /// Target (FY2029)" — see the caller for when each applies). Ignored if
  /// [targetBars] is null.
  final String? targetLabel;

  /// Fill colour for the overlay bars — should be a LIGHT/muted colour so
  /// the bars read as a backdrop, not competing with the bold series
  /// lines drawn on top of them. Defaults to a neutral light grey if
  /// omitted.
  final Color? targetColor;

  /// Optional explanatory text shown on long-press/hover of the legend
  /// entry — Craig, 2026-09-03: when the overlay is a derived estimate
  /// rather than a real entered target, that shouldn't be silently
  /// indistinguishable from one. Leave null for a real target, which needs
  /// no extra explanation.
  final String? targetTooltip;

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

  /// 2026-09-04 — see [targetShareBars]'s own doc comment. `index` is only
  /// ever called with `widget.targetBars![index] != null` already checked
  /// by the caller, so the value itself is always safe to read here.
  String _targetDetailText(int index) {
    final value = widget.targetBars![index]!;
    final base = '${widget.targetLabel}  ${widget.detailValueFormatter(value)}';
    final shareBars = widget.targetShareBars;
    final basisBars = widget.targetBasisBars;
    if (shareBars == null || basisBars == null || index >= shareBars.length || index >= basisBars.length) return base;
    final share = shareBars[index];
    final basis = basisBars[index];
    if (share == null || basis == null) return base;
    return '$base  (${(share * 100).toStringAsFixed(1)}% of $basis)';
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
                          // Target overlay's own value alongside the series
                          // values at the hovered point — same treatment as
                          // any other series here, just sourced from
                          // targetBars/targetLabel instead of a TrendSeries.
                          if (widget.targetBars != null &&
                              widget.targetLabel != null &&
                              activeIndex < widget.targetBars!.length &&
                              widget.targetBars![activeIndex] != null)
                            Text(
                              _targetDetailText(activeIndex),
                              style: textTheme.bodyMedium?.copyWith(
                                color: widget.targetColor ?? Colors.grey,
                                fontWeight: FontWeight.w600,
                              ),
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
                      targetBars: widget.targetBars,
                      targetColor: widget.targetColor ?? Colors.grey.withValues(alpha: 0.3),
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
            // A small rounded-rect swatch, not a circle like the line
            // series above — visually signals "this legend entry is a bar,
            // not a line" at a glance, matching how the overlay itself is
            // actually drawn. Wrapped in a Tooltip only when targetTooltip
            // is supplied (the derived-estimate case) — a real target needs
            // no extra explanation, so Tooltip(message: '') is avoided
            // entirely rather than shown as a no-op hover.
            if (widget.targetBars != null && widget.targetLabel != null)
              _buildTargetLegendEntry(textTheme),
          ],
        ),
      ],
    );
  }

  Widget _buildTargetLegendEntry(TextTheme textTheme) {
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: widget.targetColor ?? Colors.grey.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(widget.targetLabel!, style: textTheme.bodyMedium),
      ],
    );
    return widget.targetTooltip == null ? row : Tooltip(message: widget.targetTooltip!, child: row);
  }
}

class _TrendLinePainter extends CustomPainter {
  final List<String> categories;
  final List<TrendSeries> series;
  final int? hoverIndex;
  final Color gridColor;
  final Color axisTextColor;
  final String Function(num) axisValueFormatter;
  final List<num?>? targetBars;
  final Color targetColor;

  _TrendLinePainter({
    required this.categories,
    required this.series,
    required this.hoverIndex,
    required this.gridColor,
    required this.axisTextColor,
    required this.axisValueFormatter,
    this.targetBars,
    this.targetColor = Colors.grey,
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
    // Target bars count toward the scale too — a target notably above or
    // below the actual-revenue lines should still be visible in full,
    // rather than getting clipped against a range sized only for the
    // lines.
    for (final v in targetBars ?? const <num?>[]) {
      if (v == null) continue;
      final d = v.toDouble();
      if (d < minValue) minValue = d;
      if (d > maxValue) maxValue = d;
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

    // Target overlay bars (2026-09-03, Craig — Sales Analysis's Graph tab),
    // drawn after gridlines but before the series lines/markers, so the
    // bars read as a backdrop and the actual-revenue lines stay the
    // topmost, primary layer. Each bar spans from the zero line to its
    // target value — not from the padded chart bottom — so a chart whose
    // range dips negative (a month with more credit notes than invoices)
    // still draws the bar the intuitive way, rather than from whatever the
    // y-axis happens to be padded down to.
    final bars = targetBars;
    if (bars != null && categories.isNotEmpty) {
      final barPaint = Paint()..color = targetColor;
      final avgSpacing = categories.length > 1 ? plotWidth / (categories.length - 1) : plotWidth;
      final barWidth = (avgSpacing * 0.5).clamp(4.0, 40.0);
      final zeroY = yFor(0);
      for (var i = 0; i < categories.length; i++) {
        final value = i < bars.length ? bars[i] : null;
        if (value == null) continue;
        final x = xFor(i);
        final valueY = yFor(value);
        final top = valueY < zeroY ? valueY : zeroY;
        final bottom = valueY < zeroY ? zeroY : valueY;
        canvas.drawRect(Rect.fromLTRB(x - barWidth / 2, top, x + barWidth / 2, bottom), barPaint);
      }
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
        oldDelegate.categories != categories ||
        oldDelegate.targetBars != targetBars ||
        oldDelegate.targetColor != targetColor;
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
