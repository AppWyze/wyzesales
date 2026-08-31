import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';

class ActualVsTargetGroup {
  final String label;
  final num actual;
  final num target;
  const ActualVsTargetGroup({required this.label, required this.actual, required this.target});
}

/// A small, dependency-free grouped bar chart — one Actual/Target bar pair
/// per group (the Dashboard uses this for MTD and YTD). Same "no
/// third-party charting package" reasoning as SimpleBarChart/
/// TrendLineChart: this sandbox has no way to verify a charting package's
/// API actually compiles, so plain `Container`s are used instead, trading
/// visual polish for something guaranteed to render.
///
/// 2026-08-27: rewritten from grouped vertical columns to horizontal bar
/// rows, matching SimpleBarChart's label/track/fill/value Row shape — Craig:
/// "make the bar charts on the Dashboard horizontal." The grey Target bar
/// was also flagged in the same request ("replace grey colour with the
/// blue colour"): Target now uses AppColors.info (the palette's actual
/// blue — see fiscal.dart/app_theme.dart for the note that AppColors.teal is
/// itself mislabeled amber/gold, not the source of this change, just a
/// naming quirk to be aware of elsewhere). No legend is needed any more —
/// unlike the old side-by-side columns, each row already carries its own
/// "Actual"/"Target" label the way every SimpleBarChart row carries its own
/// entity label. A Column, not a ListView — a fixed, small number of rows
/// that comfortably fits the existing SizedBox(height: 240) Card on the
/// Dashboard without needing to scroll.
///
/// **% achieved badge** (2026-08-27, Craig: "insert a % achieved on
/// dashboard Actual Revenue vs Sales Target chart") — a small pill next to
/// each group's own label (MTD/YTD), computed straight from that group's
/// own actual/target (not the two bars' pixel widths, which are drawn
/// relative to the shared cross-group `maxValue` and would give the wrong
/// number for whichever group isn't the largest). Green at/above 100%
/// (target met or beaten), amber below — same "positive vs caution" colour
/// pairing used for over/under performance everywhere else in this app.
/// Shows "—" rather than a division-by-zero/Infinity when a group's target
/// is zero (no budget entered for that period yet).
class ActualVsTargetChart extends StatelessWidget {
  const ActualVsTargetChart({super.key, required this.groups});

  final List<ActualVsTargetGroup> groups;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return const Padding(padding: EdgeInsets.all(16), child: Text('No data.'));
    }
    num maxValue = 0;
    for (final g in groups) {
      if (g.actual.abs() > maxValue) maxValue = g.actual.abs();
      if (g.target.abs() > maxValue) maxValue = g.target.abs();
    }

    const actualColor = AppColors.teal;
    const targetColor = AppColors.info;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < groups.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            Row(
              children: [
                Text(groups[i].label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                _AchievedBadge(actual: groups[i].actual, target: groups[i].target),
              ],
            ),
            const SizedBox(height: 4),
            _BarRow(
              label: 'Actual',
              value: groups[i].actual,
              fraction: maxValue == 0 ? 0 : groups[i].actual.abs() / maxValue,
              color: actualColor,
            ),
            _BarRow(
              label: 'Target',
              value: groups[i].target,
              fraction: maxValue == 0 ? 0 : groups[i].target.abs() / maxValue,
              color: targetColor,
            ),
          ],
        ],
      ),
    );
  }
}

/// "XX.X% achieved" pill next to a group's label — see
/// [ActualVsTargetChart]'s own doc comment for the colour/zero-target
/// reasoning.
class _AchievedBadge extends StatelessWidget {
  const _AchievedBadge({required this.actual, required this.target});

  final num actual;
  final num target;

  @override
  Widget build(BuildContext context) {
    final percent = target == 0 ? null : (actual / target) * 100;
    final label = percent == null ? '— achieved' : '${formatPercent(percent)} achieved';
    final color = (percent ?? 0) >= 100 ? AppColors.positive : AppColors.caution;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({required this.label, required this.value, required this.fraction, required this.color});

  final String label;
  final num value;

  /// 0.0-1.0 of the shared chart max, converted to an actual pixel width via
  /// the surrounding Expanded/FractionallySizedBox rather than a fixed
  /// number, so this scales correctly whatever width the card around it
  /// ends up with — same approach SimpleBarChart already uses.
  final num fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(label, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  height: 18,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: fraction.clamp(0.02, 1.0).toDouble(),
                  child: Container(
                    height: 18,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: Text(formatRand(value), textAlign: TextAlign.right, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
