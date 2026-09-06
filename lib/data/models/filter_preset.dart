import '../../core/filters/global_filters.dart';

/// One row of `filter_presets` (schema/035, 2026-09-04; generalized by
/// schema/045, 2026-09-06) — a named snapshot of whatever dimension filters
/// were active on `GlobalFilterBar` when it was saved. Deliberately does NOT
/// capture Year, Month, or Document — Craig's own choice (AskUserQuestion): a
/// preset is "my view of the data," so Year/Month stay live/current every
/// time it's reapplied rather than a specific past period getting frozen
/// into it. Private to the user who created it — schema/035's RLS never
/// lets this list include anyone else's presets, so there's no "owner name"
/// field here to show; every preset this app ever loads already belongs to
/// the signed-in user.
///
/// 2026-09-06 (multi-tenant dimension model, Saved Filter Presets step):
/// rewritten from 5 fixed named fields (salesPerson/category/customer/item/
/// branch) to one `Map<String, FilterSelection>` keyed by dimension_key —
/// the same generalization `GlobalFilters` itself already went through in
/// Step 2, and for the identical reason: the old shape could never express a
/// preset for a dimension a client hasn't always had (a future EdgeTec
/// Market filter, say). `forKey` is the new, general accessor; there is
/// deliberately no `forDimension(SalesDimension)` bridge kept here — every
/// call site already had a raw dimension_key in hand once GlobalFilterBar's
/// own chip loop was generalized (Step 2), so there was nothing left needing
/// the old enum-typed accessor.
class FilterPreset {
  final String id;
  final String name;
  final Map<String, FilterSelection> dimensions;

  const FilterPreset({
    required this.id,
    required this.name,
    this.dimensions = const {},
  });

  /// True if applying this preset wouldn't actually set anything — shouldn't
  /// be reachable in practice (the save dialog requires at least one
  /// dimension picked before it lets you save), but guards the picker/apply
  /// path from silently doing nothing if a preset ever ends up empty.
  bool get isEmpty => dimensions.isEmpty;

  /// The selection this preset has for `dimensionKey`, or null when this
  /// preset doesn't touch that dimension at all — a null here is a real
  /// "not part of this preset," not a missing value, so applying a preset
  /// always replaces every filterable dimension wholesale (clearing the ones
  /// it doesn't mention) rather than merging with whatever was set before.
  /// See `_PresetsDialogState._apply` (global_filter_bar.dart) for the loop
  /// that relies on this.
  FilterSelection? forKey(String dimensionKey) => dimensions[dimensionKey];

  factory FilterPreset.fromMap(Map<String, dynamic> row) {
    final raw = (row['dimensions'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    return FilterPreset(
      id: row['id'] as String,
      name: row['name'] as String,
      dimensions: {
        for (final entry in raw.entries)
          entry.key: FilterSelection(
            (entry.value as Map)['code'] as String,
            ((entry.value as Map)['label'] as String?) ?? (entry.value as Map)['code'] as String,
          ),
      },
    );
  }
}
