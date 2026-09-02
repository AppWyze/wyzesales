import 'package:flutter_test/flutter_test.dart';
import 'package:wyzesales/core/constants/fiscal.dart';
import 'package:wyzesales/core/filters/global_filters.dart';

/// Regression tests for `GlobalFilters.forDimension` — a plain data class
/// method, no Supabase/Riverpod dependency, so this runs instantly with no
/// mocking (`GlobalFiltersNotifier` itself needs an `AuthRepository` and
/// isn't covered here).
///
/// 2026-09-02 (Wyzesales_Rebuild_Decisions.md Section 57): `SalesDimension`
/// gained a 6th member, `company`, once Craig noticed Performance Analysis'
/// dimension switcher had no whole-company option. `company` has no field of
/// its own on `GlobalFilters` — it's deliberately never offered anywhere a
/// global filter TARGET is picked (see `SalesDimension.filterable`'s doc
/// comment) — so `forDimension(company)` exists purely to satisfy the
/// switch's exhaustiveness and must always return null. These tests exist so
/// a future change can't accidentally wire a real filter field to it.
void main() {
  group('GlobalFilters.forDimension', () {
    test('returns each of the 5 real dimensions\' own field', () {
      const salesPerson = FilterSelection('R01', 'Johan Botha');
      const category = FilterSelection('CAT1', 'Pumps');
      const customer = FilterSelection('C001', 'Acme Corp');
      const item = FilterSelection('I001', 'Widget');
      const branch = FilterSelection('CPT', 'Cape Town');
      const filters = GlobalFilters(
        salesPerson: salesPerson,
        category: category,
        customer: customer,
        item: item,
        branch: branch,
      );

      expect(filters.forDimension(SalesDimension.salesPerson), salesPerson);
      expect(filters.forDimension(SalesDimension.category), category);
      expect(filters.forDimension(SalesDimension.customer), customer);
      expect(filters.forDimension(SalesDimension.item), item);
      expect(filters.forDimension(SalesDimension.branch), branch);
    });

    test('company always returns null — it has no field of its own and is never '
        'offered as a global filter target (see SalesDimension.filterable)', () {
      const empty = GlobalFilters();
      expect(empty.forDimension(SalesDimension.company), isNull);

      // Still null even with every real dimension filter active — company
      // genuinely has nothing to return, regardless of filter state.
      const allSet = GlobalFilters(
        salesPerson: FilterSelection('R01', 'Johan Botha'),
        category: FilterSelection('CAT1', 'Pumps'),
        customer: FilterSelection('C001', 'Acme Corp'),
        item: FilterSelection('I001', 'Widget'),
        branch: FilterSelection('CPT', 'Cape Town'),
      );
      expect(allSet.forDimension(SalesDimension.company), isNull);
    });

    test('isEmpty/activeCount are unaffected by company — there is no field for it '
        'to ever contribute to either count', () {
      const empty = GlobalFilters();
      expect(empty.isEmpty, true);
      expect(empty.activeCount, 0);
    });
  });
}
