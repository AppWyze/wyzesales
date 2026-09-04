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
class GlobalFilters {
  final FilterSelection? salesPerson;
  final FilterSelection? category;
  final FilterSelection? customer;
  final FilterSelection? item;
  final FilterSelection? branch;
  final int? fiscalYear;
  final String? fiscalMonth; // 'Mar'..'Feb'

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
    this.salesPerson,
    this.category,
    this.customer,
    this.item,
    this.branch,
    this.fiscalYear,
    this.fiscalMonth,
    this.document,
  });

  bool get isEmpty =>
      salesPerson == null &&
      category == null &&
      customer == null &&
      item == null &&
      branch == null &&
      fiscalYear == null &&
      fiscalMonth == null &&
      document == null;

  int get activeCount =>
      [salesPerson, category, customer, item, branch, fiscalYear, fiscalMonth, document].where((v) => v != null).length;

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
      // 2026-09-02: `company` has no field of its own here at all — see
      // `SalesDimension.filterable`'s doc comment (fiscal.dart) for why it's
      // never actually offered anywhere a global filter TARGET is picked
      // (GlobalFilterBar, the top-bar entity search). This arm only exists
      // to satisfy the switch's exhaustiveness check and should never
      // actually be reached.
      case SalesDimension.company:
        return null;
    }
  }

  /// `_unset` sentinel lets a field be explicitly set to null (clearing it)
  /// while every other field keeps its current value — a plain `copyWith`
  /// with nullable named params can't tell "leave unchanged" apart from
  /// "set to null" otherwise.
  GlobalFilters copyWith({
    Object? salesPerson = _unset,
    Object? category = _unset,
    Object? customer = _unset,
    Object? item = _unset,
    Object? branch = _unset,
    Object? fiscalYear = _unset,
    Object? fiscalMonth = _unset,
    Object? document = _unset,
  }) {
    return GlobalFilters(
      salesPerson: identical(salesPerson, _unset) ? this.salesPerson : salesPerson as FilterSelection?,
      category: identical(category, _unset) ? this.category : category as FilterSelection?,
      customer: identical(customer, _unset) ? this.customer : customer as FilterSelection?,
      item: identical(item, _unset) ? this.item : item as FilterSelection?,
      branch: identical(branch, _unset) ? this.branch : branch as FilterSelection?,
      fiscalYear: identical(fiscalYear, _unset) ? this.fiscalYear : fiscalYear as int?,
      fiscalMonth: identical(fiscalMonth, _unset) ? this.fiscalMonth : fiscalMonth as String?,
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

  void setDimension(SalesDimension dimension, FilterSelection? selection) {
    state = switch (dimension) {
      SalesDimension.salesPerson => state.copyWith(salesPerson: selection),
      SalesDimension.category => state.copyWith(category: selection),
      SalesDimension.customer => state.copyWith(customer: selection),
      SalesDimension.item => state.copyWith(item: selection),
      SalesDimension.branch => state.copyWith(branch: selection),
      // See `forDimension`'s matching arm above — `company` is never
      // actually passed here by anything in the UI (GlobalFilterBar and the
      // top-bar search both iterate `SalesDimension.filterable`, which
      // excludes it), so this is a same-state no-op purely to satisfy
      // exhaustiveness.
      SalesDimension.company => state,
    };
  }

  void clearDimension(SalesDimension dimension) => setDimension(dimension, null);

  void setFiscalYear(int? year) => state = state.copyWith(fiscalYear: year);

  void setFiscalMonth(String? month) => state = state.copyWith(fiscalMonth: month);

  void setDocument(String? document) => state = state.copyWith(document: document);

  void clearAll() => state = const GlobalFilters();
}

final globalFiltersProvider = StateNotifierProvider<GlobalFiltersNotifier, GlobalFilters>(
  (ref) => GlobalFiltersNotifier(ref),
);
