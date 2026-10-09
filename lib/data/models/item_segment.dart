/// Item Segments — schema/061_wyzesales_item_segments.sql.
///
/// `ItemSegmentCell` is one row of `fn_item_segments_summary` (one per
/// lifecycle segment x ABC class that has at least one item, plus a single
/// 'dormant' row with class '-'). `ItemSegmentItem` is one row of
/// `fn_item_segment_items`, `ItemConcentration` the single row of
/// `fn_item_concentration`. `kItemSegDefs` is the app-side half of the segment
/// definition: the database only returns a short `segment_key` ('growing',
/// 'stopped', ...), and this list gives each key its display name, colour,
/// one-line meaning and what the forecast does with it. Renaming or
/// recolouring a segment is a change here only.
library;

import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

class ItemSegmentTop {
  final String code;
  final String name;
  final num value;
  final int customers;
  final String lastMonth;

  const ItemSegmentTop({
    required this.code,
    required this.name,
    required this.value,
    required this.customers,
    required this.lastMonth,
  });

  factory ItemSegmentTop.fromMap(Map<String, dynamic> map) {
    final code = (map['code'] as String?) ?? '';
    final rawName = (map['name'] as String?)?.trim();
    return ItemSegmentTop(
      code: code,
      name: (rawName == null || rawName.isEmpty) ? code : rawName,
      value: (map['value'] as num?) ?? 0,
      customers: ((map['customers'] as num?) ?? 0).toInt(),
      lastMonth: (map['last_month'] as String?) ?? '',
    );
  }
}

class ItemSegmentCell {
  /// 'new', 'growing', 'steady', 'declining', 'occasional', 'stopped' or 'dormant'.
  final String segmentKey;

  /// 'A', 'B' or 'C'; '-' for dormant items (they have no class).
  final String abc;
  final int items;

  /// Sales over the last 12 closed months (0 for dormant).
  final num totalValue;

  /// What dormant items sold in the 12 months before the last 12 (0 otherwise).
  final num priorValue;
  final List<ItemSegmentTop> top;

  const ItemSegmentCell({
    required this.segmentKey,
    required this.abc,
    required this.items,
    required this.totalValue,
    required this.priorValue,
    required this.top,
  });

  String get cellKey => '$segmentKey|$abc';

  factory ItemSegmentCell.fromMap(Map<String, dynamic> map) {
    final topRaw = map['top_items'];
    return ItemSegmentCell(
      segmentKey: map['segment_key'] as String,
      abc: (map['abc'] as String?) ?? '-',
      items: ((map['items'] as num?) ?? 0).toInt(),
      totalValue: (map['total_value'] as num?) ?? 0,
      priorValue: (map['prior_value'] as num?) ?? 0,
      top: topRaw is List
          ? topRaw.map<ItemSegmentTop>((t) => ItemSegmentTop.fromMap(t as Map<String, dynamic>)).toList()
          : const [],
    );
  }
}

class ItemSegmentItem {
  final String code;
  final String name;
  final num value;
  final num priorValue;
  final int customers;
  final String firstMonth;
  final String lastMonth;

  const ItemSegmentItem({
    required this.code,
    required this.name,
    required this.value,
    required this.priorValue,
    required this.customers,
    required this.firstMonth,
    required this.lastMonth,
  });

  factory ItemSegmentItem.fromMap(Map<String, dynamic> map) {
    final code = (map['item_code'] as String?) ?? '';
    final rawName = (map['item_name'] as String?)?.trim();
    return ItemSegmentItem(
      code: code,
      name: (rawName == null || rawName.isEmpty) ? code : rawName,
      value: (map['value'] as num?) ?? 0,
      priorValue: (map['prior_value'] as num?) ?? 0,
      customers: ((map['customers'] as num?) ?? 0).toInt(),
      firstMonth: (map['first_month'] as String?) ?? '',
      lastMonth: (map['last_month'] as String?) ?? '',
    );
  }
}

class ItemConcentrationTop {
  final String code;
  final String name;
  final num value;
  final int customers;
  final int topSharePct;

  const ItemConcentrationTop({
    required this.code,
    required this.name,
    required this.value,
    required this.customers,
    required this.topSharePct,
  });

  factory ItemConcentrationTop.fromMap(Map<String, dynamic> map) {
    final code = (map['code'] as String?) ?? '';
    final rawName = (map['name'] as String?)?.trim();
    return ItemConcentrationTop(
      code: code,
      name: (rawName == null || rawName.isEmpty) ? code : rawName,
      value: (map['value'] as num?) ?? 0,
      customers: ((map['customers'] as num?) ?? 0).toInt(),
      topSharePct: ((map['top_share'] as num?) ?? 0).toInt(),
    );
  }
}

/// A and B items that depend on one or two customers (or where one customer is
/// 60% or more of the item).
class ItemConcentration {
  final int abItems;
  final int riskyItems;
  final int riskyAItems;
  final num riskyAValue;
  final List<ItemConcentrationTop> top;

  const ItemConcentration({
    required this.abItems,
    required this.riskyItems,
    required this.riskyAItems,
    required this.riskyAValue,
    required this.top,
  });

  static const empty = ItemConcentration(abItems: 0, riskyItems: 0, riskyAItems: 0, riskyAValue: 0, top: []);

  factory ItemConcentration.fromMap(Map<String, dynamic> map) {
    final topRaw = map['top_items'];
    return ItemConcentration(
      abItems: ((map['ab_items'] as num?) ?? 0).toInt(),
      riskyItems: ((map['risky_items'] as num?) ?? 0).toInt(),
      riskyAItems: ((map['risky_a_items'] as num?) ?? 0).toInt(),
      riskyAValue: (map['risky_a_value'] as num?) ?? 0,
      top: topRaw is List
          ? topRaw.map<ItemConcentrationTop>((t) => ItemConcentrationTop.fromMap(t as Map<String, dynamic>)).toList()
          : const [],
    );
  }
}

/// Display definition for one lifecycle segment (a column of the chart).
class ItemSegDef {
  final String key;
  final String name;
  final Color color;

  /// Text colour that stays readable on `color`.
  final Color onColor;
  final String description;

  /// What the nightly Seasonal Forecast does with items in this segment.
  final String forecastNote;

  const ItemSegDef({
    required this.key,
    required this.name,
    required this.color,
    required this.onColor,
    required this.description,
    required this.forecastNote,
  });
}

const Color _darkText = Color(0xFF0B0B0B);

/// Chart columns, left to right. The colours are the app's own status colours
/// plus one teal (Steady); each name and number is on the tile, so colour is
/// never the only cue.
const List<ItemSegDef> kItemSegDefs = [
  ItemSegDef(
    key: 'new',
    name: 'New',
    color: AppColors.info,
    onColor: Colors.white,
    description: 'First sold in the last 12 months. Not enough history to judge a trend yet.',
    forecastNote:
        'The forecast uses the average of the months it has been selling, held flat for 12 months, and marks it low confidence.',
  ),
  ItemSegDef(
    key: 'growing',
    name: 'Growing',
    color: AppColors.positive,
    onColor: _darkText,
    description: 'Sold more in the last 12 months than the 12 before, by more than 15%.',
    forecastNote:
        'The forecast follows the seasonal pattern with the upward trend, eased back so a good year is not projected forever.',
  ),
  ItemSegDef(
    key: 'steady',
    name: 'Steady',
    color: Color(0xFF0891B2),
    onColor: Colors.white,
    description: 'Selling at about the same level as a year ago (within 15%).',
    forecastNote:
        'The forecast follows the seasonal pattern at the current level. These are the items the forecast is most reliable for.',
  ),
  ItemSegDef(
    key: 'declining',
    name: 'Declining',
    color: AppColors.caution,
    onColor: _darkText,
    description: 'Selling at least 15% less than the 12 months before. Still active, but shrinking.',
    forecastNote: 'The forecast follows the seasonal pattern with the downward trend, eased back.',
  ),
  ItemSegDef(
    key: 'occasional',
    name: 'Occasional',
    color: AppColors.accentPurple,
    onColor: Colors.white,
    description: 'Sold in 5 of the last 12 months or fewer. Lumpy, order-driven or seasonal items.',
    forecastNote:
        'The forecast is the flat average of the last 12 months, because a seasonal pattern cannot be learned from so few sales.',
  ),
  ItemSegDef(
    key: 'stopped',
    name: 'Stopped',
    color: AppColors.negative,
    onColor: Colors.white,
    description:
        'Sold in the last 12 months but nothing for the last 4 months. Discontinued, out of stock or lost.',
    forecastNote:
        'The forecast fades to zero. Check the A and B items here: if they should still be selling, this is where to look first.',
  ),
];

ItemSegDef? itemSegDefFor(String key) {
  for (final d in kItemSegDefs) {
    if (d.key == key) return d;
  }
  return null;
}

const String kItemDormantKey = 'dormant';
const String kItemDormantNote =
    'No sales for 12 months or more. Kept so you can see what has dropped away, but left out of the chart and the percentages. The forecast is zero.';
