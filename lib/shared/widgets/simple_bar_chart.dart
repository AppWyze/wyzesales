import 'package:flutter/material.dart';
import '../../core/utils/formatters.dart';

class BarChartEntry {
  final String label;
  final num value;
  const BarChartEntry({required this.label, required this.value});
}

/// A deliberately simple, dependency-free horizontal bar chart — used for
/// the Dashboard's "Top 5" cards and anywhere else a quick ranked comparison
/// is needed. No charting package (e.g. fl_chart) is used here: this was
/// built in a sandbox with no way to verify a third-party charting package's
/// API compiles, so this trades visual polish for something guaranteed to
/// render correctly. Worth revisiting once the project can be built for
/// real — see the design notes.
///
/// Track colour fixed 2026-08-26: this used to read `Theme.of(context)
/// .dividerColor` for the bar's background track, which is a *different*
/// property from the `dividerTheme` this app actually configures in
/// app_theme.dart — `ThemeData.dividerColor` falls back to Flutter's own
/// Material default (a flat black at low opacity) whenever it isn't set
/// directly on `ThemeData`, which it never was here. That's the "black bar"
/// Craig flagged on the Dashboard. Switched to the same theme-derived
/// neutral tint app_shell.dart's top-bar chips already use, so it reads as
/// a soft neutral in both light and dark mode instead of literal black.
class SimpleBarChart extends StatelessWidget {
  const SimpleBarChart({super.key, required this.entries, this.currency = true});

  final List<BarChartEntry> entries;
  final bool currency;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Padding(padding: EdgeInsets.all(16), child: Text('No data.'));
    }
    final maxValue = entries.map((e) => e.value.abs()).fold<num>(0, (a, b) => a > b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: entries.map((entry) {
        final fraction = maxValue == 0 ? 0.0 : (entry.value.abs() / maxValue).toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 96,
                child: Text(entry.label, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
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
                      widthFactor: fraction.clamp(0.02, 1.0),
                      child: Container(
                        height: 18,
                        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 90,
                child: Text(
                  currency ? formatRand(entry.value) : formatQuantity(entry.value),
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
