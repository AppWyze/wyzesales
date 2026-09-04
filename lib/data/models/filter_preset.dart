import '../../core/constants/fiscal.dart';
import '../../core/filters/global_filters.dart';

/// One row of `filter_presets` (schema/035, 2026-09-04) — a named snapshot
/// of the 5 dimension global filters (Sales Person/Category/Customer/Item/
/// Branch) a user can save once and reapply later from the global filter
/// bar. Deliberately does NOT capture Year, Month, or Document — Craig's own
/// choice (AskUserQuestion): a preset is "my view of the data," so Year/
/// Month stay live/current every time it's reapplied rather than a specific
/// past period getting frozen into it. Private to the user who created it —
/// schema/035's RLS never lets this list include anyone else's presets, so
/// there's no "owner name" field here to show; every preset this app ever
/// loads already belongs to the signed-in user.
class FilterPreset {
  final String id;
  final String name;
  final FilterSelection? salesPerson;
  final FilterSelection? category;
  final FilterSelection? customer;
  final FilterSelection? item;
  final FilterSelection? branch;

  const FilterPreset({
    required this.id,
    required this.name,
    this.salesPerson,
    this.category,
    this.customer,
    this.item,
    this.branch,
  });

  /// True if applying this preset wouldn't actually set anything — shouldn't
  /// be reachable in practice (the save dialog requires at least one
  /// dimension picked before it lets you save), but guards the picker/apply
  /// path from silently doing nothing if a preset ever ends up empty.
  bool get isEmpty => salesPerson == null && category == null && customer == null && item == null && branch == null;

  /// Mirrors `GlobalFilters.forDimension` — lets the "apply this preset"
  /// code (global_filter_bar.dart) loop over `SalesDimension.filterable` and
  /// call `GlobalFiltersNotifier.setDimension(dimension, preset.forDimension
  /// (dimension))` for each, which both sets the dimensions the preset has
  /// and clears the ones it doesn't (a `null` here is a real "not part of
  /// this preset," not a missing value) — so applying a preset always
  /// replaces the current 5 dimension filters wholesale rather than merging
  /// with whatever was set before.
  FilterSelection? forDimension(SalesDimension dimension) {
    switch (dimension) {
      case SalesDimension.salesPerson:
        return salesPerson;
      case SalesDimension.category:
        return category;
      case SalesDimension.customer:
        return customer;
      case SalesDimension.item:
        return item;
      case SalesDimension.branch:
        return branch;
      case SalesDimension.company:
        return null;
    }
  }

  factory FilterPreset.fromMap(Map<String, dynamic> row) {
    FilterSelection? selection(String codeKey, String labelKey) {
      final code = row[codeKey] as String?;
      if (code == null) return null;
      return FilterSelection(code, (row[labelKey] as String?) ?? code);
    }

    return FilterPreset(
      id: row['id'] as String,
      name: row['name'] as String,
      salesPerson: selection('sales_person_code', 'sales_person_label'),
      category: selection('category_code', 'category_label'),
      customer: selection('customer_code', 'customer_label'),
      item: selection('item_code', 'item_label'),
      branch: selection('branch_code', 'branch_label'),
    );
  }
}
