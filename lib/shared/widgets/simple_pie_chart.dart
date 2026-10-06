import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

/// One wedge — `rawValue` keeps its sign (matters for Gross Profit mode,
/// where a "Bottom 5"/"Diminishing 5" selection can genuinely include a
/// loss-making entity) even though the wedge itself is always sized by
/// magnitude; see the class doc below for why.
class PieSlice {
  final String label;
  final String entityCode;
  final num rawValue;

  /// Optional replacement for the default "R value · share" line under the
  /// name in the legend (and for the value in the hover row). Used by
  /// Diminishing 5 / Growth 5, where the wedge is the size of the CHANGE and
  /// the useful text is "was X, now Y" rather than a plain amount.
  final String? note;
  const PieSlice({required this.label, required this.entityCode, required this.rawValue, this.note});
}

/// A dependency-free donut chart — no third-party charting package, same
/// reasoning as SimpleBarChart/TrendLineChart (this sandbox has no way to
/// verify a package like fl_chart actually compiles; a real Flutter SDK
/// only exists on Craig's machine).
///
/// Wedge sizing uses each slice's *magnitude* (`rawValue.abs()`) as a share
/// of the total magnitude shown, not the signed value — a pie's areas only
/// mean something as parts of a positive whole, and a mix of positive and
/// negative signed values (e.g. Gross Profit's "Bottom 5", which can
/// legitimately include a loss-making customer) has no sane "part of a
/// whole" interpretation if summed with their signs. A negative slice is
/// still sized honestly (by how big its loss is) and coloured red
/// (AppColors.negative) regardless of its position in the palette, so it
/// reads as "this one is actually a loss" rather than blending in as just
/// another positive contributor. Documented here since this is a real
/// simplification, not a hidden one — worth Craig's awareness.
///
/// Interaction: hovering a wedge (desktop) shows its detail in a fixed row
/// above the chart — deliberately not a floating tooltip, matching
/// TrendLineChart's own precedent, since overlay positioning isn't
/// something this sandbox can visually verify. Tapping a wedge (or its
/// legend entry) both selects it and, if `onSliceTap` is set, drills down —
/// there's no separate "hover" gesture on touch, so a tap has to do both
/// jobs there the way most mobile pie charts do.
class SimplePieChart extends StatefulWidget {
  const SimplePieChart({
    super.key,
    required this.slices,
    required this.valueFormatter,
    this.onSliceTap,
    this.totalLabel,
    this.emptyMessage = 'No data for the current filters.',
  });

  final List<PieSlice> slices;
  final String Function(num) valueFormatter;
  final ValueChanged<PieSlice>? onSliceTap;

  /// Small caption under the donut's centre total (e.g. "MTD" / "YTD").
  final String? totalLabel;
  final String emptyMessage;

  @override
  State<SimplePieChart> createState() => _SimplePieChartState();
}

class _SimplePieChartState extends State<SimplePieChart> {
  int? _hoverIndex;

  // 2026-10-06: AppColors.teal and AppColors.caution are both amber, so two
  // wedges/legend dots were near-identical (Craig's Bottom 5 / Diminishing 5
  // screenshots). The 3rd and 5th colours are now clearly different hues.
  static const List<Color> _palette = [
    AppColors.info,
    AppColors.positive,
    AppColors.caution,
    AppColors.accentPurple,
    Color(0xFF06B6D4),
  ];

  Color _colorFor(int index, PieSlice slice) {
    if (slice.rawValue < 0) return AppColors.negative;
    return _palette[index % _palette.length];
  }

  List<_SliceGeometry> get _geometry => _computeGeometry(widget.slices);

  void _updateHover(Offset local, Size size) {
    final index = _hitTest(local, size, _geometry);
    if (index != _hoverIndex) setState(() => _hoverIndex = index);
  }

  void _handleTap(Offset local, Size size) {
    final index = _hitTest(local, size, _geometry);
    if (index == null) return;
    setState(() => _hoverIndex = index);
    widget.onSliceTap?.call(widget.slices[index]);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.slices.isEmpty) {
      return Center(child: Text(widget.emptyMessage, style: Theme.of(context).textTheme.bodyMedium));
    }
    final totalAbs = widget.slices.fold<num>(0, (a, s) => a + s.rawValue.abs());
    final hovered = _hoverIndex != null ? widget.slices[_hoverIndex!] : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Fixed-height detail row so hovering never reflows the layout —
        // same fixed-row-not-floating-tooltip approach as TrendLineChart.
        SizedBox(
          height: 20,
          child: hovered == null
              ? Text(
                  'Hover a segment for detail, click to drill down.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                )
              : Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '${hovered.label}: ', style: const TextStyle(fontWeight: FontWeight.w700)),
                      TextSpan(text: hovered.note ?? widget.valueFormatter(hovered.rawValue)),
                      if (totalAbs > 0 && hovered.note == null)
                        TextSpan(
                          text: '  (${(hovered.rawValue.abs() / totalAbs * 100).toStringAsFixed(0)}% of shown)',
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                        ),
                    ],
                  ),
                  style: Theme.of(context).textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 5,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final size = Size(constraints.maxWidth, constraints.maxHeight);
                    return MouseRegion(
                      onHover: (event) => _updateHover(event.localPosition, size),
                      onExit: (_) => setState(() => _hoverIndex = null),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) => _handleTap(details.localPosition, size),
                        child: CustomPaint(
                          size: size,
                          painter: _PieChartPainter(
                            geometry: _geometry,
                            colors: [for (var i = 0; i < widget.slices.length; i++) _colorFor(i, widget.slices[i])],
                            hoverIndex: _hoverIndex,
                            centerText: widget.valueFormatter(totalAbs),
                            centerLabel: widget.totalLabel,
                            textColor: Theme.of(context).colorScheme.onSurface,
                            holeColor: Theme.of(context).cardTheme.color ?? Theme.of(context).colorScheme.surface,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: widget.slices.length,
                  itemBuilder: (context, index) {
                    final slice = widget.slices[index];
                    final color = _colorFor(index, slice);
                    final isHovered = index == _hoverIndex;
                    return InkWell(
                      onTap: () {
                        setState(() => _hoverIndex = index);
                        widget.onSliceTap?.call(slice);
                      },
                      // Deliberately no onHover here — highlighting a legend
                      // row by hovering it (separately from hovering its
                      // wedge) invites the two hover sources fighting over
                      // _hoverIndex on fast mouse movement. The legend still
                      // reflects whichever wedge is hovered (isHovered
                      // below); it just isn't a second way to *set* it.
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                        child: Row(
                          children: [
                            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                            const SizedBox(width: 6),
                            // Name on top, its real value and share underneath
                            // (2026-10-06): a wedge can be too small to see (or
                            // R 0), so the legend now states every entry's actual
                            // figure instead of leaving it to be read off the ring.
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    slice.label,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: isHovered ? FontWeight.w700 : FontWeight.w500,
                                    ),
                                  ),
                                  Text(
                                    slice.note ??
                                        (totalAbs > 0
                                            ? '${widget.valueFormatter(slice.rawValue)}  ·  ${(slice.rawValue.abs() / totalAbs * 100).toStringAsFixed(1)}%'
                                            : widget.valueFormatter(slice.rawValue)),
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SliceGeometry {
  /// Both in radians, in a "12 o'clock = 0, increasing clockwise" frame —
  /// converted to Canvas's own "3 o'clock = 0" frame at paint/hit-test time
  /// (see the -pi/2 shifts below), so this list itself never needs to
  /// handle wraparound past 2*pi.
  final double startAngle;
  final double sweepAngle;
  const _SliceGeometry(this.startAngle, this.sweepAngle);
}

List<_SliceGeometry> _computeGeometry(List<PieSlice> slices) {
  final totalAbs = slices.fold<double>(0, (a, s) => a + s.rawValue.abs().toDouble());
  final result = <_SliceGeometry>[];
  if (totalAbs <= 0) {
    for (var i = 0; i < slices.length; i++) {
      result.add(const _SliceGeometry(0, 0));
    }
    return result;
  }
  // Every non-zero slice gets at least `minShare` of the ring so it stays
  // visible (2026-10-06, Craig: Bottom 5 / Diminishing 5 showed 3 wedges for
  // 5 legend entries, or one solid ring, because the other entries were far
  // smaller than the biggest and rounded to under a pixel). The wedge sizes
  // are therefore a readability compromise for tiny slices only; the legend
  // and hover text always carry the true value and percentage.
  const minShare = 0.04;
  var shares = [for (final s in slices) s.rawValue.abs().toDouble() / totalAbs];
  final tiny = <int>{
    for (var i = 0; i < shares.length; i++)
      if (shares[i] > 0 && shares[i] < minShare) i,
  };
  if (tiny.isNotEmpty) {
    final reserved = tiny.length * minShare;
    var bigTotal = 0.0;
    for (var i = 0; i < shares.length; i++) {
      if (!tiny.contains(i)) bigTotal += shares[i];
    }
    shares = [
      for (var i = 0; i < shares.length; i++)
        tiny.contains(i) ? minShare : (bigTotal > 0 ? shares[i] / bigTotal * (1 - reserved) : 0.0),
    ];
  }
  var cursor = 0.0;
  for (final share in shares) {
    final sweep = share * 2 * math.pi;
    result.add(_SliceGeometry(cursor, sweep));
    cursor += sweep;
  }
  return result;
}

int? _hitTest(Offset local, Size size, List<_SliceGeometry> geometry) {
  final side = math.min(size.width, size.height);
  if (side <= 0) return null;
  final outerRadius = side / 2;
  final innerRadius = outerRadius * 0.55; // donut hole — matches the painter
  final center = Offset(size.width / 2, size.height / 2);
  final dx = local.dx - center.dx;
  final dy = local.dy - center.dy;
  final distance = math.sqrt(dx * dx + dy * dy);
  if (distance > outerRadius || distance < innerRadius) return null;

  final rawAngle = math.atan2(dy, dx); // Canvas frame: 0 = 3 o'clock, clockwise positive
  var cursorAngle = rawAngle + math.pi / 2; // shift into the geometry's 12-o'clock-start frame
  if (cursorAngle < 0) cursorAngle += 2 * math.pi;
  if (cursorAngle >= 2 * math.pi) cursorAngle -= 2 * math.pi;

  for (var i = 0; i < geometry.length; i++) {
    final g = geometry[i];
    if (g.sweepAngle <= 0) continue;
    if (cursorAngle >= g.startAngle && cursorAngle < g.startAngle + g.sweepAngle) return i;
  }
  return null;
}

class _PieChartPainter extends CustomPainter {
  const _PieChartPainter({
    required this.geometry,
    required this.colors,
    required this.hoverIndex,
    required this.centerText,
    required this.centerLabel,
    required this.textColor,
    required this.holeColor,
  });

  final List<_SliceGeometry> geometry;
  final List<Color> colors;
  final int? hoverIndex;
  final String centerText;
  final String? centerLabel;
  final Color textColor;
  final Color holeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    if (side <= 0) return;
    final outerRadius = side / 2;
    final innerRadius = outerRadius * 0.55;
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: outerRadius);

    for (var i = 0; i < geometry.length; i++) {
      final g = geometry[i];
      if (g.sweepAngle <= 0) continue;
      final isHovered = i == hoverIndex;
      // Hovered wedge pops out slightly along its own bisector, rather than
      // just changing colour — visible even for a viewer who can't easily
      // tell two similar hues apart.
      final bisector = g.startAngle + g.sweepAngle / 2 - math.pi / 2;
      final popOffset = isHovered ? Offset(math.cos(bisector), math.sin(bisector)) * 4 : Offset.zero;
      final wedgeRect = rect.shift(popOffset);
      final paint = Paint()
        ..color = colors[i].withValues(alpha: hoverIndex == null || isHovered ? 1.0 : 0.55)
        ..style = PaintingStyle.fill;
      canvas.drawArc(wedgeRect, g.startAngle - math.pi / 2, g.sweepAngle, true, paint);
    }

    // Donut hole, painted over the wedges' inner portion — background
    // colour, not a transparent cutout, since CustomPaint has no
    // guaranteed-transparent backdrop to punch through to. Matches the
    // surrounding Card's own fill (cardTheme.color) so it reads as a clean
    // punch-through rather than a mismatched patch.
    final holePaint = Paint()..color = holeColor;
    canvas.drawCircle(center, innerRadius, holePaint);

    final textPainter = TextPainter(textDirection: TextDirection.ltr, textAlign: TextAlign.center);
    textPainter.text = TextSpan(
      text: centerText,
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: textColor),
    );
    textPainter.layout(maxWidth: innerRadius * 1.8);
    textPainter.paint(canvas, center - Offset(textPainter.width / 2, textPainter.height + (centerLabel == null ? -textPainter.height / 2 : 1)));

    if (centerLabel != null) {
      final labelPainter = TextPainter(textDirection: TextDirection.ltr, textAlign: TextAlign.center);
      labelPainter.text = TextSpan(
        text: centerLabel,
        style: TextStyle(fontSize: 10, color: textColor.withValues(alpha: 0.6)),
      );
      labelPainter.layout(maxWidth: innerRadius * 1.8);
      labelPainter.paint(canvas, center + Offset(-labelPainter.width / 2, 2));
    }
  }

  @override
  bool shouldRepaint(covariant _PieChartPainter oldDelegate) {
    return oldDelegate.geometry != geometry || oldDelegate.hoverIndex != hoverIndex || oldDelegate.centerText != centerText;
  }
}
