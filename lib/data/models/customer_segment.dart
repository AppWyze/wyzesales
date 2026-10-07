/// Customer Segments (RFM) — schema/060_wyzesales_customer_segments.sql.
///
/// `CustomerSegmentSummary` is one row of `fn_customer_segments_summary` (one
/// per segment that has at least one customer), `CustomerSegmentCustomer` one
/// row of `fn_customer_segment_customers`. `kSegmentDefs` is the app-side half
/// of the segment definition: the database only returns a short `segment_key`
/// ('champ', 'loyal', ...), and this list gives each key its display name,
/// colour family, one-line meaning, and position on the 5 x 5 grid. Renaming a
/// segment or recolouring it is a change here only — nothing in the database
/// knows the display names.
library;

import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

class CustomerSegmentTop {
  final String code;
  final String name;
  final num value;
  const CustomerSegmentTop({required this.code, required this.name, required this.value});

  factory CustomerSegmentTop.fromMap(Map<String, dynamic> map) {
    final code = (map['code'] as String?) ?? '';
    final rawName = (map['name'] as String?)?.trim();
    return CustomerSegmentTop(
      code: code,
      name: (rawName == null || rawName.isEmpty) ? code : rawName,
      value: (map['value'] as num?) ?? 0,
    );
  }
}

class CustomerSegmentSummary {
  final String segmentKey;
  final int customers;
  final num totalValue;
  final num avgValue;
  final int recMin;
  final int recMax;
  final int freqMin;
  final int freqMax;
  final num valueMin;
  final num valueMax;
  final List<CustomerSegmentTop> top;

  const CustomerSegmentSummary({
    required this.segmentKey,
    required this.customers,
    required this.totalValue,
    required this.avgValue,
    required this.recMin,
    required this.recMax,
    required this.freqMin,
    required this.freqMax,
    required this.valueMin,
    required this.valueMax,
    required this.top,
  });

  factory CustomerSegmentSummary.fromMap(Map<String, dynamic> map) {
    final topRaw = map['top_customers'];
    return CustomerSegmentSummary(
      segmentKey: map['segment_key'] as String,
      customers: (map['customers'] as num).toInt(),
      totalValue: (map['total_value'] as num?) ?? 0,
      avgValue: (map['avg_value'] as num?) ?? 0,
      recMin: ((map['rec_min'] as num?) ?? 0).toInt(),
      recMax: ((map['rec_max'] as num?) ?? 0).toInt(),
      freqMin: ((map['freq_min'] as num?) ?? 0).toInt(),
      freqMax: ((map['freq_max'] as num?) ?? 0).toInt(),
      valueMin: (map['value_min'] as num?) ?? 0,
      valueMax: (map['value_max'] as num?) ?? 0,
      top: topRaw is List
          ? topRaw.map<CustomerSegmentTop>((t) => CustomerSegmentTop.fromMap(t as Map<String, dynamic>)).toList()
          : const [],
    );
  }
}

class CustomerSegmentCustomer {
  final String code;
  final String name;
  final int recDays;
  final int frequency;
  final num monetary;

  const CustomerSegmentCustomer({
    required this.code,
    required this.name,
    required this.recDays,
    required this.frequency,
    required this.monetary,
  });

  factory CustomerSegmentCustomer.fromMap(Map<String, dynamic> map) {
    final code = (map['account_code'] as String?) ?? '';
    final rawName = (map['customer_name'] as String?)?.trim();
    return CustomerSegmentCustomer(
      code: code,
      name: (rawName == null || rawName.isEmpty) ? code : rawName,
      recDays: ((map['rec_days'] as num?) ?? 0).toInt(),
      frequency: ((map['frequency'] as num?) ?? 0).toInt(),
      monetary: (map['monetary'] as num?) ?? 0,
    );
  }
}

/// The five colour families the tiles are drawn in (the app's own status
/// colours, see AppColors). A tile's colour says how healthy the relationship
/// is; its name and numbers carry the identity, so colour is never the only cue.
enum SegmentFamily {
  best('Best', AppColors.positive, Color(0xFF0B0B0B)),
  growing('Growing', AppColors.info, Colors.white),
  cooling('Cooling', AppColors.caution, Color(0xFF0B0B0B)),
  atRisk('At risk', AppColors.negative, Colors.white),
  dormant('Dormant', AppColors.accentPurple, Colors.white);

  const SegmentFamily(this.label, this.color, this.onColor);
  final String label;
  final Color color;

  /// Text colour that stays readable on `color`.
  final Color onColor;
}

/// One segment's display definition and its rectangle on the 5 x 5 grid.
/// `col`/`row` are 0-based from the top-left; row 0 is the highest
/// Frequency + Monetary band, column 4 is the most recent. `colSpan`/`rowSpan`
/// are in grid cells.
class SegmentDef {
  final String key;
  final String name;
  final SegmentFamily family;
  final String description;
  final int col;
  final int row;
  final int colSpan;
  final int rowSpan;

  const SegmentDef({
    required this.key,
    required this.name,
    required this.family,
    required this.description,
    required this.col,
    required this.row,
    required this.colSpan,
    required this.rowSpan,
  });
}

const List<SegmentDef> kSegmentDefs = [
  SegmentDef(
    key: 'cant',
    name: 'Win back now',
    family: SegmentFamily.atRisk,
    description:
        'Your biggest historic spenders and most frequent buyers, silent for months. Highest priority to win back.',
    col: 0, row: 0, colSpan: 1, rowSpan: 1,
  ),
  SegmentDef(
    key: 'loyal',
    name: 'Loyal regulars',
    family: SegmentFamily.best,
    description:
        'Buy regularly and spend well, though not in the last few weeks. Keep them engaged and nudge them to buy more.',
    col: 1, row: 0, colSpan: 3, rowSpan: 2,
  ),
  SegmentDef(
    key: 'champ',
    name: 'Best customers',
    family: SegmentFamily.best,
    description: 'Bought in the last few weeks, buy often and spend the most. Protect and thank them.',
    col: 4, row: 0, colSpan: 1, rowSpan: 2,
  ),
  SegmentDef(
    key: 'risk',
    name: 'Slipping away',
    family: SegmentFamily.atRisk,
    description: 'Used to spend well but have not bought for many months. Contact them now.',
    col: 0, row: 1, colSpan: 1, rowSpan: 2,
  ),
  SegmentDef(
    key: 'sleep',
    name: 'Cooling off',
    family: SegmentFamily.cooling,
    description: 'Mid-level buyers who have not ordered for a while. A reminder or an offer may wake them up.',
    col: 1, row: 2, colSpan: 2, rowSpan: 1,
  ),
  SegmentDef(
    key: 'pot',
    name: 'Rising',
    family: SegmentFamily.growing,
    description: 'Recent buyers with moderate spend. The best chance of becoming loyal regulars.',
    col: 3, row: 2, colSpan: 2, rowSpan: 2,
  ),
  SegmentDef(
    key: 'hib',
    name: 'Dormant',
    family: SegmentFamily.dormant,
    description: 'Small buyers, not seen for a long time. Low-cost reactivation only.',
    col: 0, row: 3, colSpan: 1, rowSpan: 2,
  ),
  SegmentDef(
    key: 'attn',
    name: 'Fading',
    family: SegmentFamily.cooling,
    description: 'Small buyers who are going quiet. Check in before they drift further.',
    col: 1, row: 3, colSpan: 2, rowSpan: 2,
  ),
  SegmentDef(
    key: 'prom',
    name: 'Warming up',
    family: SegmentFamily.growing,
    description: 'Bought recently but only a little. Worth encouraging a second and third order.',
    col: 3, row: 4, colSpan: 1, rowSpan: 1,
  ),
  SegmentDef(
    key: 'recent',
    name: 'New or returning',
    family: SegmentFamily.growing,
    description: 'Very recent and small so far. Often new customers: make the first experience a good one.',
    col: 4, row: 4, colSpan: 1, rowSpan: 1,
  ),
];

SegmentDef? segmentDefFor(String key) {
  for (final d in kSegmentDefs) {
    if (d.key == key) return d;
  }
  return null;
}
