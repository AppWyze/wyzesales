import 'package:flutter_test/flutter_test.dart';
import 'package:wyzesales/core/constants/fiscal.dart';
import 'package:wyzesales/core/filters/global_filters.dart';

/// Regression tests for `GlobalFilters` — a plain data class, no Supabase/
/// Riverpod dependency, so this runs instantly with no mocking
/// (`GlobalFiltersNotifier` itself needs an `AuthRepository` and isn't
/// covered here).
///
/// 2026-09-05 (multi-tenant dimension model Step 2): rewritten alongside
/// `GlobalFilters` itself, from 5 fixed named fields to a
/// `Map<String, FilterSelection>` keyed by dimension_key — see that class's
/// own doc comment (core/filters/global_filters.dart) for the full
/// reasoning. `forDimension(SalesDimension)` is kept as a bridge over the
/// map for every call site not yet touched by this rework, so these tests
/// cover both that bridge AND the new `forKey`/`withDimension`/`.only`/
/// `hasAnyDimensionSelected` primitives it's built from.
///
/// 2026-09-02 (Wyzesales_Rebuild_Decisions.md Section 57): `SalesDimension`
/// gained a 6th member, `company`, once Craig noticed Performance Analysis'
/// dimension switcher had no whole-company option. `company` has no
/// meaningful selection — it's deliberately never offered anywhere a global
/// filter TARGET is picked (see `SalesDimension.filterable`'s doc comment)
/// — so `forDimension(company)` looks up a key nothing ever sets and must
/// always return null. These tests exist so a future change can't
/// accidentally wire a real filter value to it.
void main() {
  group('GlobalFilters.forKey / forDimension', () {
    test('forKey returns each dimension_key\'s own selection', () {
      const salesPerson = FilterSelection('R01', 'Johan Botha');
      const category = FilterSelection('CAT1', 'Pumps');
      const customer = FilterSelection('C001', 'Acme Corp');
      const item = FilterSelection('I001', 'Widget');
      const branch = FilterSelection('CPT', 'Cape Town');
      const filters = GlobalFilters(dimensions: {
        'sales_person': salesPerson,
        'category': category,
        'customer': customer,
        'item': item,
        'branch': branch,
      });

      expect(filters.forKey('sales_person'), salesPerson);
      expect(filters.forKey('category'), category);
      expect(filters.forKey('customer'), customer);
      expect(filters.forKey('item'), item);
      expect(filters.forKey('branch'), branch);
      expect(filters.forKey('dim_1'), isNull);
    });

    test('forDimension bridges SalesDimension to the matching dimensionKey (dbValue)', () {
      const salesPerson = FilterSelection('R01', 'Johan Botha');
      const category = FilterSelection('CAT1', 'Pumps');
      const customer = FilterSelection('C001', 'Acme Corp');
      const item = FilterSelection('I001', 'Widget');
      const branch = FilterSelection('CPT', 'Cape Town');
      const filters = GlobalFilters(dimensions: {
        'sales_person': salesPerson,
        'category': category,
        'customer': customer,
        'item': item,
        'branch': branch,
      });

      expect(filters.forDimension(SalesDimension.salesPerson), salesPerson);
      expect(filters.forDimension(SalesDimension.category), category);
      expect(filters.forDimension(SalesDimension.customer), customer);
      expect(filters.forDimension(SalesDimension.item), item);
      expect(filters.forDimension(SalesDimension.branch), branch);
    });

    test('company always returns null — it has no meaningful selection and is never '
        'offered as a global filter target (see SalesDimension.filterable)', () {
      const empty = GlobalFilters();
      expect(empty.forDimension(SalesDimension.company), isNull);

      // Still null even with every real dimension filter active — company
      // genuinely has nothing to return, regardless of filter state.
      const allSet = GlobalFilters(dimensions: {
        'sales_person': FilterSelection('R01', 'Johan Botha'),
        'category': FilterSelection('CAT1', 'Pumps'),
        'customer': FilterSelection('C001', 'Acme Corp'),
        'item': FilterSelection('I001', 'Widget'),
        'branch': FilterSelection('CPT', 'Cape Town'),
      });
      expect(allSet.forDimension(SalesDimension.company), isNull);
    });
  });

  group('GlobalFilters.only', () {
    test('sets exactly one dimension, nothing else', () {
      const selection = FilterSelection('R01', 'Johan Botha');
      final filters = GlobalFilters.only('sales_person', selection);

      expect(filters.forKey('sales_person'), selection);
      expect(filters.forKey('category'), isNull);
      expect(filters.fiscalYear, isNull);
      expect(filters.fiscalMonth, isNull);
      expect(filters.document, isNull);
      expect(filters.hasAnyDimensionSelected, true);
      expect(filters.activeCount, 1);
    });
  });

  group('GlobalFilters.withDimension', () {
    test('adds a dimension selection without disturbing others already set', () {
      const salesPerson = FilterSelection('R01', 'Johan Botha');
      const category = FilterSelection('CAT1', 'Pumps');
      final filters = GlobalFilters.only('sales_person', salesPerson).withDimension('category', category);

      expect(filters.forKey('sales_person'), salesPerson);
      expect(filters.forKey('category'), category);
      expect(filters.activeCount, 2);
    });

    test('a null selection clears that dimension only', () {
      const salesPerson = FilterSelection('R01', 'Johan Botha');
      const category = FilterSelection('CAT1', 'Pumps');
      final withBoth = GlobalFilters.only('sales_person', salesPerson).withDimension('category', category);
      final cleared = withBoth.withDimension('sales_person', null);

      expect(cleared.forKey('sales_person'), isNull);
      expect(cleared.forKey('category'), category);
      expect(cleared.activeCount, 1);
    });

    test('replaces an existing selection for the same key', () {
      const first = FilterSelection('R01', 'Johan Botha');
      const second = FilterSelection('R02', 'Sarah Naidoo');
      final filters = GlobalFilters.only('sales_person', first).withDimension('sales_person', second);

      expect(filters.forKey('sales_person'), second);
      expect(filters.activeCount, 1);
    });
  });

  group('hasAnyDimensionSelected / isEmpty / activeCount', () {
    test('all false/0 on a plain empty GlobalFilters', () {
      const empty = GlobalFilters();
      expect(empty.hasAnyDimensionSelected, false);
      expect(empty.isEmpty, true);
      expect(empty.activeCount, 0);
    });

    test('hasAnyDimensionSelected is true the moment any dimension is set, however many', () {
      const one = GlobalFilters(dimensions: {'branch': FilterSelection('CPT', 'Cape Town')});
      expect(one.hasAnyDimensionSelected, true);
      expect(one.isEmpty, false);

      const five = GlobalFilters(dimensions: {
        'sales_person': FilterSelection('R01', 'Johan Botha'),
        'category': FilterSelection('CAT1', 'Pumps'),
        'customer': FilterSelection('C001', 'Acme Corp'),
        'item': FilterSelection('I001', 'Widget'),
        'branch': FilterSelection('CPT', 'Cape Town'),
      });
      expect(five.activeCount, 5);
    });

    test('Year/Month/Document each contribute to activeCount but never to a dimension lookup', () {
      const filters = GlobalFilters(fiscalYear: 2027, fiscalMonth: 'Aug', document: 'INV-1');
      expect(filters.hasAnyDimensionSelected, false);
      expect(filters.isEmpty, false);
      expect(filters.activeCount, 3);
    });
  });

  group('GlobalFilters.toFilterParams', () {
    test('empty when no dimension is active', () {
      const filters = GlobalFilters(fiscalYear: 2027, fiscalMonth: 'Aug');
      expect(filters.toFilterParams(), <String, String>{});
    });

    test('every active dimension reduced to just its code, keyed by dimension_key', () {
      const filters = GlobalFilters(dimensions: {
        'sales_person': FilterSelection('R01', 'Johan Botha'),
        'branch': FilterSelection('CPT', 'Cape Town'),
        'dim_7': FilterSelection('ONLINE', 'Online Channel'),
      });

      expect(filters.toFilterParams(), {
        'sales_person': 'R01',
        'branch': 'CPT',
        'dim_7': 'ONLINE',
      });
    });

    test('excludeDimensionKey drops just that one key, leaving every other active filter', () {
      const filters = GlobalFilters(dimensions: {
        'sales_person': FilterSelection('R01', 'Johan Botha'),
        'customer': FilterSelection('C001', 'Acme Corp'),
      });

      final withoutCustomer = filters.toFilterParams(excludeDimensionKey: 'customer');
      expect(withoutCustomer, {'sales_person': 'R01'});

      // A key with no active selection is simply a no-op to exclude.
      final withoutBranch = filters.toFilterParams(excludeDimensionKey: 'branch');
      expect(withoutBranch, {'sales_person': 'R01', 'customer': 'C001'});
    });
  });

  group('copyWith', () {
    test('leaves dimensions untouched when not passed', () {
      const selection = FilterSelection('R01', 'Johan Botha');
      final filters = GlobalFilters.only('sales_person', selection).copyWith(fiscalYear: 2027);

      expect(filters.forKey('sales_person'), selection);
      expect(filters.fiscalYear, 2027);
    });

    test('the _unset sentinel lets fiscalYear/fiscalMonth/document be explicitly cleared to null', () {
      const filters = GlobalFilters(fiscalYear: 2027, fiscalMonth: 'Aug', document: 'INV-1');
      final cleared = filters.copyWith(fiscalYear: null);

      expect(cleared.fiscalYear, isNull);
      expect(cleared.fiscalMonth, 'Aug');
      expect(cleared.document, 'INV-1');
    });
  });
}
