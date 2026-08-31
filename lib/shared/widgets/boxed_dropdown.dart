import 'package:flutter/material.dart';

/// A dropdown with the same bordered white box every text field in the app
/// already gets from the theme's InputDecorationTheme — thin wrapper around
/// DropdownButtonFormField, used everywhere a plain Material DropdownButton
/// was being used bare (no border, no background) for the dimension/sort/
/// year/month switchers across Sales By, Budgets, and Performance. Craig
/// flagged this directly, comparing against SeaWyze's own boxed dropdowns
/// (2026-08-21).
///
/// Always wrapped in a fixed-width SizedBox: DropdownButtonFormField's
/// isExpanded:true needs a bounded width from its parent to size against,
/// and the Row/Wrap these dropdowns sit in don't hand children one by
/// default (unlike the one dropdown that was already inside a width-bound
/// SizedBox before this fix) — giving every call site an explicit width
/// sidesteps that risk entirely rather than relying on context-dependent
/// layout behaviour this project has no compiler to verify.
class BoxedDropdown<T> extends StatelessWidget {
  const BoxedDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width = 180,
    this.label,
    this.hint,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final double width;

  /// Shown in place of a selected value when `value` is null — e.g. the
  /// global filter bar's "Add filter" control (2026-08-26), which never
  /// actually holds a selection of its own (picking an entry there applies
  /// it to globalFiltersProvider and immediately resets, rather than
  /// leaving the picked item showing), so it needs its own placeholder text
  /// instead of sitting blank.
  final Widget? hint;

  /// Optional field label drawn above the dropdown box, styled the same way
  /// as every other field label in the app (Text at labelLarge + 6px gap,
  /// see login_screen.dart) — used by the Year/Category/Item/Sales
  /// Person/Branch/Customer filters on Sales Analysis' Table tab, Quote
  /// Analysis, and Sales Order Analysis, which previously relied on
  /// DropdownButtonFormField's built-in floating labelText instead: the same
  /// small/thin Material floating-label look Craig already flagged and moved
  /// away from on the Login screen, just never carried over here (2026-08-22).
  /// Left null on the dimension/sort/year/month switchers (Sales By/Budgets/
  /// Performance) that don't need a persistent label — the screen's own
  /// heading already makes their purpose clear.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final dropdown = SizedBox(
      width: width,
      child: DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        hint: hint,
        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
        items: items,
        onChanged: onChanged,
      ),
    );
    if (label == null) return dropdown;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label!, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          dropdown,
        ],
      ),
    );
  }
}
