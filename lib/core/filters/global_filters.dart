import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app_providers.dart';
import '../constants/fiscal.dart';

/// One selected entity for a dimension filter — `code` is what queries
/// filter by, `label` is what the filter chip displays. Capturing both at
/// selection time (from whichever picker set it — a dropdown, a search
/// result, a table row) means the chip never needs a second network round
/// trip just to show a name.
class FilterSelection {
  final String code;
  final String label;
  const FilterSelection(this.code, this.label);

  @override
  bool operator ==(Object other) => other is FilterSelection && other.code == code && other.label == label;

  @override
  int get hashCode => Object.hash(code, label);
}

const _unset = Object();

/// Session-only, app-wide filter state (Craig, 2026-08-26: "Selection
/// filters need to be iterative throughout the application... Multiple
/// filters can be applied at once"; follow-up decision same day: all 5
/// dimensions plus Year and Month, session-only persistence). Held in a
/// Riverpod provider — not screen-local State — so the SAME instance
/// survives go_router navigation between screens; every screen reads and
/// writes this one object for the life of the signed-in session.
///
/// 2026-09-05 (multi-tenant dimension model, design doc Step 2): rewritten
/// from 5 fixed named fields (salesPerson/category/customer/item/branch) to
/// one `Map<String, FilterSelection>` keyed by dimension_key — the exact
/// string `client_dimensions.dimension_key` (schema/038) uses, which for an
/// 'existing' dimension is the same string as `SalesDimension.dbValue`. This
/// is what lets `GlobalFilterBar` (shared/widgets/global_filter_bar.dart)
/// render its chips/"Add filter" dropdown from a CLIENT's actual configured
/// dimension list instead of a hardcoded 5-field class that could only ever
/// describe WCSA. `forDimension(SalesDimension)` is kept as a thin bridge
/// over the map for every call site this step deliberately leaves alone
/// (the RPC-backed repositories, Sales By/Performance/Budgets/Dashboard's
/// own dimension switchers — see design doc Section 6 steps 3/4) — none of
/// those need to change in Step 2 since WCSA's own dimension set is
/// unchanged; `forKey(String)` is the new, more general accessor for code
/// that already has a raw dimension_key rather than a `SalesDimension`
/// (GlobalFilterBar's own dynamic loop).
///
/// Year/Month/Document stay plain fields, unchanged — none of the three is a
/// "dimension" in the client_dimensions sense (see `client_dimensions`'
/// own header comment, schema/038): Year/Month narrow WHICH period is
/// summed regardless of client, and Document is WCSA-specific raw text with
/// no separate display label (see its own field doc comment below).
class GlobalFilters {
  final Map<String, FilterSelection> _dimensions;

  final int? fiscalYear;
  final String? fiscalMonth; // 'Mar'..'Feb'

  /// 2026-09-07 — Quarter, offered everywhere Year/Month already are (Craig:
  /// "This needs to be built in an offered to all clients the same way as
  /// Year and Month work"). Always FISCAL quarter, confirmed with Craig —
  /// 'Q1'..'Q4' from `fiscalQuarterLabels` (fiscal.dart), Q1 being the
  /// client's own first 3 fiscal months. Kept as a plain field alongside
  /// fiscalYear/fiscalMonth for the exact same reason those are: not a
  /// "dimension" in the client_dimensions sense, so never captured by Saved
  /// Filter Presets (see this class's own doc comment) — `_PresetsDialog`
  /// only ever loops over `dimensions`, so this is automatically excluded,
  /// no extra guard needed there.
  ///
  /// `fiscalQuarterMonths` is `fiscalQuarter` already resolved to its 3
  /// concrete fiscal month labels (`fiscalMonthsInQuarter`, fiscal.dart) —
  /// always set together with `fiscalQuarter` (both null, or both non-null),
  /// resolved ONCE by `GlobalFiltersNotifier.setFiscalQuarter` (which has
  /// `ref` and so can read the client's own `fiscal_year_settings.start_
  /// month`) rather than by every downstream reader. This is what lets the
  /// repository layer (SalesRepository, ReferenceDataRepository) — which
  /// has no `ref` and so no way to resolve 'Q1' into months itself — just
  /// read `filters.fiscalQuarterMonths` directly, the same way it already
  /// reads `filters.fiscalMonth` directly, without every call site needing
  /// to separately thread the client's start month through. The trade-off:
  /// if start_month is edited mid-session with a Quarter filter active, the
  /// resolved months stay whatever they were at selection time until the
  /// filter is re-picked — an edge case judged not worth the alternative
  /// (re-resolving 'Q1' at every one of a dozen-plus call sites instead of
  /// once here), especially since start_month is effectively a one-time
  /// setup value in practice, not something edited mid-session.
  final String? fiscalQuarter;
  final List<String>? fiscalQuarterMonths;

  /// 2026-08-27: promoted from a per-screen local text field on
  /// document_analysis_view.dart to a real global filter — Craig: "We need
  /// to add Document to the Filters dropdown." A raw document number
  /// string, not a `FilterSelection` — there's no separate display label to
  /// carry alongside it the way an entity code/name pair needs one. Only
  /// document_analysis_view.dart (Sales/Quote/Sales Order Analysis) actually
  /// reads this; every other screen works with aggregated rows that have no
  /// document number to filter by, and simply ignores it, same as those
  /// screens already ignore whichever other filters don't apply to them.
  final String? document;

  const GlobalFilters({
    Map<String, FilterSelection> dimensions = const {},
    this.fiscalYear,
    this.fiscalMonth,
    this.fiscalQuarter,
    this.fiscalQuarterMonths,
    this.document,
  }) : _dimensions = dimensions;

  /// A `GlobalFilters` with exactly ONE dimension selection set, nothing
  /// else — replaces the old per-screen `onlyDimension`/`_onlyDimension`
  /// local helpers (dashboard_screen.dart, sales_analysis_screen.dart) that
  /// used to construct `GlobalFilters(salesPerson: selection)` etc. by hand
  /// via a switch over `SalesDimension`. `dimensionKey` is normally
  /// `dimension.dbValue` at these call sites.
  factory GlobalFilters.only(String dimensionKey, FilterSelection selection) =>
      GlobalFilters(dimensions: {dimensionKey: selection});

  /// The selection for a raw dimension_key (client_dimensions.dimension_key,
  /// schema/038) — the primitive accessor everything else in this class is
  /// built from. Returns null when that dimension has no active selection,
  /// including for a key this client has never even configured.
  FilterSelection? forKey(String dimensionKey) => _dimensions[dimensionKey];

  /// Bridge for every call site still keyed on the fixed `SalesDimension`
  /// enum (see this class's own doc comment) — `dimension.dbValue` is always
  /// exactly the dimension_key an 'existing'-resolution client_dimensions row
  /// uses for that dimension, so this is a pure `forKey` lookup, not a
  /// separate mechanism. `company` has no meaningful selection (see
  /// `SalesDimension.filterable`'s own doc comment) and simply looks up a key
  /// nothing ever sets — always null, same as before this class changed.
  FilterSelection? forDimension(SalesDimension dimension) => forKey(dimension.dbValue);

  /// Every dimension_key with an active selection right now — read-only
  /// view; callers should go through `withDimension`/`GlobalFiltersNotifier
  /// .setDimension` to change one, never mutate this directly.
  Map<String, FilterSelection> get dimensions => Map.unmodifiable(_dimensions);

  /// True the moment ANY dimension has a selection — replaces the old
  /// hand-written `salesPerson != null || category != null || ...` chains
  /// that used to appear at every call site needing "is at least one of the
  /// 5 real dimensions filtered" (sales_repository.dart's `_hasCrossFilters`/
  /// `hasDimensionFilters`, the Presets dialog's `_hasDimensionFilter`).
  /// Generalizes automatically as new dimensions are added in a later step —
  /// none of those call sites will need to change again for that.
  bool get hasAnyDimensionSelected => _dimensions.isNotEmpty;

  /// The `p_filters` jsonb map schema/042's generalized RPC functions
  /// (fn_dimension_monthly_sales_filtered, fn_consolidated_sales_filtered,
  /// fn_dimension_performance_filtered, fn_dimension_filter_options) expect —
  /// this map's own dimension_key -> FilterSelection entries, reduced to just
  /// each selection's `code` (the RPC only ever matches on the code, never
  /// the display label). `excludeDimensionKey`, when given, drops that one
  /// key even if it has an active selection — `filterOptionCodes`
  /// (reference_data_repository.dart) needs this: a dimension's own current
  /// selection must never narrow that SAME dimension's own picker list (see
  /// fn_dimension_filter_options' own doc comment, schema/017/042). Every
  /// other caller omits it and gets every active dimension, unfiltered —
  /// matching the five RPC functions' pre-042 named-parameter calls exactly,
  /// which never excluded a dimension from filtering itself either.
  Map<String, String> toFilterParams({String? excludeDimensionKey}) {
    return {
      for (final entry in _dimensions.entries)
        if (entry.key != excludeDimensionKey) entry.key: entry.value.code,
    };
  }

  bool get isEmpty =>
      _dimensions.isEmpty && fiscalYear == null && fiscalMonth == null && fiscalQuarter == null && document == null;

  // fiscalQuarterMonths deliberately not counted separately — it's always
  // set/cleared together with fiscalQuarter (see that field's own doc
  // comment), so counting both would double-count one active filter as two.
  int get activeCount => _dimensions.length + [fiscalYear, fiscalMonth, fiscalQuarter, document].where((v) => v != null).length;

  /// Returns a copy with `dimensionKey`'s selection replaced (or, when
  /// `selection` is null, cleared) — the one place a dimension selection is
  /// ever actually added/changed/removed; `GlobalFiltersNotifier.setDimension
  /// `/`clearDimension` are thin wrappers over this.
  GlobalFilters withDimension(String dimensionKey, FilterSelection? selection) {
    final next = Map<String, FilterSelection>.of(_dimensions);
    if (selection == null) {
      next.remove(dimensionKey);
    } else {
      next[dimensionKey] = selection;
    }
    return copyWith(dimensions: next);
  }

  /// `_unset` sentinel lets a field be explicitly set to null (clearing it)
  /// while every other field keeps its current value — a plain `copyWith`
  /// with nullable named params can't tell "leave unchanged" apart from
  /// "set to null" otherwise. `dimensions`, unlike the other params, has no
  /// such ambiguity to resolve (there's no meaningful "set the whole map to
  /// null"), so it stays a plain nullable positional-by-name param —
  /// omitted or null both mean "keep the current map."
  GlobalFilters copyWith({
    Map<String, FilterSelection>? dimensions,
    Object? fiscalYear = _unset,
    Object? fiscalMonth = _unset,
    Object? fiscalQuarter = _unset,
    Object? fiscalQuarterMonths = _unset,
    Object? document = _unset,
  }) {
    return GlobalFilters(
      dimensions: dimensions ?? _dimensions,
      fiscalYear: identical(fiscalYear, _unset) ? this.fiscalYear : fiscalYear as int?,
      fiscalMonth: identical(fiscalMonth, _unset) ? this.fiscalMonth : fiscalMonth as String?,
      fiscalQuarter: identical(fiscalQuarter, _unset) ? this.fiscalQuarter : fiscalQuarter as String?,
      fiscalQuarterMonths:
          identical(fiscalQuarterMonths, _unset) ? this.fiscalQuarterMonths : fiscalQuarterMonths as List<String>?,
      document: identical(document, _unset) ? this.document : document as String?,
    );
  }
}

/// Same shape as SessionNotifier (app_providers.dart) — resets to empty
/// whenever the signed-in user changes, matching Craig's "for the session
/// only" decision: filters live purely in memory for as long as a GIVEN user
/// is signed in, never written to local storage or Supabase.
///
/// 2026-09-04 (Decisions doc Section 80): this used to listen directly to
/// `AuthRepository.onAuthStateChange` and reset only when `currentSession`
/// became null — correct for an ordinary sign-out, but Craig found the real
/// gap: sign out, then sign straight back in as a DIFFERENT user (Johan) on
/// the same login screen — the OLD user's filter selection was still
/// showing on Johan's own screen. This app is a single long-lived Flutter
/// web page (one `ProviderScope` for the life of the browser tab — see
/// main.dart); `globalFiltersProvider` is never recreated on navigation, so
/// the ONLY thing that ever clears it is this reset logic actually firing at
/// the right moment. Watching `sessionProvider` instead of the raw auth
/// stream — and comparing the resolved PROFILE ID across changes, not just
/// "is there a session at all" — resets on every one of null->user,
/// user->null, AND user->a-different-user, closing that gap regardless of
/// the exact sequence/timing of the underlying Supabase auth events (which
/// this sandbox has no way to reproduce and verify directly — see this
/// file's own note in Section 80).
class GlobalFiltersNotifier extends StateNotifier<GlobalFilters> {
  GlobalFiltersNotifier(Ref ref) : super(const GlobalFilters()) {
    _lastUserId = ref.read(sessionProvider).value?.id;
    ref.listen(sessionProvider, (previous, next) {
      final userId = next.value?.id;
      if (userId != _lastUserId) {
        _lastUserId = userId;
        state = const GlobalFilters();
      }
    });
  }

  String? _lastUserId;

  /// `dimensionKey` is a raw client_dimensions.dimension_key (an 'existing'
  /// dimension's key is the same string as its `SalesDimension.dbValue`) —
  /// every caller that still only has a `SalesDimension` in hand passes
  /// `dimension.dbValue` (see GlobalFilterBar's Presets `_apply`,
  /// top_bar_search.dart's `_selectResult`).
  void setDimension(String dimensionKey, FilterSelection? selection) {
    state = state.withDimension(dimensionKey, selection);
  }

  void clearDimension(String dimensionKey) => setDimension(dimensionKey, null);

  void setFiscalYear(int? year) => state = state.copyWith(fiscalYear: year);

  /// Setting a Month clears any active Quarter (2026-09-07) — Month and
  /// Quarter are both "which fiscal period" filters at different
  /// granularities, and letting both sit active at once (e.g. Month=Jun with
  /// Quarter=Q1, which doesn't even contain June) has no sensible combined
  /// meaning. Rather than defining a precedence rule for that combination
  /// throughout the RPC layer, the two are kept mutually exclusive at the
  /// point of selection instead — picking one always clears the other, so
  /// only one is ever active at a time, same as GlobalFilterBar's own "Add
  /// filter" dropdown only ever lets you pick one value per entry anyway.
  void setFiscalMonth(String? month) => state = state.copyWith(fiscalMonth: month, fiscalQuarter: null, fiscalQuarterMonths: null);

  /// `startMonth` — the client's own `fiscal_year_settings.start_month` —
  /// is resolved to concrete months exactly ONCE, here, via
  /// `fiscalMonthsInQuarter` (fiscal.dart) — see `GlobalFilters.
  /// fiscalQuarterMonths`'s own doc comment for why. Callers pass
  /// `ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3`, the same
  /// fallback convention every other startMonth read in the app already
  /// uses. Clears any active Month — see `setFiscalMonth`'s own doc comment
  /// for why the two stay mutually exclusive.
  void setFiscalQuarter(String? quarter, {required int startMonth}) {
    state = state.copyWith(
      fiscalQuarter: quarter,
      fiscalQuarterMonths: quarter == null ? null : fiscalMonthsInQuarter(quarter, startMonth: startMonth),
      fiscalMonth: null,
    );
  }

  void setDocument(String? document) => state = state.copyWith(document: document);

  void clearAll() => state = const GlobalFilters();
}

final globalFiltersProvider = StateNotifierProvider<GlobalFiltersNotifier, GlobalFilters>(
  (ref) => GlobalFiltersNotifier(ref),
);

/// Applies a clicked table row's own fields as cross-filters — writes to the
/// SAME `GlobalFilters` state the "Add filter" dropdown does, so from here on
/// every screen (including whichever one was clicked on) re-queries as if
/// each of these had been picked by hand, one at a time (Craig, 2026-09-08:
/// "if I am on Sales Analysis and I click on a row. Set the filters
/// according to the selected row and filter out everything that does not
/// meet the filters across the app. Just as if we had setup the filters
/// independently. If the Date on the row is 2026-09-01 then year = 2026 and
/// month = sep. If sales person = Jacqi then set etc."). This is
/// deliberately additive/replacing only for the specific fields the row
/// actually carries — it never clears a filter for a dimension (or Year/
/// Month) the row says nothing about, matching "as if... independently"
/// literally: exactly one `setDimension`/`setFiscalYear`/`setFiscalMonth`
/// call per field the row has, nothing else touched. A row from a screen
/// with no date column (most dimension-rollup screens — Sales By,
/// Performance, the Dashboard's Table view) simply omits `date` and only
/// sets whichever dimension(s) it has.
///
/// `date`, when given, is resolved to the client's own FISCAL year/month
/// (never the plain calendar year/month) via `fiscalYearFor`/
/// `fiscalMonthLabelFor` — the same two functions every other "a real
/// calendar date maps to which fiscal period" call site in the app already
/// uses — so a row from 1 September under an October-start fiscal year sets
/// Year/Month exactly the way the global Year/Month pickers themselves
/// would, not a plain calendar-year/month guess. Setting Month this way also
/// clears any active Quarter, same as picking a Month from the filter bar
/// itself (see `GlobalFiltersNotifier.setFiscalMonth`'s own doc comment) —
/// Year/Month/Quarter are all "which period" at different granularities, and
/// a row click is picking one specific month, not a quarter.
void applyRowCrossFilters(
  WidgetRef ref, {
  Map<String, FilterSelection> dimensions = const {},
  DateTime? date,
  int startMonth = 3,
}) {
  final notifier = ref.read(globalFiltersProvider.notifier);
  for (final entry in dimensions.entries) {
    notifier.setDimension(entry.key, entry.value);
  }
  if (date != null) {
    notifier.setFiscalYear(fiscalYearFor(date, startMonth: startMonth));
    notifier.setFiscalMonth(fiscalMonthLabelFor(date));
  }
}
