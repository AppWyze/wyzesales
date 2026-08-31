import 'package:flutter/material.dart';

/// A colour-tinted shortcut tile — mirrors SeaWyze's "Quick actions" row
/// (Create work order / Log maintenance / ...), repurposed here as
/// navigation shortcuts to WyzeSales' own screens rather than data-entry
/// actions, since WyzeSales doesn't have equivalent one-tap actions (nothing
/// here is "logged" in a single tap the way SeaWyze's work orders/hours are).
///
/// Restyled again 2026-08-26 ("make the quick action tiles resemble
/// seawyze") to match SeaWyze's `_QuickActionBtn` exactly rather than just
/// approximately: a coloured border (the actual mismatch — the previous
/// pass had the tinted fill and icon badge but no border, so tiles read as
/// slightly flatter/plainer than SeaWyze's own), and a dark/light-aware
/// fill opacity (SeaWyze uses a stronger tint in dark mode, 0.12 vs 0.07,
/// since the same alpha reads lighter against a dark background).
class QuickActionTile extends StatelessWidget {
  const QuickActionTile({super.key, required this.icon, required this.label, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: color.withValues(alpha: isDark ? 0.12 : 0.07),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(9)),
                child: Icon(icon, color: color, size: 19),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: onSurface, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
