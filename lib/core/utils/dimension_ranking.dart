/// Which of the "Top 5 / Bottom 5 / Diminishing 5 / Growth 5" rankings a
/// dimension breakdown (Dashboard's Customer/Item/etc pie charts) is
/// currently showing. Mirrors dashboard_screen.dart's own private
/// `_RankMode` one level down — this file only needs the four cases to
/// decide "how do we rank" and "do we need last period's entities as well
/// as this period's," not the UI label each one displays as, so it isn't
/// worth sharing the enum itself across a privacy boundary.
enum DimensionRankMode { top5, bottom5, diminishing5, growth5 }

/// The up to `limit` entity codes a dimension breakdown pie should show,
/// pulled out of dashboard_screen.dart's `_pickSlices` so this ranking
/// decision is independently unit-testable — the same reason
/// `performance_rollup.dart`/`sales_coverage.dart`/`target_overlay.dart`
/// are standalone utility files rather than private State methods.
///
/// Craig, 2026-09-03, logged in as a rep with only 2 real September
/// transactions: "there are only two transactions in September so where
/// does five customers come from???" Root cause: with fewer than `limit`
/// entities active in the CURRENT period, the pie still needed `limit`
/// slices to fill its legend, so it padded the remaining slots with
/// whichever PREVIOUS-period entities happened to sort first out of the
/// current+previous union — entities with a real August number but zero
/// September activity, shown in September's own breakdown at R0. This is
/// the same class of bug as the `current.isEmpty` fix already in
/// dashboard_screen.dart (2026-09-01, Craig: "This is incorrect as we have
/// no MTD data for September yet") — just one notch less extreme: not "we
/// have no data for this period at all" but "we have SOME, just fewer than
/// `limit` distinct entities," which that earlier fix didn't cover.
///
/// Top 5 / Bottom 5 rank entities that actually had activity THIS period —
/// they only ever draw from `current`'s own keys, so a period with 2 real
/// entities shows exactly 2 slices, never `limit` padded ones.
///
/// Diminishing 5 / Growth 5 deliberately still need the union of both
/// periods' keys — an entity with real previous-period activity and zero
/// this period is exactly the "dropped to zero" case those two modes exist
/// to surface (dashboard_screen.dart's own original comment on this: "an
/// entity that had activity last period but none this period is exactly
/// the kind of thing Diminishing 5 should be able to surface, not silently
/// omit"), not a padding artifact to exclude.
List<String> rankEntityCodes({
  required Map<String, num> current,
  required Map<String, num> previous,
  required DimensionRankMode mode,
  int limit = 5,
}) {
  if (current.isEmpty) return const [];

  num currentValue(String code) => current[code] ?? 0;
  num previousValue(String code) => previous[code] ?? 0;
  num delta(String code) => currentValue(code) - previousValue(code);

  final needsPreviousPeriodToo = mode == DimensionRankMode.diminishing5 || mode == DimensionRankMode.growth5;
  final codes = (needsPreviousPeriodToo ? <String>{...current.keys, ...previous.keys} : current.keys.toSet()).toList();

  switch (mode) {
    case DimensionRankMode.top5:
      codes.sort((a, b) => currentValue(b).compareTo(currentValue(a)));
      break;
    case DimensionRankMode.bottom5:
      codes.sort((a, b) => currentValue(a).compareTo(currentValue(b)));
      break;
    case DimensionRankMode.diminishing5:
      codes.sort((a, b) => delta(a).compareTo(delta(b))); // most negative delta (biggest decline) first
      break;
    case DimensionRankMode.growth5:
      codes.sort((a, b) => delta(b).compareTo(delta(a))); // most positive delta (biggest growth) first
      break;
  }

  return codes.take(limit).toList();
}
