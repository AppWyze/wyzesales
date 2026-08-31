import 'package:flutter/material.dart';

/// A single KPI tile — label, big value, optional tinted icon badge,
/// optional subtitle. Mirrors the stat-card row pattern from SeaWyze's
/// Dashboard (Overdue work orders / Work orders due soon / ...), restyled
/// here around real WyzeSales figures (sales/GP totals) rather than copying
/// SeaWyze's work-order concepts, which don't have an equivalent in this
/// app.
///
/// `icon` made optional 2026-08-27 — Craig: "Please remove the icons from
/// the dashboard Sales mtd, Ytd, Gp mtd and ytd," a plain cosmetic
/// simplification of the 4 Dashboard KPI tiles, not a request to drop the
/// badge capability outright (nothing else in the app currently uses this
/// widget with an icon, but there's no reason to force every future call
/// site to supply one it might not want).
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.subtitle,
  });

  final IconData? icon;
  final String label;
  final String value;
  final Color color;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon == null)
              Text(label, style: textTheme.bodyMedium, overflow: TextOverflow.ellipsis)
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(label, style: textTheme.bodyMedium, overflow: TextOverflow.ellipsis)),
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
                    child: Icon(icon, color: color, size: 18),
                  ),
                ],
              ),
            const SizedBox(height: 10),
            Text(
              value,
              // headlineMedium deliberately, not headlineSmall — headlineSmall
              // was shrunk to match SeaWyze's smaller page-title/heading
              // scale (2026-08-21), but a KPI tile's own number is meant to
              // stay bold and prominent regardless, same as SeaWyze's.
              style: textTheme.headlineMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(subtitle!, style: textTheme.bodySmall, overflow: TextOverflow.ellipsis),
            ],
          ],
        ),
      ),
    );
  }
}
