import '../../core/constants/fiscal.dart';

/// One row of `client_dimensions` (schema/038, multi-tenant dimension model)
/// — the signed-in user's own CLIENT's configured set of Sales Analysis
/// dimensions. Read-only from the app's perspective for now — the
/// Platform-Admin configuration screen that writes these rows is design doc
/// Section 6 step 6, not yet built; Step 2 (GlobalFilters/filter bar rework)
/// only needs to READ this list, to render GlobalFilterBar's chips/"Add
/// filter" dropdown from whatever dimensions THIS client actually has
/// instead of the hardcoded `SalesDimension.filterable` every screen shared
/// before this existed.
class ClientDimensionConfig {
  final String dimensionKey;
  final String displayLabel;
  final int sortOrder;

  /// 'existing' | 'fact_column' | 'customer_attribute' — see
  /// client_dimensions' own column comment (schema/038) for what each means.
  final String resolutionKind;

  final String? parentDimensionKey;
  final bool drivesBudgets;

  /// Whether this dimension makes sense as a global filter TARGET or
  /// something to rank entities within — mirrors the OLD
  /// `SalesDimension.filterable` list exactly for WCSA (true for all 5 real
  /// dimensions, false for `company` — see schema/038's WCSA seed comment).
  /// GlobalFilterBar filters its chip/dropdown list to just the dimensions
  /// where this is true.
  final bool drivesCrossFilter;

  final bool isRlsScope;
  final bool showsOnDashboardTop5;

  const ClientDimensionConfig({
    required this.dimensionKey,
    required this.displayLabel,
    required this.sortOrder,
    required this.resolutionKind,
    this.parentDimensionKey,
    required this.drivesBudgets,
    required this.drivesCrossFilter,
    required this.isRlsScope,
    required this.showsOnDashboardTop5,
  });

  /// Bridges back to the OLD fixed `SalesDimension` enum — null for any
  /// 'fact_column'/'customer_attribute' dimension, since those have no
  /// `SalesDimension` value at all (they didn't exist before this migration).
  /// Every call site this Step 2 rework deliberately leaves alone (entity
  /// pickers, the RPC-backed repositories, Sales By/Performance/Budgets/
  /// Dashboard's own dimension switchers — design doc Section 6 steps 3/4)
  /// still only knows how to work with a `SalesDimension`, so this is what
  /// lets GlobalFilterBar's "Add filter" dropdown hand one of THOSE a value
  /// it understands for the dimensions that are still 'existing' (which, for
  /// WCSA today, is all six). A second client's genuinely new dimension
  /// returns null here and Step 2's entity picker simply can't offer it yet
  /// — see global_filter_bar.dart's own `_handleAdd` comment.
  SalesDimension? get asSalesDimension {
    if (resolutionKind != 'existing') return null;
    for (final d in SalesDimension.values) {
      if (d.dbValue == dimensionKey) return d;
    }
    return null;
  }

  factory ClientDimensionConfig.fromMap(Map<String, dynamic> row) {
    return ClientDimensionConfig(
      dimensionKey: row['dimension_key'] as String,
      displayLabel: row['display_label'] as String,
      sortOrder: row['sort_order'] as int,
      resolutionKind: row['resolution_kind'] as String,
      parentDimensionKey: row['parent_dimension_key'] as String?,
      drivesBudgets: row['drives_budgets'] as bool,
      drivesCrossFilter: row['drives_cross_filter'] as bool,
      isRlsScope: row['is_rls_scope'] as bool,
      showsOnDashboardTop5: row['shows_on_dashboard_top5'] as bool,
    );
  }
}
