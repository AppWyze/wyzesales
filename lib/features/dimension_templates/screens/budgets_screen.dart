import 'package:data_table_2/data_table_2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/app_providers.dart';
import '../../../core/constants/fiscal.dart';
import '../../../core/filters/global_filters.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/budget_figure.dart';
import '../../../data/models/client_dimension_config.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/reference_data.dart';
import '../../../data/models/sales_forecast_figure.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/async_section.dart';
import '../../../shared/widgets/boxed_dropdown.dart';
import '../../../shared/widgets/responsive_data_table.dart';

/// 2026-09-01, Craig, looking at a screenshot of this exact screen: "The
/// Sales Budget input value is not formatted to 591,080." Every other
/// number in the app already gets comma-grouped thousands via
/// formatRand/formatQuantity (formatters.dart) — this TextField was the one
/// place displaying a raw editable number (a plain `keyboardType:
/// TextInputType.number` field with no formatter at all), because it's the
/// one live-editable numeric input in the app rather than a read-only
/// Text/DataCell. Re-formats to "591,080" on every keystroke as the admin
/// types; digits are stripped back out again before parsing/saving
/// (`_MonthTableState._saveMonth`), so what's actually persisted is still
/// the plain numeric value budget_figures.budget_value always was.
///
/// Deliberately simple rather than cursor-position-preserving: always
/// re-collapses to the digits typed so far and places the cursor at the
/// end. A budget figure is typed once, start to finish, in one sitting —
/// there's no realistic case here of editing in the middle of an existing
/// number the way there might be in a general-purpose form field — so the
/// simpler implementation was not worth trading against a much fussier
/// mid-string-edit-safe version for a field nobody edits that way.
/// 2026-09-01, Craig, testing the field this formatter lives on: "Can you
/// Also remove the decimals on the input." Some existing budget_figures
/// rows already carry cents (e.g. 591080.13, presumably from before this
/// field had any formatting at all) — `NumberFormat.decimalPattern`
/// preserves whatever precision a value actually has, so those rows'
/// initial display picked up their real decimals the moment this field
/// switched from the old `.toStringAsFixed(0)` (always whole, no matter
/// what was stored) to this formatter. Pattern `'#,##0'` forces whole-Rand
/// display unconditionally, matching what this field always showed before
/// today and simply adding comma grouping on top — nobody has ever been
/// able to see or rely on cents in this field.
class _ThousandsInputFormatter extends TextInputFormatter {
  static final RegExp _nonDigits = RegExp(r'[^\d]');
  static final NumberFormat _format = NumberFormat('#,##0', 'en_US');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(_nonDigits, '');
    if (digits.isEmpty) {
      return const TextEditingValue(text: '');
    }
    final formatted = _format.format(int.parse(digits));
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
  }
}

class _BudgetEntityData {
  final List<CodeName> entities;
  const _BudgetEntityData(this.entities);
}

class _BudgetMonthData {
  final Map<String, num> budget; // fiscal_month -> value
  final Map<String, num> forecast;
  final Map<String, String> confidence;
  const _BudgetMonthData({required this.budget, required this.forecast, required this.confidence});
}

/// One entity's annual Sales Budget/Seasonal Forecast totals, as shown on
/// the landing-pane summary before any entity is selected — see
/// `_BudgetsScreenState._loadContribution` and `_DimensionContributionData`
/// below. Deliberately just the two annual totals, not a full
/// `_BudgetMonthData`'s worth of per-month detail — the summary only ever
/// needs a % of each entity's yearly figure, never a monthly breakdown.
class _EntityContribution {
  final String code;
  final String label;
  final num budgetTotal;
  final num forecastTotal;
  const _EntityContribution({
    required this.code,
    required this.label,
    required this.budgetTotal,
    required this.forecastTotal,
  });
}

/// The landing-pane summary data: every entity in the current dimension
/// (2026-09-22, Craig: "list the entities for the dimension and what their
/// contribution is ... for both Sales Budgets and Seasonal Forecast"),
/// pre-sorted by Sales Budget contribution descending, plus the two
/// dimension-wide totals each entity's own % is computed against.
class _DimensionContributionData {
  final List<_EntityContribution> entities;
  final num budgetGrandTotal;
  final num forecastGrandTotal;
  const _DimensionContributionData({
    required this.entities,
    required this.budgetGrandTotal,
    required this.forecastGrandTotal,
  });
}

/// Same "value / total, '—' when total is 0" one-line rule as
/// `_MonthTableState._pctOf` below — kept as its own top-level copy rather
/// than shared, since that one is a month's share of ONE entity's own
/// annual total, and this one is an entity's share of the WHOLE
/// dimension's total across every entity — different axes that just
/// happen to reduce to the identical formula.
String _formatContributionPct(num value, num total) => total == 0 ? '—' : '${(value / total * 100).round()}%';

/// A dimension dropdown plus the global filter bar select which entity is
/// showing (2026-09-30 — see `build()`'s own doc comment for the standalone
/// entity-list panel this replaced); the selected entity's own two
/// 12-month fiscal columns are an editable Sales Budget and a read-only
/// Seasonal Forecast (Wyzesales_Screens_and_Recommendations.md Section 1).
/// Editing requires adminuser (schema/008 retired superuser from this and
/// everything else — see `Profile.canEditBudgets`'s own comment).
///
/// 2026-09-03, Craig (Wyzesales_Rebuild_Decisions.md Section 70): "A User
/// must be able to see their own Budget but also Category Budget, Item
/// Budget, and only their allocated Customers Budgets. Not Branch or
/// Company. A Regional User must see the Branch Sales Persons, Category,
/// Items, Branch Customers and the Branch Budget. Admin sees every thing.
/// Users and RegUsers only have view access." Viewing is now open to every
/// level — only editing stays adminuser-only. Which DIMENSIONS a level can
/// even pick from is filtered client-side by `_allowedDimensionsFor` purely
/// as a convenience (no point offering a Branch entry list to a plain User
/// when migration 031's RLS would hand back zero rows for it); the actual
/// enforcement of which rows within an allowed dimension are visible lives
/// entirely in `budget_figures_select`/`sales_forecast_select` (migration
/// 031), same as every other screen in this app.
class BudgetsScreen extends ConsumerStatefulWidget {
  const BudgetsScreen({super.key, required this.dimension});

  /// A plain dimension_key (client_dimensions.dimension_key, schema/038) —
  /// 2026-09-06 (Step 4), see SalesByScreen.dimension's own doc comment for
  /// the full reasoning; identical change, same reasons.
  final String dimension;

  @override
  ConsumerState<BudgetsScreen> createState() => _BudgetsScreenState();
}

/// Which dimensions a login can pick from on the Budgets screen at all —
/// Wyzesales_Rebuild_Decisions.md Section 70 (migration 031). Company stays
/// admin-only for both non-admin levels (never asked for); a plain User has
/// no "own branch" concept at all, so Branch is admin+reguser only. This is
/// purely a UI convenience so a User/RegUser isn't shown an entity list for
/// a dimension `budget_figures_select`/`sales_forecast_select` would just
/// return zero rows for anyway — RLS is the only real enforcement, and this
/// list is deliberately kept in lockstep with it rather than duplicating any
/// row-level logic here.
///
/// 2026-09-06 (Step 4): generalized from the fixed `SalesDimension` list to
/// this client's own configured dimensions (`allDimensions`, from
/// `clientDimensionsProvider`), so a brand-new client's own dimension is
/// budget-pickable too. The two carve-outs above map onto flags every
/// dimension already carries rather than a hardcoded per-dimension list:
/// "not Company" is `dimensionKey != 'company'` (the reserved whole-company
/// pseudo-dimension, same special key schema/042's SQL treats specially);
/// "not Branch" for a plain User is `!isRlsScope` — Branch is WCSA's own
/// is_rls_scope dimension (schema/038's WCSA seed), so this generalizes
/// "the one dimension a RegUser is pinned to isn't something a plain User
/// gets to pick an arbitrary OTHER entity's budget within" to any client.
/// Checked against WCSA's exact 3 pre-existing lists: adminuser/superuser =
/// all 6; reguser = all 6 minus company = the old 5-item list; user = that
/// minus branch (WCSA's is_rls_scope dimension) = the old 4-item list —
/// byte-for-byte the same 3 outcomes as before this generalized.
List<ClientDimensionConfig> _allowedDimensionsFor(Profile? profile, List<ClientDimensionConfig> allDimensions) {
  switch (profile?.level) {
    case UserLevel.adminuser:
    // superuser is vestigial — schema/008 retired it outright and nothing
    // is ever assigned it again (see Profile.canEditBudgets's comment) —
    // treated the same as adminuser here rather than falling through to
    // the narrowest case for a level nobody actually has.
    case UserLevel.superuser:
      return allDimensions;
    case UserLevel.reguser:
      return allDimensions.where((d) => d.dimensionKey != 'company').toList();
    case UserLevel.user:
    case null:
      return allDimensions.where((d) => d.dimensionKey != 'company' && !d.isRlsScope).toList();
  }
}

class _BudgetsScreenState extends ConsumerState<BudgetsScreen> {
  late Future<_BudgetEntityData> _entitiesFuture;
  String? _selectedEntityCode;
  String? _selectedEntityName;
  Future<_BudgetMonthData>? _monthDataFuture;
  late Future<_DimensionContributionData> _contributionFuture;

  // Contribution-by-entity table sort (2026-10-06, Craig: click a column header to sort). Starts where the
  // loader already ordered it: Sales Budget, biggest first.
  int _contribSortColumn = 1;
  bool _contribSortAscending = false;

  /// 2026-09-30, Craig: "How would your recommend increasing or decreasing
  /// a dimension budget?... increase or decrease only a single dimension
  /// budget by a % across it's entities." Backs the "Adjust budget by %"
  /// control on the Contribution-by-entity summary — see
  /// `_buildAdjustByPercent` below. Lives on this State (not its own
  /// StatefulWidget) for the same reason `_MonthTableState` keeps its own
  /// TextEditingControllers directly on its State: one control, one owner,
  /// no need for a separate widget just to hold it.
  final TextEditingController _scalePercentController = TextEditingController();
  bool _scaling = false;

  @override
  void initState() {
    super.initState();
    _entitiesFuture = _loadEntities();
    _contributionFuture = _loadContribution();
  }

  @override
  void dispose() {
    _scalePercentController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BudgetsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dimension != widget.dimension) {
      _selectedEntityCode = null;
      _monthDataFuture = null;
      _entitiesFuture = _loadEntities();
      _contributionFuture = _loadContribution();
    }
  }

  /// 2026-09-03, Craig, after confirming Section 70's "only their allocated
  /// Customers Budgets" behaved exactly as intended (blank figures for a
  /// customer a User can see but isn't allocated to): "hide the Customer if
  /// it does not belong to the User." A User's RLS-visible customer set
  /// (`customers_select`, `fn_customer_visible_to_rep` — assigned to me OR
  /// I've sold to them) is broader than the set Budgets now shows a figure
  /// for (`fn_customer_allocated_to_rep` — assigned to me only), so without
  /// this a User could pick a customer here and see nothing but em-dashes.
  /// Narrowed with a plain `assigned_rep_code` equality filter ON TOP of
  /// RLS (`ReferenceDataRepository.customers`'s own doc comment) — this is a
  /// convenience narrowing for THIS screen's picker only, not a change to
  /// who can see a customer elsewhere in the app (the global Customer
  /// filter/search still use the broader "visible to rep" rule, unchanged).
  /// RegUser/Admin are untouched: a RegUser's Customer list here already
  /// uses the same "sold at my branch" rule Budgets' own figures use, so
  /// there's no equivalent gap for that level.
  Future<_BudgetEntityData> _loadEntities() async {
    final profile = ref.read(sessionProvider).value;
    final restrictToOwnCustomers = widget.dimension == 'customer' && profile?.level == UserLevel.user;
    // .future, not .valueOrNull — see SalesByScreen._load()'s identical
    // comment for why this is safe/correct inside an already-async load.
    final dimensionConfig = (await ref.read(clientDimensionsProvider.future)).forKey(widget.dimension);
    final list = dimensionConfig == null || profile?.clientId == null
        ? <CodeName>[]
        : await ref.read(referenceDataRepositoryProvider).entitiesForConfig(
            dimensionConfig,
            profile!.clientId,
            customerAssignedRepCode: restrictToOwnCustomers ? profile.repCode : null,
          );
    final data = _BudgetEntityData(list);
    // 2026-09-30, Craig, after confirming the filter-driven redesign above
    // works everywhere else: "This works perfectly except for Company. I
    // suggest we merge the Contribution by entity screen and the actual
    // Sales Budget, Seasonal Forecast Screen for only Company into one."
    // Root cause: Company always has exactly ONE entity — `entitiesFor`'s
    // own doc comment, `CodeName(code: 'ALL', name: 'Company')`, no real
    // reference table backs it — and `company` is deliberately excluded
    // from `SalesDimension.filterable` (global_filter_bar.dart), so it was
    // never offered as a filterable dimension in "Add filter"/the search
    // bar at all, for any screen. That's harmless everywhere else (Sales
    // By/Performance just show the one Company row directly), but for
    // Budgets specifically it meant `_applyGlobalFilterSelection` could
    // never fire for this dimension once the standalone entity-list panel
    // was removed — with no filter able to select it and no list left to
    // click it from, Company's month table became permanently unreachable,
    // stuck showing a "Company: 100%" one-row summary that told you
    // nothing you didn't already know just from being on this screen.
    // Since there is never a second entity to choose between, select the
    // one there is unconditionally rather than routing it through the
    // filter — the Contribution summary would be pure redundancy for this
    // one dimension (a single row that's always 100% of itself), so skip
    // straight to the real Sales Budget/Seasonal Forecast view every time,
    // exactly as Craig asked. Every other dimension is untouched — this is
    // the one place `widget.dimension == 'company'` is special-cased.
    if (widget.dimension == 'company' && data.entities.isNotEmpty) {
      if (mounted) _selectEntity(data.entities.first);
    } else {
      _applyGlobalFilterSelection(data);
    }
    return data;
  }

  /// The landing-pane summary shown before any entity is selected
  /// (2026-09-22, Craig: "list the entities for the dimension and what
  /// their contribution is ... for both Sales Budgets and Seasonal
  /// Forecast") — each entity's own annual Sales Budget/Seasonal Forecast
  /// total as a % of the whole dimension's total, the same "% of total"
  /// idea `_MonthTableState` already uses per-entity across months
  /// (`_pctOf`), just summed across entities instead of across months.
  ///
  /// Awaits `_entitiesFuture` itself rather than re-deriving the entity
  /// list a second way, so this always reflects the exact same
  /// level-filtered/RLS-visible entities a same-dimension filter can match
  /// against (`_applyGlobalFilterSelection`) — an entity a User isn't
  /// allowed to see never appears in this summary, or gets selected via a
  /// filter, either. `BudgetRepository.fetchBudget`/`fetchForecast` already
  /// support "every entity in this dimension" by simply omitting
  /// `entityCode` (added 2026-09-03 for the Dashboard's Rep Target
  /// Attainment — see that method's own doc comment), so this needs no new
  /// repository method, just the two existing ones called without an
  /// entity filter and summed client-side.
  Future<_DimensionContributionData> _loadContribution() async {
    final entities = (await _entitiesFuture).entities;
    final budgetRepo = ref.read(budgetRepositoryProvider);
    final results = await Future.wait([
      budgetRepo.fetchBudget(dimension: widget.dimension),
      budgetRepo.fetchForecast(dimension: widget.dimension),
    ]);
    final budgetRows = results[0] as List<BudgetFigure>;
    final forecastRows = results[1] as List<SalesForecastFigure>;

    final budgetByEntity = <String, num>{};
    for (final b in budgetRows) {
      budgetByEntity[b.entityCode] = (budgetByEntity[b.entityCode] ?? 0) + b.budgetValue;
    }
    final forecastByEntity = <String, num>{};
    for (final f in forecastRows) {
      forecastByEntity[f.entityCode] = (forecastByEntity[f.entityCode] ?? 0) + f.forecastValue;
    }

    final rows = [
      for (final e in entities)
        _EntityContribution(
          code: e.code,
          label: e.displayLabel,
          budgetTotal: budgetByEntity[e.code] ?? 0,
          forecastTotal: forecastByEntity[e.code] ?? 0,
        ),
    ];
    // Highest Sales Budget contribution first, so the summary reads as a
    // ranking — matching how Sales By already ranks entities by their own
    // primary metric. A static sort, not user-resortable: Craig, when
    // confirming this feature, opted for a plain read-only summary rather
    // than an interactive table here.
    rows.sort((a, b) => b.budgetTotal.compareTo(a.budgetTotal));

    return _DimensionContributionData(
      entities: rows,
      budgetGrandTotal: rows.fold<num>(0, (sum, r) => sum + r.budgetTotal),
      forecastGrandTotal: rows.fold<num>(0, (sum, r) => sum + r.forecastTotal),
    );
  }

  /// Budgets/forecast (budget_figures/sales_forecast, schema/001 Section 4/
  /// 5) are keyed by ONE dimension + entity_code only — there's no other
  /// dimension's code recorded against a budget row at all, so unlike every
  /// other screen this migration wires up, a global filter for a DIFFERENT
  /// dimension genuinely can't narrow anything here (there's no data to
  /// narrow). What this CAN do is jump straight to the entity a global
  /// filter already names for THIS screen's own dimension — e.g. arriving
  /// on Budgets — Sales Person with a global Sales Person filter active
  /// selects that rep instead of leaving the summary unselected.
  ///
  /// 2026-09-30, Craig: "Can we change the Budgets screen to work the same
  /// way as the other screens. Defaults to Dimension = Sales Person. We can
  /// change the Dimension via the dropdown and filter on an Entity." Until
  /// today this was one of two ways to pick an entity (the other being the
  /// standalone scrollable entity-list panel this screen used to show
  /// alongside the dropdown) — Craig's ask removed that panel entirely (see
  /// `build()`'s own doc comment), so the global filter — "Add filter"/the
  /// top search bar, exactly like Sales By/Performance/the Dashboard — is
  /// now the ONLY way to select an entity here, matching how every other
  /// dimension-template screen already worked. No longer flagged as a
  /// partial exception in Wyzesales_Rebuild_Decisions.md Section 18 — this
  /// screen is now as fully filter-driven as the others, for its own
  /// dimension; the cross-dimension limitation in the paragraph above still
  /// stands (there's still no data to narrow the summary by another
  /// dimension), that part hasn't changed.
  void _applyGlobalFilterSelection(_BudgetEntityData data) {
    final selection = ref.read(globalFiltersProvider).forKey(widget.dimension);
    if (selection == null || !mounted) return;
    final match = data.entities.where((e) => e.code == selection.code).toList();
    if (match.isEmpty) return;
    _selectEntity(match.first);
  }

  void _selectEntity(CodeName entity) {
    setState(() {
      _selectedEntityCode = entity.code;
      _selectedEntityName = entity.displayLabel;
      _monthDataFuture = _loadMonthData(entity.code);
    });
  }

  /// 2026-09-30: the counterpart to `_selectEntity`, now that the global
  /// filter is the only way in or out of a selected entity (see
  /// `_applyGlobalFilterSelection`'s doc comment) — removing this screen's
  /// own dimension filter (the chip's own "x", "Clear all", or picking a
  /// different search result) needs to drop back to the Contribution
  /// summary, not leave the last-viewed entity's month table stranded on
  /// screen with no filter chip left to explain why it's showing.
  void _clearSelection() {
    setState(() {
      _selectedEntityCode = null;
      _selectedEntityName = null;
      _monthDataFuture = null;
    });
  }

  Future<_BudgetMonthData> _loadMonthData(String entityCode) async {
    final budgetRepo = ref.read(budgetRepositoryProvider);
    final results = await Future.wait([
      budgetRepo.fetchBudget(dimension: widget.dimension, entityCode: entityCode),
      _fetchForecast(entityCode),
    ]);
    final budgetRows = results[0] as List<BudgetFigure>;
    final forecastRows = results[1] as List<Map<String, dynamic>>;
    return _BudgetMonthData(
      budget: {for (final b in budgetRows) b.fiscalMonth: b.budgetValue},
      forecast: {for (final f in forecastRows) f['fiscal_month'] as String: f['forecast_value'] as num},
      confidence: {for (final f in forecastRows) f['fiscal_month'] as String: f['confidence'] as String},
    );
  }

  /// sales_forecast is read-only and only needed on this one screen, so
  /// queried directly rather than adding a dedicated repository for a
  /// single call site.
  Future<List<Map<String, dynamic>>> _fetchForecast(String entityCode) async {
    return supabase
        .from('sales_forecast')
        .select('fiscal_month, forecast_value, confidence')
        .eq('dimension', widget.dimension)
        .eq('entity_code', entityCode);
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(sessionProvider);
    // valueOrNull ?? const [] — see SalesByScreen.build()'s identical
    // comment for the reasoning. Computed up front so it's available to
    // both the loading branch below and the fully-rendered body.
    final dimensions = ref.watch(clientDimensionsProvider).valueOrNull ?? const <ClientDimensionConfig>[];
    final dimensionLabel = dimensions.forKey(widget.dimension)?.displayLabel ?? widget.dimension;

    // Mirrors dashboard_screen.dart's own fix for the identical race
    // (Craig, 2026-09-03: "Dashboard opens and it shows 0 target. I
    // navigate to another screen and then back... and it shows correctly")
    // — `_loadEntities()` is kicked off from `initState`, which can run
    // before SessionNotifier's own async profile fetch finishes. For the
    // Customer dimension, `_loadEntities` uses whatever profile
    // `ref.read(sessionProvider).value` returns AT THAT MOMENT to decide
    // whether to narrow the list to a User's allocated customers; a null
    // profile at that instant silently falls back to the unfiltered list
    // instead. Refetch once the profile actually arrives so a User who
    // lands directly on Budgets — Customer (a fresh page load/deep link,
    // not simple in-app navigation, where the profile is virtually always
    // already loaded) still gets the narrowed list without needing to
    // switch dimensions and back to trigger it. Scoped to the Customer
    // dimension only — it's the only one `_loadEntities` treats
    // profile-dependently.
    ref.listen<AsyncValue<Profile?>>(sessionProvider, (previous, next) {
      if (previous?.value != null || next.value == null) return;
      if (widget.dimension == 'customer') {
        setState(() => _entitiesFuture = _loadEntities());
      }
    });

    // 2026-09-30, Craig: "On the budgets screen the filter selection does
    // not work." Root cause: `_applyGlobalFilterSelection` (this screen's
    // own "jump to the entity a global filter already names for THIS
    // screen's dimension" behaviour — see that method's own doc comment)
    // only ever ran once, from `initState`/`didUpdateWidget`, using
    // whatever filter was already active at that moment. Every OTHER
    // screen that reacts to the global filter bar while already open
    // (SalesByScreen.build(), for one) does it via a `ref.listen` on
    // `globalFiltersProvider` — this screen was simply missing the
    // equivalent listener, so picking (or changing) a same-dimension
    // filter via "Add filter"/the search bar while already sitting on
    // Budgets — Sales Person did nothing visible at all until you
    // navigated away and back (which re-runs `initState`) or switched
    // dimensions and back.
    //
    // 2026-09-30 (later same day, Craig: "change the Budgets screen to work
    // the same way as the other screens... filter on an Entity"): this
    // listener is now the ONLY way an entity gets selected at all — the
    // standalone entity-list panel `_applyGlobalFilterSelection` used to
    // merely supplement is gone (see `build()`'s own doc comment), so a
    // CLEARED selection (the filter chip's "x", "Clear all", or search
    // for/pick a different dimension entirely) has to actively drop this
    // screen back to the Contribution summary via `_clearSelection()` —
    // before today that case was simply never reachable this way (the list
    // panel's own click-to-select handled every case), so there was
    // nothing else for a cleared filter to do here.
    //
    // Scoped to only react when THIS screen's own dimension selection
    // actually changed — an unrelated dimension's filter changing (which
    // this screen still can't use, see `_applyGlobalFilterSelection`'s doc
    // comment) fires this listener too but is a same-value no-op, not a
    // second bug. Re-reads `_entitiesFuture` rather than reloading it — the
    // entity LIST itself never depends on the filter (only which one is
    // selected does), so there's nothing to re-fetch, just re-match against
    // what's already loaded.
    ref.listen<GlobalFilters>(globalFiltersProvider, (previous, next) {
      final previousSelection = previous?.forKey(widget.dimension);
      final nextSelection = next.forKey(widget.dimension);
      if (previousSelection == nextSelection) return;
      if (nextSelection == null) {
        _clearSelection();
        return;
      }
      _entitiesFuture.then((data) {
        if (mounted) _applyGlobalFilterSelection(data);
      });
    });

    // Checked separately from "not yet loaded" so a still-loading profile
    // shows a spinner instead of flashing content computed from a null
    // profile (which `_allowedDimensionsFor`/`canEditBudgets` below would
    // otherwise treat as the narrowest, User-level case) before the real
    // value arrives.
    if (profileAsync.isLoading) {
      return AppShell(
        title: 'Budgets — $dimensionLabel',
        currentRoute: '/budgets/${widget.dimension}',
        body: const Center(child: RepaintBoundary(child: CircularProgressIndicator())),
      );
    }

    final profile = profileAsync.value;
    final canEditBudgets = profile?.canEditBudgets ?? false;
    final allowedDimensions = _allowedDimensionsFor(profile, dimensions);

    // Every level can view Budgets now (Section 70) — the screen itself no
    // longer has a hard access-denied state. What's left to guard against
    // is a User/RegUser landing directly on a dimension route their level
    // can't see at all (a bookmarked/typed /budgets/company, or
    // /budgets/branch as a plain User) — bounce to the first dimension
    // they're actually allowed rather than show them an entity list that
    // migration 031's RLS would return zero rows for regardless. Deferred
    // to a post-frame callback since build() itself must return a widget,
    // not navigate mid-build.
    //
    // `allowedDimensions.isNotEmpty` guards the one other reason this can be
    // empty besides a genuine access issue: `clientDimensionsProvider`
    // hasn't resolved yet on a cold load. Skipping the redirect in that
    // case (rather than crashing on `.first` of an empty list) just falls
    // through to the normal render below, which itself tolerates an
    // empty/still-loading dimension list — see the dropdown's own fallback
    // item and `_loadEntities`' `dimensionConfig == null` branch.
    if (allowedDimensions.isNotEmpty && !allowedDimensions.any((d) => d.dimensionKey == widget.dimension)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/budgets/${allowedDimensions.first.dimensionKey}');
      });
      return AppShell(
        title: 'Budgets',
        currentRoute: '/budgets/${widget.dimension}',
        body: const Center(child: RepaintBoundary(child: CircularProgressIndicator())),
      );
    }

    // 2026-09-30, Craig: "Can we change the Budgets screens to work the
    // same way as the other screens. Defaults to Dimension = Sales Person.
    // We can change the Dimension via the drop down and filter on an
    // Entity." Until today this screen paired the dimension dropdown with
    // its OWN standalone, scrollable entity-list panel (a fixed-width
    // side-by-side column below ~900px collapsing to a fixed-height stack
    // above a `_stackBreakpoint` of 700px — the 2026-09-07 "optimised for
    // Mobile, Tablet and Desktop" layout this replaces) — every other
    // dimension-template screen (Sales By, Performance, the Dashboard) has
    // no such panel at all: just the dimension dropdown plus the global
    // filter bar's "Add filter"/search-driven entity selection. Dropped the
    // list panel entirely so Budgets now matches that same pattern — the
    // dropdown here still only switches WHICH dimension (unchanged), and
    // `_applyGlobalFilterSelection`/`_clearSelection` (see their own doc
    // comments) are what actually select or deselect an entity now, driven
    // purely by the global filter the same way every other screen already
    // works. `detail` (the Contribution summary vs. the selected entity's
    // month table) is unchanged from before — only what used to sit beside
    // it is gone, so this is a plain single-column layout now, no more
    // LayoutBuilder/breakpoint stacking needed either.
    final dropdown = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: BoxedDropdown<String>(
        value: widget.dimension,
        width: 236,
        items: [
          for (final d in allowedDimensions) DropdownMenuItem(value: d.dimensionKey, child: Text(d.displayLabel)),
          // Same "value must match an item" fallback as
          // SalesByScreen/PerformanceScreen's own dimension
          // switchers — see their doc comments.
          if (!allowedDimensions.any((d) => d.dimensionKey == widget.dimension))
            DropdownMenuItem(value: widget.dimension, child: Text(dimensionLabel)),
        ],
        onChanged: (d) {
          if (d != null && d != widget.dimension) context.go('/budgets/$d');
        },
      ),
    );
    final detail = _selectedEntityCode == null
        ? AsyncSection<_DimensionContributionData>(
            future: _contributionFuture,
            isEmpty: (d) => d.entities.isEmpty,
            emptyMessage: 'No entities to show for this dimension yet.',
            builder: (context, data) => _buildContributionSummary(context, data, canEditBudgets),
          )
        : Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_selectedEntityName ?? _selectedEntityCode!, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Expanded(
                  child: AsyncSection<_BudgetMonthData>(
                    future: _monthDataFuture!,
                    builder: (context, data) => _MonthTable(
                      dimension: widget.dimension,
                      entityCode: _selectedEntityCode!,
                      data: data,
                      // Section 70: the screen no longer denies
                      // access outright, so this now genuinely
                      // varies — adminuser gets the editable
                      // TextField cells and Save button,
                      // User/RegUser get _MonthTable's existing
                      // read-only Text rendering.
                      canEdit: canEditBudgets,
                      clientId: profile?.clientId,
                    ),
                  ),
                ),
              ],
            ),
          );

    return AppShell(
      title: 'Budgets — $dimensionLabel',
      currentRoute: '/budgets/${widget.dimension}',
      // Plain single-column body — dropdown up top (matching Sales By/
      // Performance's own dimension switcher placement), then whichever of
      // the Contribution summary or the selected entity's month table
      // `detail` currently is. No LayoutBuilder/breakpoint stacking left to
      // do now that there's no second column competing for width on a
      // narrow screen (see the dropdown's own doc comment above).
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            dropdown,
            const Divider(height: 1),
            Expanded(child: detail),
          ],
        ),
      ),
    );
  }

  /// The landing-pane summary — ranks every entity in the current dimension
  /// by its share of the dimension's total Sales Budget and Seasonal
  /// Forecast. This is what shows by default for the current dimension
  /// until a same-dimension global filter selects one entity
  /// (`_applyGlobalFilterSelection`).
  ///
  /// Row click -> global cross-filter (Craig, 2026-09-30: "if you click on
  /// an entity it needs to apply the filters according to selected rows and
  /// filter the data accordingly", extending Sales By/Performance's existing
  /// `applyRowCrossFilters` wiring — see that function's own doc comment,
  /// core/filters/global_filters.dart — to this table too). This supersedes
  /// an earlier explicit decision (Craig, confirming the original version of
  /// this feature: "not clickable, percentage only, no dollar values") — the
  /// table itself is unchanged (still percentage-only, no dollar values),
  /// only the row-click behaviour is new. Selecting a row here narrows this
  /// same table to that one entity (`_applyGlobalFilterSelection` already
  /// reacts to any global filter change on this dimension), exactly like
  /// clicking a Company entity already does via `_loadEntities`'s special
  /// case. No date on this screen's rows (a per-entity rollup, not a
  /// document), so only this screen's own dimension gets set — same "just
  /// the fields the row actually carries" rule every other screen's row
  /// click follows. `_MonthTable` below remains the one deliberate exception
  /// to this app-wide pattern — see its own `build()` doc comment for the
  /// live-TextField focus-stealing risk that's still unrelated to and
  /// unaffected by this change.
  Widget _buildContributionSummary(BuildContext context, _DimensionContributionData data, bool canEditBudgets) {
    // isDark/lightTextSecondary-darkTextSecondary — the app's own
    // established muted-text pattern (e.g. settings_screen.dart), since
    // AppColors has no single theme-agnostic "secondary text" constant.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sortedEntities = [...data.entities]..sort((a, b) {
        final cmp = switch (_contribSortColumn) {
          0 => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
          1 => a.budgetTotal.compareTo(b.budgetTotal),
          _ => a.forecastTotal.compareTo(b.forecastTotal),
        };
        return _contribSortAscending ? cmp : -cmp;
      });
    void onSort(int column, bool ascending) => setState(() {
          _contribSortColumn = column;
          _contribSortAscending = ascending;
        });
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Contribution by entity', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            "Each entity's share of this dimension's total Sales Budget and Seasonal Forecast. "
            'Filter by an entity above to view or edit its own figures.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ResponsiveDataTable(
              sortColumnIndex: _contribSortColumn,
              sortAscending: _contribSortAscending,
              columns: [
                DataColumn2(label: const Text('Entity'), onSort: onSort, fixedWidth: 340),
                DataColumn(label: const Text('Sales Budget'), numeric: true, onSort: onSort),
                DataColumn(label: const Text('Seasonal Forecast'), numeric: true, onSort: onSort),
              ],
              rows: [
                for (final e in sortedEntities)
                  DataRow(
                    onSelectChanged: (_) => applyRowCrossFilters(
                      ref,
                      dimensions: {widget.dimension: FilterSelection(e.code, e.label)},
                    ),
                    cells: [
                      DataCell(Text(e.label, maxLines: 2, overflow: TextOverflow.ellipsis)),
                      DataCell(Text(_formatContributionPct(e.budgetTotal, data.budgetGrandTotal))),
                      DataCell(Text(_formatContributionPct(e.forecastTotal, data.forecastGrandTotal))),
                    ],
                  ),
              ],
            ),
          ),
          if (canEditBudgets) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 12),
            _buildAdjustByPercent(context, data),
          ],
        ],
      ),
    );
  }

  /// 2026-09-30, Craig: "The budget apportion works well. How would your
  /// recommend increasing or decreasing a dimension budget?... what if we
  /// wanted to say increase or decrease only a single dimension budget by a
  /// % across it's entities." Sits directly below the Contribution-by-
  /// entity table above, scoped to the dimension currently showing —
  /// applies to every entity in `widget.dimension` at once, for all 12
  /// fiscal months (Craig's confirmed choice: whole year, not a month
  /// range — see `BudgetRepository.scaleDimensionBudget`'s own doc
  /// comment). Deliberately never shown for Company: `_loadEntities`
  /// already routes Company straight to its own single-entity month table
  /// (see that method's own doc comment), so this summary — and this
  /// control — is never reachable for that dimension; Company only ever
  /// goes through the apportion dialog on `_MonthTable` instead, which is
  /// the only place Company Budget itself can be changed.
  ///
  /// Requires typing an explicit % and pressing Apply, which then shows a
  /// before/after TOTAL preview in a confirm dialog before anything is
  /// written (Craig's confirmed choice — unlike the Company apportion
  /// dialog, which applies immediately once confirmed with no numeric
  /// preview, because there the "before" figure is just whatever was typed
  /// into Company's own field a moment earlier and already visible on
  /// screen; here the admin hasn't seen a total for the OTHER entities
  /// being changed, so showing one first is what makes the confirmation
  /// meaningful rather than a blind "Yes").
  Widget _buildAdjustByPercent(BuildContext context, _DimensionContributionData data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Adjust budget by %', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          "Scales every entity's Sales Budget in this dimension by the same % — "
          "across all 12 months, and always for this dimension only.",
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary,
              ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 120,
              child: TextField(
                controller: _scalePercentController,
                enabled: !_scaling,
                keyboardType: TextInputType.numberWithOptions(signed: true, decimal: true),
                // Allows a leading "-" and decimals (e.g. "-12.5") — unlike
                // _ThousandsInputFormatter above, this is a small signed %,
                // not a comma-grouped Rand value, so that formatter doesn't
                // apply here.
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.\-]'))],
                decoration: const InputDecoration(isDense: true, suffixText: '%', hintText: 'e.g. 10 or -15'),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 36,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _scaling ? null : () => _confirmAndApplyScale(context, data),
                icon: _scaling
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.percent, size: 16),
                label: Text(_scaling ? 'Applying…' : 'Apply'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Parses `_scalePercentController`'s text, shows the before/after TOTAL
  /// preview dialog, and — only once confirmed — actually calls
  /// `BudgetRepository.scaleDimensionBudget`. The preview total
  /// (`data.budgetGrandTotal * (1 + percent/100)`) is a client-side
  /// approximation for display purposes only: it multiplies the DIMENSION'S
  /// total the same way the server scales each entity's own row, so it
  /// matches exactly except in the edge case where the % is a decrease so
  /// large (beyond -100%) that one or more individual entities would go
  /// negative — the server floors each of THOSE rows at 0 individually
  /// (see the migration's own comment), which this simple total-level
  /// multiply doesn't model. Not worth the extra round-trip to compute
  /// exactly for what's just a confirmation preview; the actual write is
  /// always the server's own per-row math, never this estimate.
  Future<void> _confirmAndApplyScale(BuildContext context, _DimensionContributionData data) async {
    final text = _scalePercentController.text.trim();
    if (text.isEmpty) return;
    final percent = num.tryParse(text);
    if (percent == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a number, e.g. 10 or -15.')),
      );
      return;
    }

    final currentTotal = data.budgetGrandTotal;
    final previewTotal = (currentTotal * (1 + percent / 100)).clamp(0, double.infinity);
    final entityCount = data.entities.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Adjust budget by %?'),
        content: Text(
          'Apply a ${percent > 0 ? '+' : ''}$percent% change to the Sales Budget of every '
          'entity in this dimension ($entityCount ${entityCount == 1 ? 'entity' : 'entities'}), '
          'across all 12 months?\n\n'
          'Current total: ${formatRand(currentTotal)}\n'
          'New total: ${formatRand(previewTotal)}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Apply')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _scaling = true);
    try {
      final rowsWritten = await ref
          .read(budgetRepositoryProvider)
          .scaleDimensionBudget(dimension: widget.dimension, percent: percent);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Adjusted $rowsWritten budget figures.')));
        _scalePercentController.clear();
        setState(() => _contributionFuture = _loadContribution());
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not adjust: $e')));
      }
    } finally {
      if (mounted) setState(() => _scaling = false);
    }
  }
}

class _MonthTable extends ConsumerStatefulWidget {
  const _MonthTable({
    required this.dimension,
    required this.entityCode,
    required this.data,
    required this.canEdit,
    required this.clientId,
  });

  final String dimension;
  final String entityCode;
  final _BudgetMonthData data;
  final bool canEdit;
  final String? clientId;

  @override
  ConsumerState<_MonthTable> createState() => _MonthTableState();
}

class _MonthTableState extends ConsumerState<_MonthTable> {
  // Shared by the Sales Budget AND Seasonal Forecast DataColumn2s'
  // fixedWidth and every cell's own sizing in those columns (month rows and
  // the Total row alike) — see the fixedWidth columns' own doc comment for
  // why this needs to be one single source of truth rather than several
  // places independently guessing the same number.
  //
  // 2026-09-28, Craig, after seeing the % contribution figures split into
  // their own extra columns: "I meant go with your suggestion to reduce
  // the columns" — folded back into the Sales Budget/Seasonal Forecast
  // cells themselves as trailing text on the SAME line, rather than as
  // separate columns. Widened from 150 to fit that: "591,080" alone needed
  // ~150px, but "R 591,080  (38%)" needs a bit more room alongside it —
  // still comfortably inside one line (see `_pctSuffix`; the quarter %
  // that used to also live here moved to its own `_quarterDividerRow`,
  // 2026-09-22).
  static const double _budgetColumnWidth = 260;

  late final Map<String, TextEditingController> _controllers;

  /// A mutable working copy of `widget.data.budget` (`_BudgetMonthData` is
  /// itself immutable — `widget.data` never changes after this table's
  /// entity is picked, since nothing refetches it until the admin leaves
  /// and re-selects) — see `_saveMonth`'s own comment for why this exists:
  /// it's what every total/% figure below is actually computed FROM now,
  /// specifically so those figures can be updated the moment a save
  /// succeeds rather than only after a full reload.
  late Map<String, num> _budgetValues;

  // Computed once at mount, same as ytd_comparative_screen.dart's
  // _fiscalYears — this table's row/column ORDER is display-only (every
  // lookup below is keyed by the calendar month label itself, e.g.
  // _budgetValues[month], so a different rotation never changes which
  // value a row shows, only which row it shows first).
  late final List<String> _months;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _months = fiscalMonthOrderFor(startMonth: ref.read(fiscalYearStartMonthProvider).valueOrNull ?? 3);
    _budgetValues = Map.of(widget.data.budget);
    _controllers = {
      for (final month in _months)
        // Comma-grouped from the start (e.g. "591,080") to match what
        // _ThousandsInputFormatter keeps it as on every subsequent keystroke
        // — see that class's own doc comment.
        month: TextEditingController(text: _ThousandsInputFormatter._format.format(_budgetValues[month] ?? 0)),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Parses one month's current field text back into a plain number and
  /// upserts it — no snackbar of its own; `_saveAll` below is the only
  /// user-facing entry point now (see its doc comment for why).
  ///
  /// Strips only commas, not every non-digit character. The previous
  /// version of this method used `replaceAll(RegExp(r'[^\d]'), '')`, which
  /// strips a decimal point right along with the thousands commas — safe
  /// only as long as a "." could never appear in this field at all. That
  /// assumption briefly didn't hold: for the short window today between
  /// this field first getting comma-formatted and `_ThousandsInputFormatter`
  /// being fixed to force whole-Rand display, a pre-existing row with real
  /// cents (e.g. 591080.13) would render here as "591,080.13" — and hitting
  /// Enter on it with the old digit-stripping would have silently saved
  /// 59108013, not 591080.13 or even 591080, mashing the whole and
  /// fractional parts together into a number two orders of magnitude too
  /// large. Not reachable any more now that `_ThousandsInputFormatter`
  /// never lets a "." into this field's text in the first place (see its
  /// own doc comment) — fixed properly here anyway rather than left as a
  /// latent trap for the next thing that touches this method.
  ///
  /// 2026-09-22, Craig: "when you insert a Sales Budget it does not sum and
  /// update. You have to go out of the screen and then when you go back in
  /// it displays." Root cause: every total/% figure in this table is
  /// computed from `_budgetValues` (previously read straight from
  /// `widget.data.budget`, the snapshot fetched once when the entity was
  /// selected — see that field's own doc comment), and nothing ever wrote
  /// this month's freshly-saved value back into it after a successful save;
  /// only leaving and re-selecting the entity re-fetched a fresh snapshot
  /// and so happened to pick the new value up. Updating `_budgetValues`
  /// here, right after the write actually succeeds (not optimistically
  /// before it), means `_saveAll`'s own `setState` at the end of the batch
  /// (see its doc comment) now rebuilds with figures that already reflect
  /// every month just saved, with no extra round-trip back to Supabase to
  /// re-fetch numbers this screen already has.
  Future<void> _saveMonth(String month, String clientId) async {
    final text = _controllers[month]!.text.replaceAll(',', '');
    final parsed = text.isEmpty ? 0 : num.tryParse(text);
    if (parsed == null) return;
    await ref.read(budgetRepositoryProvider).setBudgetValue(
          clientId: clientId,
          dimension: widget.dimension,
          entityCode: widget.entityCode,
          fiscalMonth: month,
          budgetValue: parsed,
        );
    _budgetValues[month] = parsed;
  }

  /// 2026-09-01, Craig: "you have to input a budget number then enter for
  /// it to save before inputting the next one. If you input more than one
  /// at a time it only saves the last when. What about a Save button.
  /// Change all and press Save." The old design saved a field the instant
  /// the admin hit Enter (or otherwise submitted) on it — meaning every
  /// OTHER field they'd already typed into during the same visit, but not
  /// yet individually submitted, was silently never persisted. Replaced
  /// with one explicit Save button that saves every month in this table in
  /// a single batch; each field's own `onSubmitted` now just advances focus
  /// to the next one (Enter to tab through quickly) instead of saving on
  /// its own — matching "fill several in, then press Save" rather than
  /// pretending each field commits independently as you go.
  Future<void> _saveAll() async {
    final clientId = widget.clientId;
    if (clientId == null || _saving) return;
    setState(() => _saving = true);
    try {
      await Future.wait(_months.map((month) => _saveMonth(month, clientId)));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sales Budget saved.')));
      }
      // Company only (2026-09-30, Craig — see BudgetRepository.
      // apportionCompanyBudget's own doc comment for the full mechanics).
      // Deliberately after the snackbar above, not instead of it — Company's
      // own save already succeeded and is worth confirming on its own,
      // independently of whatever the admin decides on this dialog.
      if (widget.dimension == 'company' && mounted) {
        await _promptApportionCompanyBudget();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Asks whether to push the Company Budget just saved down through every
  /// other dimension's entities, weighted by each entity's own share of
  /// that month's Seasonal Forecast (per-month, not a flat annual %, and
  /// always a full overwrite — both Craig's explicit choices, 2026-09-30;
  /// see `fn_apportion_company_budget`'s migration comment for why). A "No"
  /// leaves every entity's own budget exactly as it was — Company's figure
  /// is still saved either way, this only controls whether it also
  /// cascades down.
  Future<void> _promptApportionCompanyBudget() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Apportion Company Budget?'),
        content: const Text(
          'Apportion the Company Budget across all Dimensions and Entities, '
          "according to each entity's Seasonal Forecast contribution for that month? "
          'This replaces any existing budget already entered for those entities. '
          '(Saving a Company Budget of 0 and apportioning reverses everything back out.)',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Yes')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final rowsWritten = await ref.read(budgetRepositoryProvider).apportionCompanyBudget();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Apportioned to $rowsWritten entity/month figures.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not apportion: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Sum of every fiscal month's value in `series` — the denominator for
  /// `_pctOf` below, and what the (unchanged) Totals row already sums
  /// separately for the Sales Budget/Seasonal Forecast columns themselves.
  num _annualTotal(Map<String, num> series) => _months.fold<num>(0, (sum, m) => sum + (series[m] ?? 0));

  /// Sum of the 3 fiscal months making up quarter `quarterIndex` (0=Q1 ..
  /// 3=Q4) — `_months` is already in fiscal order (`fiscalMonthOrderFor`),
  /// so a quarter is just the next unclaimed run of 3, same grouping
  /// `fiscalMonthsInQuarter` uses elsewhere, without needing to resolve a
  /// quarter LABEL here (this table has no quarter/month granularity toggle
  /// to serve — every row already IS one month).
  num _quarterTotal(Map<String, num> series, int quarterIndex) {
    num sum = 0;
    for (var i = quarterIndex * 3; i < quarterIndex * 3 + 3 && i < _months.length; i++) {
      sum += series[_months[i]] ?? 0;
    }
    return sum;
  }

  /// 2026-09-28, Craig: "on the right of each number can you show the % of
  /// contribution and on the right of that the contribution per quarter."
  /// Shared by both the Sales Budget and Seasonal Forecast columns — each
  /// has its own total, so a month's Budget % and Forecast % can genuinely
  /// differ even though they're computed the same way. Whole numbers, not
  /// decimals — this is a quick at-a-glance annotation in an already dense
  /// row, not a figure anyone needs to the tenth of a percent. "—" rather
  /// than a division-by-zero when nothing's been entered/forecast for the
  /// whole year yet.
  String _pctOf(num value, num total) => total == 0 ? '—' : '${(value / total * 100).round()}%';

  /// "(38%)" — a month's own share of its column's annual total, appended
  /// after a Sales Budget/Seasonal Forecast figure on the SAME line (Craig,
  /// 2026-09-28: "on the right of each number can you show the % of
  /// contribution").
  String _pctSuffix(num value, num total) => '(${_pctOf(value, total)})';

  /// Text colour for a Seasonal Forecast figure, by its own month's
  /// confidence tier — 2026-09-28, Craig: "remove this column and rather
  /// colour code the numbers. Red = Low; Amber = Partial and Green = Full."
  /// Reuses `AppColors.negative`/`caution`/`positive` rather than new
  /// colours — see this file's own new import: those three already exist
  /// specifically for "positive/negative GP%, over/under budget, forecast
  /// confidence" (app_theme.dart's own doc comment lists forecast
  /// confidence by name), just unused for that third purpose until now.
  /// Null (default text colour) for a month with no forecast at all — see
  /// `_legend` below for what the three colours mean, now that the
  /// Confidence column itself is gone.
  Color? _confidenceColor(String? confidence) {
    switch (confidence) {
      case 'low':
        return AppColors.negative;
      case 'partial':
        return AppColors.caution;
      case 'full':
        return AppColors.positive;
      default:
        return null;
    }
  }

  /// One divider row per quarter, inserted right after that quarter's 3rd
  /// month — Craig, 2026-09-22 (screenshot of the previous "Q1 14%" repeated
  /// on all 3 of Q1's months): "remove the Quarter numbers from where they
  /// are now and insert horizontal lines dividing the quarters and then
  /// insert the quarter % between each line in the middle." `data_table_2`
  /// has no cell-merging/rowspan (confirmed against its own README's "Known
  /// issues/limitations" list), so this is a real, ordinary `DataRow` of its
  /// own rather than a literal spanning cell — each of its 3 cells draws a
  /// thin top+bottom border (`Theme.dividerColor`, the same colour Flutter's
  /// own stock row dividers already use elsewhere in this table, just drawn
  /// deliberately here rather than left to chance) that lines up across the
  /// row width into what reads as one line above and one line below,
  /// exactly the "between each line" Craig described — with the quarter's
  /// own % centred in the Sales Budget/Seasonal Forecast cells, and just the
  /// quarter's label (e.g. "Q1") centred under Month, so the label isn't
  /// needlessly repeated across all 3 cells of this one row.
  DataRow _quarterDividerRow({
    required int quarterIndex,
    required num budgetTotal,
    required num budgetQuarterTotal,
    required num forecastTotal,
    required num forecastQuarterTotal,
  }) {
    final quarterLabel =
        quarterIndex >= 0 && quarterIndex < fiscalQuarterLabels.length ? fiscalQuarterLabels[quarterIndex] : '';
    final borderStyle = BorderSide(color: Theme.of(context).dividerColor);
    final textStyle = Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic);
    Widget cell(String text) => Container(
          width: double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(border: Border.symmetric(horizontal: borderStyle)),
          child: Text(text, style: textStyle),
        );
    return DataRow(cells: [
      DataCell(cell(quarterLabel)),
      DataCell(cell(_pctOf(budgetQuarterTotal, budgetTotal))),
      DataCell(cell(_pctOf(forecastQuarterTotal, forecastTotal))),
    ]);
  }

  /// The 12 month rows, with a `_quarterDividerRow` inserted after every
  /// 3rd one — an ordinary imperative loop rather than `_months.map(...)`
  /// (what this used to be) specifically so a row can be ADDED in between,
  /// which a 1:1 `.map` over months can't do. Factored out of `build()`
  /// itself once the divider row made it a genuinely separate concern from
  /// laying out the table shell around it (columns, Totals row, legend,
  /// Save button) — same reasoning as `_totalsRow`/`_legend` already being
  /// their own methods rather than inlined into `build()`.
  List<DataRow> _monthRows({
    required num budgetTotal,
    required num forecastTotal,
    required List<num> budgetQuarterTotals,
    required List<num> forecastQuarterTotals,
  }) {
    final rows = <DataRow>[];
    for (var i = 0; i < _months.length; i++) {
      final month = _months[i];
      final quarterIndex = i ~/ 3;
      final budgetSuffix = _pctSuffix(_budgetValues[month] ?? 0, budgetTotal);
      final forecastSuffix = _pctSuffix(widget.data.forecast[month] ?? 0, forecastTotal);
      rows.add(DataRow(cells: [
        DataCell(Text(month)),
        DataCell(
          widget.canEdit
              ? SizedBox(
                  width: _budgetColumnWidth,
                  // The % suffix sits to the right of the editable field
                  // itself, inside this same cell — Row +
                  // mainAxisAlignment.end rather than a bare
                  // `Align(centerRight)` wrapper, since there's now a
                  // second, non-editable widget sharing the cell with the
                  // TextField. The TextField keeps its own `textAlign:
                  // TextAlign.right` and zero horizontal content padding
                  // from before (see its own comment, below) — those
                  // digits' alignment with the Total row is unaffected;
                  // what changed is only that the Total row's own cell
                  // (see `_totalsRow`) sits at the right edge of the same
                  // `_budgetColumnWidth`-wide box, not that its digits
                  // align with the TextField's digits specifically
                  // anymore, now that the field no longer stretches to
                  // fill the whole cell.
                  //
                  // 2026-09-22, Craig, screenshot with the "Sales Budget"
                  // header and the Totals row's "R 0" both arrowed: the
                  // whole TextField+suffix group was landing hard against
                  // the LEFT of this cell, while the header ("Sales
                  // Budget", right-aligned — `numeric: true` on its
                  // `DataColumn2`) and the Totals row's own total (its own
                  // `Align(centerRight)`, see `_totalsRow`) both sit at the
                  // RIGHT edge — three different alignments in one column.
                  // Root cause: `Expanded` always claims every pixel of
                  // free space in a `Row` regardless of
                  // `mainAxisAlignment`, so the suffix `Text` was filling
                  // the whole space left over after the TextField rather
                  // than sizing to its own text — which left `end`
                  // nothing to actually push against, so the TextField+
                  // suffix pair stayed pinned to the left. `Flexible`
                  // (its default, loose fit) below sizes to the suffix
                  // text's own width instead of forcing it to fill,
                  // `overflow`/`maxLines` on the `Text` still protect
                  // against a suffix too long to fit — so now
                  // `mainAxisAlignment: MainAxisAlignment.end` has real
                  // slack to push the whole group flush right, lining up
                  // with the header and the Total exactly as intended.
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(
                        width: 130,
                        child: TextField(
                          controller: _controllers[month],
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.right,
                          inputFormatters: [_ThousandsInputFormatter()],
                          // 2026-09-01, Craig: "The Total is still not
                          // aligned" even after the fixedWidth column
                          // (attempt #3). The width WAS already identical
                          // between this cell and the Total cell below by
                          // that point — what wasn't identical is that a
                          // bare `TextField` doesn't shrink to its text
                          // like a `Text` widget does: it fills the whole
                          // box it's given, and then draws its digits
                          // inset from that box's right edge by
                          // `InputDecoration.contentPadding` (Material's
                          // default is non-zero even with `isDense: true`
                          // — it only shrinks the vertical padding, not
                          // the horizontal). Zeroing the horizontal
                          // content padding here removes that inset.
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 8),
                            prefixText: 'R ',
                          ),
                          // No longer saves on its own — see _saveAll's
                          // doc comment. Enter now just moves to the next
                          // field, so typing Enter->Enter->Enter tabs
                          // straight down the column while filling
                          // several months in before pressing Save.
                          onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          budgetSuffix,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                )
              : Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${formatRand(_budgetValues[month])}  $budgetSuffix',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
        ),
        DataCell(
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${formatRand(widget.data.forecast[month])}  $forecastSuffix',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(color: _confidenceColor(widget.data.confidence[month])),
            ),
          ),
        ),
      ]));
      // Divider row after the 3rd month of every quarter (i % 3 == 2) —
      // see `_quarterDividerRow`'s own doc comment for why this replaces
      // repeating the quarter % on all 3 months.
      if (i % 3 == 2) {
        rows.add(_quarterDividerRow(
          quarterIndex: quarterIndex,
          budgetTotal: budgetTotal,
          budgetQuarterTotal: budgetQuarterTotals[quarterIndex],
          forecastTotal: forecastTotal,
          forecastQuarterTotal: forecastQuarterTotals[quarterIndex],
        ));
      }
    }
    return rows;
  }

  /// 2026-09-28, Craig: "Include a legend at the bottom explaining this."
  /// Explains what the Seasonal Forecast column's text colour means, now
  /// that the Confidence column itself is gone — one dot + label per tier,
  /// same order/wording as `compute-forecast`'s own three-tier scheme
  /// (schema/041, <12 months history = low, 12-23 = partial, 24+ = full)
  /// rather than re-deriving the thresholds here.
  ///
  /// 2026-09-22, Craig: "I know that each person is going to ask me how the
  /// Seasonal Forecast Numbers are calculated. As such I would like a
  /// Button / Hover... that explains in layman terms exactly how Holt
  /// Winters Forecasts are calculated." The `_helpButton` added to this
  /// same row is both: a `Tooltip` (shows on hover on desktop/web, and on
  /// long-press on touch — no separate "hover" mechanism needed) carrying a
  /// one-line teaser, wrapping a small tappable button that opens the full
  /// explanation via `_showForecastExplanation` — same `showDialog`/
  /// `AlertDialog` pattern already used elsewhere in this app (e.g.
  /// `global_filter_bar.dart`'s "Presets" button) rather than a new
  /// mechanism.
  Widget _legend() {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Forecast confidence:', style: textStyle),
        _legendEntry(AppColors.negative, 'Low', textStyle),
        _legendEntry(AppColors.caution, 'Partial', textStyle),
        _legendEntry(AppColors.positive, 'Full', textStyle),
        _helpButton(),
      ],
    );
  }

  Widget _legendEntry(Color color, String label, TextStyle? textStyle) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: textStyle),
      ],
    );
  }

  Widget _helpButton() {
    return Tooltip(
      message: 'How the Seasonal Forecast numbers are calculated',
      child: TextButton.icon(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 24),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: _showForecastExplanation,
        icon: const Icon(Icons.help_outline, size: 14),
        label: const Text('How is this calculated?'),
      ),
    );
  }

  /// The actual layman's-terms explanation — written from, and meant to
  /// stay in sync with, `supabase/functions/compute-forecast/index.ts`'s
  /// real logic (not a generic description of Holt-Winters off the shelf):
  /// the 3 confidence thresholds (`partial_history_months`/
  /// `full_history_months`, defaults 12/24 — `DEFAULT_SETTINGS`), the Tier
  /// 3 "not enough history" flat-average fallback for Low, and the
  /// 2026-09-21 robustness fixes (median year-seeding, the symmetric
  /// deseasonalized cap/floor) described here in plain terms as "protection
  /// against one freak month" without the underlying algorithm's own
  /// jargon. If `compute-forecast`'s thresholds or safeguards ever change,
  /// this text needs updating alongside it — it's describing that specific
  /// function, not general forecasting theory.
  ///
  /// 2026-09-22, Craig: "The Sales Budget overrides the Seasonal Forecast.
  /// If you can put this into the explanation in the right words as well
  /// please." The closing paragraph now says so — grounded in
  /// `core/utils/target_overlay.dart`'s `resolveTarget`, which mirrors
  /// schema/021's own `coalesce(nullif(budget_value, 0), forecast_value)`:
  /// everywhere else this app shows a "Target" (Dashboard, Sales Analysis,
  /// Performance), a month with a real entered Sales Budget uses that
  /// figure; the Seasonal Forecast is only ever the fallback for a month
  /// left blank (or 0, which `resolveTarget` treats as "not entered" too —
  /// same reasoning as `budget_value`'s own `not null default 0`).
  void _showForecastExplanation() {
    final theme = Theme.of(context);
    Widget paragraph(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(text),
        );
    Widget tier(Color color, String label, String detail) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: theme.textTheme.bodyMedium,
                    children: [
                      TextSpan(text: '$label — ', style: const TextStyle(fontWeight: FontWeight.w600)),
                      TextSpan(text: detail),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('How the Seasonal Forecast is calculated'),
        // ConstrainedBox with a maxWidth, not a fixed-width SizedBox — a
        // literal `SizedBox(width: 480)` would force that width even on a
        // phone screen narrower than 480px plus the dialog's own insets,
        // which is exactly the RenderFlex-overflow bug class already fixed
        // elsewhere this engagement (platform_admin_screen.dart's
        // _dialogHeader). maxWidth is a ceiling, not a floor — it only caps
        // how wide this gets on a large screen, and lets it shrink freely
        // below that on a narrow one.
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                paragraph(
                  'The Seasonal Forecast isn\'t a target anyone sets — it\'s a '
                  'prediction, worked out automatically from this entity\'s own '
                  'real sales history using a well-established forecasting '
                  'method called Holt-Winters.',
                ),
                paragraph('It blends three things:'),
                paragraph(
                  '• How much this entity normally sells right now — a running '
                  'average that keeps adjusting as new sales come in.',
                ),
                paragraph(
                  '• Whether sales have generally been climbing or declining '
                  'over the past year or two.',
                ),
                paragraph(
                  '• The repeating pattern of busier and quieter months through '
                  'the year — a December spike or a January dip, for example — '
                  'compared to what\'s typical for THIS entity, not judged '
                  'against anyone else\'s numbers.',
                ),
                paragraph(
                  'Those three are combined and rolled forward a month at a '
                  'time to produce the next 12 months, and the whole thing '
                  'recalculates automatically every day as new sales land — '
                  'nobody needs to maintain or adjust it by hand.',
                ),
                paragraph(
                  'It also has built-in protection against a single freak '
                  'month — one unusually huge sale, or one large credit note '
                  '— throwing off the rest of the year\'s forecast.',
                ),
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('How much to trust it depends on how much sales history exists:', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                tier(
                  AppColors.negative,
                  'Low',
                  'Under 12 months of history. Not enough to know this entity\'s '
                  'seasonal pattern yet, so it\'s simply the recent average '
                  'repeated across all 12 months — treat this one as a rough '
                  'placeholder.',
                ),
                tier(
                  AppColors.caution,
                  'Partial',
                  '12 to 23 months of history. A genuine forecast with a real '
                  'seasonal pattern, but only one year to have learned that '
                  'pattern from.',
                ),
                tier(
                  AppColors.positive,
                  'Full',
                  '24 months or more. Two full years or more to work from, so '
                  'both the seasonal pattern and the underlying trend are '
                  'well established.',
                ),
                paragraph(
                  'This is separate from the Sales Budget column alongside it, '
                  'which is a target entered manually — the Seasonal Forecast '
                  'is calculated, not typed in. But the two aren\'t independent: '
                  'wherever this app shows a "Target" elsewhere — the Dashboard, '
                  'Sales Analysis, Performance — it uses the Sales Budget for any '
                  'month that has one entered. The Seasonal Forecast only steps '
                  'in to fill a month that\'s been left blank.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Got it')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Deliberately no row-click cross-filter here either (2026-09-08, see
    // `applyRowCrossFilters`'s own doc comment, core/filters/
    // global_filters.dart, for the app-wide feature this screen is the one
    // exception to) — `ResponsiveDataTable`'s new "tap anywhere in a row
    // with onSelectChanged set" mechanism relies on `showCheckboxColumn:
    // false` making every DataCell itself tappable, and this table's Sales
    // Budget column is a live `TextField` an admin needs to tap INTO to
    // edit — wiring a row-level tap handler on top of that risks stealing
    // focus or misfiring on every edit tap, exactly the kind of thing this
    // screen's existing "no onSort here either" call already guards
    // against for a similar reason (see that comment, just below). Rows
    // with no `onSelectChanged` (every row in this table) stay completely
    // inert either way, so this table is entirely unaffected by
    // `showCheckboxColumn: false` being set globally in
    // `ResponsiveDataTable` now.
    //
    // No onSort here, deliberately — unlike every other table in the app,
    // this one is an editable grid where the row order (fiscal month, Mar ->
    // Feb) IS the meaningful, expected order for entering a budget, and each
    // row holds a live TextEditingController; letting rows jump around
    // under a half-typed value seemed like the wrong trade for a "sort by
    // column" feature nobody's likely to reach for on a 12-row form.
    // Flagged back to Craig rather than silently applied — happy to add it
    // if it turns out to be wanted here too.
    //
    // stickyHeader: false — 2026-08-27, the rest of the app's tables got a
    // frozen header (+ frozen Totals row where they have one) via
    // ResponsiveDataTable, now backed by the data_table_2 package (Craig:
    // "lock the Headers and Totals so we don't lose them when scrolling
    // down"). This table opts out — not because of any technical
    // constraint (data_table_2 renders the row list once, so the earlier
    // hand-rolled version's "two simultaneously-mounted TextField
    // controllers" hazard doesn't apply here any more), but because this
    // table's Totals row deliberately stays at the BOTTOM, unpinned
    // (Wyzesales_Rebuild_Decisions.md Section 22b: Budgets was never
    // included in the "Totals to the top" scope Craig confirmed for the
    // other tables). A frozen HEADER alone would be safe to add here today
    // if wanted — flagged as an easy follow-up, not applied unasked.
    //
    // Computed once here rather than per row — every month's contribution
    // % shares the same annual/quarterly totals, and (unlike the Sales
    // Budget/Seasonal Forecast figures themselves) none of this depends on
    // anything that changes mid-edit, so there's no reason to recompute it
    // 12 times over.
    final budgetTotal = _annualTotal(_budgetValues);
    final forecastTotal = _annualTotal(widget.data.forecast);
    final budgetQuarterTotals = [for (var q = 0; q < 4; q++) _quarterTotal(_budgetValues, q)];
    final forecastQuarterTotals = [for (var q = 0; q < 4; q++) _quarterTotal(widget.data.forecast, q)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ResponsiveDataTable(
            stickyHeader: false,
            columns: const [
              DataColumn(label: Text('Month')),
              // 2026-09-01, Craig, after TWO attempts at this via `Align`
              // still didn't line the input boxes up with the Total below
              // them: a plain (non-fixed-width) `DataColumn` lets
              // `data_table_2` decide how wide the column actually renders
              // (stretched to fill available space, per
              // `ResponsiveDataTable`'s own doc comment) — and there was no
              // way to be certain from here whether a `TextField`-holding
              // cell and a plain-`Text` cell resolve that stretched width
              // (and any internal cell padding) identically. Rather than
              // guess a third time, `DataColumn2(fixedWidth: ...)` (a
              // `data_table_2` extension already available via
              // `pubspec.yaml`, just not previously used anywhere in this
              // app) pins this ONE column to an exact, known pixel width —
              // removing the ambiguity outright instead of reasoning about
              // it. `_budgetColumnWidth` below is shared by both this
              // column and every cell's own `SizedBox` in it, so the
              // aligning container is provably identical, not just
              // presumed to be, between the input rows and the Total row.
              DataColumn2(label: Text('Sales Budget'), numeric: true, fixedWidth: _budgetColumnWidth),
              // 2026-09-28, Craig: "remove this column and rather colour
              // code the numbers" — the Confidence column is gone; its
              // information now lives entirely in this cell's own text
              // colour (`_confidenceColor`) instead of a separate column.
              // Also fixedWidth now (previously a plain stretched
              // `DataColumn`) — see `_budgetColumnWidth`'s own doc comment;
              // this cell's text got longer (the % contribution figures
              // folded in below) and needs the same known-width treatment
              // Sales Budget already had, for the same reasons.
              DataColumn2(label: Text('Seasonal Forecast'), numeric: true, fixedWidth: _budgetColumnWidth),
            ],
            rows: [
              ..._monthRows(
                budgetTotal: budgetTotal,
                forecastTotal: forecastTotal,
                budgetQuarterTotals: budgetQuarterTotals,
                forecastQuarterTotals: forecastQuarterTotals,
              ),
              _totalsRow(),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _legend(),
        if (widget.canEdit) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              height: 36,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _saving ? null : _saveAll,
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save, size: 16),
                label: Text(_saving ? 'Saving…' : 'Save'),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Bold annual total — Craig, 2026-08-26: "Can we have total for each
  /// column in each table." Sums the saved Sales Budget figures
  /// (`_budgetValues`, updated as each month is saved — see that field's
  /// and `_saveMonth`'s own doc comments; NOT `widget.data.budget`, the
  /// original fetched snapshot, which is why this used to go stale until
  /// the admin left and re-entered the screen), not each field's live
  /// unsaved text — this table doesn't rebuild on every keystroke (only on
  /// save), so a total sourced from the text controllers directly would
  /// just as often show a half-typed figure as a genuinely saved one;
  /// summing the saved values is the one source that's always accurate for
  /// what's actually been recorded. The annual % contribution figures
  /// (folded into the Sales Budget/Seasonal Forecast cells themselves —
  /// see `_pctSuffix`) have no meaningful value for the Total row itself,
  /// so this row's own two cells stay plain totals with no trailing
  /// suffix.
  DataRow _totalsRow() {
    final totalBudget = _months.fold<num>(0, (sum, month) => sum + (_budgetValues[month] ?? 0));
    final totalForecast = _months.fold<num>(0, (sum, month) => sum + (widget.data.forecast[month] ?? 0));
    const style = TextStyle(fontWeight: FontWeight.bold);
    return DataRow(cells: [
      const DataCell(Text('Total', style: style)),
      // 2026-09-01, Craig: two rounds of `Align`-based fixes on this column
      // still didn't line the Total up with the input boxes above it —
      // reasoning about how `data_table_2` was passing width down to each
      // cell wasn't getting anywhere, so this stopped guessing and instead
      // made the space itself unambiguous: the Sales Budget DataColumn2
      // above is now a genuinely FIXED width (`_budgetColumnWidth`), and
      // this cell uses the exact same `SizedBox(width: _budgetColumnWidth)`
      // + `Align(alignment: Alignment.centerRight)` wrapper as the per-month
      // input cell — same width, same alignment mechanism, both provably
      // identical rather than each independently trusting the table to
      // hand them the same space. The Seasonal Forecast total below now
      // gets the identical wrapper too (2026-09-28) — see its own comment.
      DataCell(
        SizedBox(
          width: _budgetColumnWidth,
          child: Align(alignment: Alignment.centerRight, child: Text(formatRand(totalBudget), style: style)),
        ),
      ),
      // No "% of total" for the Total row itself — a total's contribution
      // to itself is always 100%, not a figure worth printing. Seasonal
      // Forecast total gets the same SizedBox+Align treatment as Sales
      // Budget's now (2026-09-28) — both columns are fixedWidth
      // `_budgetColumnWidth` for the first time (previously this one alone
      // needed it, since it was the only editable-field column), so both
      // total cells now size and right-align the exact same way.
      DataCell(
        SizedBox(
          width: _budgetColumnWidth,
          child: Align(alignment: Alignment.centerRight, child: Text(formatRand(totalForecast), style: style)),
        ),
      ),
    ]);
  }
}
