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

  /// schema/043 (2026-09-06): whether this dimension is actually live in the
  /// app yet. Craig, right after seeing the Dimensions tab: "How do we make
  /// sure that the Client Dimensions and Client WyzeSalesExtract are
  /// aligned? If I added a new Dimension to WCSA now, the WyzeSalesExtract
  /// would not know about it??" — correct: WCSA's extractor writes a fixed,
  /// hardcoded set of columns with zero awareness of client_dimensions, so a
  /// brand-new dimension configured here would show up in every filter/
  /// screen immediately while its backing column sits permanently null until
  /// that client's extractor is separately rewritten and redeployed.
  /// `ReferenceDataRepository.clientDimensions()` (the query behind
  /// `clientDimensionsProvider`, which every app screen reads) filters to
  /// `is_live = true` — so a new dimension can be entered ahead of time and
  /// stays completely invisible to the real app until a platform admin
  /// confirms real data is flowing and explicitly publishes it. Defaults to
  /// `true` at the DB column level (safe for WCSA's existing six rows, which
  /// already work today), but `_EditDimensionDialog` sends `false` explicitly
  /// when creating any BRAND NEW dimension, so new ones start as drafts.
  final bool isLive;

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
    this.isLive = true,
  });

  /// Bridges back to the OLD fixed `SalesDimension` enum — null for any
  /// 'fact_column'/'customer_attribute' dimension, since those have no
  /// `SalesDimension` value at all (they didn't exist before this migration).
  /// 2026-09-06 (Step 4): Sales By/Performance/Budgets now work off this
  /// class directly (`entitiesForConfig`/`namesForConfig`,
  /// reference_data_repository.dart) rather than `SalesDimension` — this
  /// bridge's remaining job is letting THOSE new code paths reuse the
  /// original per-dimension reference-table queries (`entitiesFor`) for the
  /// 6 'existing' dimensions without duplicating that switch statement.
  /// GlobalFilterBar's own "Add filter" entity picker and the Dashboard's
  /// ranking-breakdown/top-bar search are UNCHANGED by Step 4 and still only
  /// know how to work with a `SalesDimension` — this is also still what lets
  /// THOSE hand one of those a value it understands for the dimensions that
  /// are still 'existing' (which, for WCSA today, is all six). A second
  /// client's genuinely new dimension returns null here; those call sites
  /// simply can't offer it as a global filter target yet — see
  /// global_filter_bar.dart's own `_handleAdd` comment.
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
      isLive: (row['is_live'] as bool?) ?? true,
    );
  }
}

/// Looking up one dimension by its raw dimension_key out of
/// `clientDimensionsProvider`'s own list — 2026-09-06 (Step 4), Sales By/
/// Performance/Budgets each need this to resolve the route's `:dimension`
/// path segment (a bare string) back to its display label/resolutionKind.
extension ClientDimensionConfigLookup on List<ClientDimensionConfig> {
  /// Null when this client has no such dimension configured, OR (just as
  /// importantly) while `clientDimensionsProvider` hasn't loaded yet —
  /// callers fall back to the raw dimensionKey string as a display label in
  /// either case, same "don't block rendering" convention
  /// `clientDimensionsProvider`'s other callers already use (see
  /// global_filter_bar.dart's own `.valueOrNull ?? const []`).
  ClientDimensionConfig? forKey(String dimensionKey) {
    for (final d in this) {
      if (d.dimensionKey == dimensionKey) return d;
    }
    return null;
  }
}
