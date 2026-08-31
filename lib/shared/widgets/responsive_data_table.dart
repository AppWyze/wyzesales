import 'package:flutter/material.dart';
import 'package:data_table_2/data_table_2.dart';

/// Wraps [DataTable2] (the `data_table_2` package) so every table in the app
/// gets, for free: columns that spread to fill the available width instead
/// of packing to the left with blank space after the last one (Craig,
/// 2026-08-26: "Space the data evenly eliminating white space"), a
/// persistent horizontal scrollbar once a table genuinely doesn't fit
/// (Craig, same day: "Build in a horizontal scroll bar when the data does
/// not fit into the screen horizontally"), and — the reason this file now
/// wraps a package instead of a hand-rolled `DataTable` — a frozen header
/// plus frozen leading rows while the rest of the table scrolls (Craig,
/// 2026-08-27: "lock the Headers and Totals so we don't lose them when
/// scrolling down").
///
/// **History — why this isn't hand-rolled.** The first three attempts at
/// "lock the Headers and Totals" were a from-scratch rewrite of this file:
/// build the header/Totals row into one clipped, never-scrolled `DataTable`,
/// and the rest into a second `DataTable` shifted up inside its own
/// scrollable, with both built from identical inputs so their column widths
/// would agree. All three shipped, and all three crashed on Craig's actual
/// device in three different ways this sandbox had no way to catch first
/// (there is no Flutter runtime here — every layout change this whole
/// engagement has shipped unverified until Craig runs it):
///   1. `mouse_tracker.dart` assertion — the hidden, permanently-clipped
///      copy of the header still carried real `onSort` callbacks it could
///      never actually be clicked through, so `DataTable` wrapped it in the
///      same live, hoverable `InkWell`/`MouseRegion` as the genuinely
///      visible copy: two simultaneously-mounted sort-arrow regions for
///      every sortable column, one of them invisible.
///   2. `RenderConstrainedOverflowBox... given an infinite size` — the
///      `OverflowBox`es used to let each table overflow its clipped box
///      inherited an unbounded width from the horizontal scrollview several
///      widgets up (deliberate there, so a wide table can scroll sideways),
///      and `OverflowBox`'s own reported size tracks that incoming max — an
///      unbounded max made it try to BE infinitely wide.
///   3. Still throwing after the fix for #2, per Craig's own testing.
/// Three real, different failure modes from one hand-rolled mechanism is a
/// pattern, not bad luck — Craig asked directly what other apps do about
/// this, and the honest answer is: they almost never hand-roll a frozen
/// header over raw table primitives. They use a purpose-built grid
/// component that's already had this exact problem solved and tested against
/// real devices — `data_table_2` for Flutter (a free, BSD-3-Clause,
/// actively-maintained, documented in-place substitute for `DataTable`/
/// `PaginatedDataTable` — see `pubspec.yaml`), the same category of choice
/// as AG Grid or MUI's DataGrid on the web. Craig chose to switch rather
/// than take a fourth blind swing at the hand-rolled version.
///
/// **What changed for call sites**: nothing. Every existing `DataColumn`
/// (including its `onSort` callback) and `DataRow`/`DataCell` is used
/// as-is — `DataTable2` is explicitly built to accept the stock classes
/// unchanged (`DataColumn2`/`DataRow2` are opt-in extensions this codebase
/// doesn't need). `pinnedRowCount` and `stickyHeader` keep their exact prior
/// meaning; they just map onto `DataTable2`'s own native `fixedTopRows`
/// (which counts the header itself as row 1, so `pinnedRowCount: 1` becomes
/// `fixedTopRows: 2`) instead of this file's own now-deleted clip/transform
/// mechanism. `_minWidth` below replaces the old two-pass `GlobalKey`
/// measurement — `data_table_2` already spreads plain `DataColumn`s evenly
/// across the available width on its own ("table automatically stretches
/// horizontally," per its docs), so the only thing this widget still needs
/// to work out for itself is a sensible FLOOR under that stretching, below
/// which columns should stop being squeezed and the table should scroll
/// horizontally instead — a plain, static function of each column's label
/// text, no runtime measurement or `GlobalKey` involved, so there's nothing
/// left here that can crash the way the last three attempts did.
///
/// Still not visually confirmed on a real device — same caveat as every
/// layout change this engagement, since this sandbox cannot run Flutter —
/// but the actual pinning/frozen-row mechanism is now `data_table_2`'s own,
/// not this file's, which is the whole point of making this switch.
class ResponsiveDataTable extends StatelessWidget {
  const ResponsiveDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.sortColumnIndex,
    this.sortAscending = true,
    this.scrollsVertically = true,
    this.stickyHeader = true,
    this.pinnedRowCount = 0,
  });

  final List<DataColumn> columns;
  final List<DataRow> rows;

  /// Which column (if any) is currently showing a sort arrow, and which way
  /// — set by whichever screen owns the sort state. This widget only
  /// displays it and renders whatever `onSort` callback each [DataColumn]
  /// already carries; it never decides sort order itself, since only the
  /// calling screen knows how to compare its own row data.
  final int? sortColumnIndex;
  final bool sortAscending;

  /// Cosmetic only now — `DataTable2` always owns and manages its own
  /// vertical scroll region (that's the whole premise of a frozen header:
  /// something has to own an internal scrollable to freeze a row against).
  /// Kept for API continuity; maps onto whether the vertical scrollbar is
  /// shown, not whether scrolling itself happens. No call site currently
  /// passes `false`.
  final bool scrollsVertically;

  /// Defaults to `true` — freezes the header plus [pinnedRowCount] leading
  /// rows (typically a Totals row). `false` only for Budgets, whose Totals
  /// row deliberately stays at the bottom, unpinned (Wyzesales_Rebuild_Decisions.md
  /// Section 22b: Budgets was never included in the "Totals to the top"
  /// scope) — not for the duplicate-`TextField`-controller reason that used
  /// to apply here; `data_table_2` renders the row list once, not twice, so
  /// that specific hazard no longer exists. Budgets could safely pass
  /// `stickyHeader: true` today if a frozen header (not a frozen Totals row,
  /// which would still need `pinnedRowCount` and a repositioned Totals row)
  /// is ever wanted there — flagged as an easy follow-up, not applied
  /// unasked.
  final bool stickyHeader;

  /// How many of the LEADING rows in [rows] are a Totals row (or similar)
  /// that should freeze in place directly under the header, rather than
  /// scroll away with the rest of the body — 0 (default) pins the header
  /// only. Ignored when [stickyHeader] or [scrollsVertically] is false.
  /// Mapped onto `DataTable2.fixedTopRows` as `1 + pinnedRowCount`, since
  /// `fixedTopRows` counts the header row itself (its own default is `1` —
  /// header only pinned, matching the same "always at least the header"
  /// baseline this widget already had).
  final int pinnedRowCount;

  /// A deliberately simple, static floor under `data_table_2`'s own
  /// "stretch columns to fill the available width" behavior — without one,
  /// a table with many columns on a narrow window would just keep dividing
  /// the available width evenly among them with no lower bound, squeezing
  /// every column arbitrarily thin instead of switching to horizontal
  /// scroll (the actual, explicit ask: "Build in a horizontal scroll bar
  /// when the data does not fit into the screen horizontally"). Estimated
  /// per column from its own label's text length — "Sales Person" gets more
  /// room than "Qty" — rather than one flat number for every column,
  /// clamped to a sane range either way. This is intentionally rough: it's
  /// plain arithmetic over each column's own label, not a runtime
  /// measurement of anything, so there's no `GlobalKey`/render-tree
  /// dependency here to get wrong. If a particular table still looks too
  /// tight or too loose once Craig sees it rendered, that's a quick,
  /// low-risk visual tweak — nothing like the three render-tree crashes the
  /// previous hand-rolled approach produced.
  double get _minWidth => columns.fold<double>(0, (sum, column) => sum + _estimatedColumnWidth(column));

  double _estimatedColumnWidth(DataColumn column) {
    const base = 96.0;
    const perChar = 7.0;
    const min = 72.0;
    const max = 220.0;
    final label = column.label;
    final charCount = label is Text ? (label.data?.length ?? 8) : 8;
    final estimate = base + perChar * charCount;
    return estimate.clamp(min, max);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: DataTable2(
        columns: columns,
        rows: rows,
        sortColumnIndex: sortColumnIndex,
        sortAscending: sortAscending,
        minWidth: _minWidth,
        fixedTopRows: stickyHeader ? 1 + pinnedRowCount : 0,
        isVerticalScrollBarVisible: scrollsVertically,
        isHorizontalScrollBarVisible: true,
      ),
    );
  }
}
