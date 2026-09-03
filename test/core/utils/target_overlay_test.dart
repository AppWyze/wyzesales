import 'package:flutter_test/flutter_test.dart';
import 'package:wyzesales/core/constants/fiscal.dart';
import 'package:wyzesales/core/filters/global_filters.dart';
import 'package:wyzesales/core/utils/target_overlay.dart';

/// 2026-09-03 (Wyzesales_Rebuild_Decisions.md — Sales Analysis's Target
/// overlay): pure logic only, no Supabase/Riverpod dependency, mirroring
/// global_filters_test.dart's own reasoning for why this needs no mocking.
void main() {
  group('activeDimensionFilterCount', () {
    test('0 for an empty GlobalFilters', () {
      expect(activeDimensionFilterCount(const GlobalFilters()), 0);
    });

    test('counts only the 5 real dimensions — Year/Month/Document never count', () {
      const filters = GlobalFilters(fiscalYear: 2027, fiscalMonth: 'Aug', document: 'INV-1');
      expect(activeDimensionFilterCount(filters), 0);
    });

    test('counts each of the 5 real dimensions independently', () {
      const salesPerson = FilterSelection('R01', 'Johan Botha');
      expect(activeDimensionFilterCount(const GlobalFilters(salesPerson: salesPerson)), 1);

      const twoActive = GlobalFilters(
        salesPerson: salesPerson,
        item: FilterSelection('I001', 'Flange Coupling 100mm'),
      );
      expect(activeDimensionFilterCount(twoActive), 2);

      const allFive = GlobalFilters(
        salesPerson: salesPerson,
        category: FilterSelection('CAT1', 'Pumps'),
        customer: FilterSelection('C001', 'Acme Corp'),
        item: FilterSelection('I001', 'Widget'),
        branch: FilterSelection('CPT', 'Cape Town'),
      );
      expect(activeDimensionFilterCount(allFive), 5);
    });
  });

  group('singleActiveDimensionFilter', () {
    test('null when zero dimensions are active', () {
      expect(singleActiveDimensionFilter(const GlobalFilters()), isNull);
    });

    test('null when 2 or more dimensions are active at once', () {
      const filters = GlobalFilters(
        customer: FilterSelection('C001', 'Johannesburg City Utilities'),
        item: FilterSelection('I001', 'Flange Coupling 100mm'),
      );
      expect(singleActiveDimensionFilter(filters), isNull);
    });

    test('returns the one active dimension + its selection, for each of the 5', () {
      const salesPerson = FilterSelection('R01', 'Johan Botha');
      final result = singleActiveDimensionFilter(const GlobalFilters(salesPerson: salesPerson));
      expect(result, isNotNull);
      expect(result!.dimension, SalesDimension.salesPerson);
      expect(result.selection, salesPerson);

      const branch = FilterSelection('CPT', 'Cape Town');
      final branchResult = singleActiveDimensionFilter(const GlobalFilters(branch: branch));
      expect(branchResult!.dimension, SalesDimension.branch);
      expect(branchResult.selection, branch);
    });
  });

  group('deriveProportionalTarget', () {
    test('Craig\'s own worked example (2026-09-03): Customer + Item filtered actual '
        'R3,029.74 of whole-company R1,475,555.60, against a company target of '
        'R1,845,948, derives to roughly R3,790', () {
      final result = deriveProportionalTarget(
        companyTarget: 1845948,
        totalActual: 1475555.60,
        filteredActual: 3029.74,
      );
      expect(result, isNotNull);
      expect(result!, closeTo(3790, 1));
    });

    test('null when companyTarget is null — nothing entered for the company at all', () {
      expect(deriveProportionalTarget(companyTarget: null, totalActual: 100, filteredActual: 10), isNull);
    });

    test('null when totalActual is null — no whole-company baseline to take a share of', () {
      expect(deriveProportionalTarget(companyTarget: 1000, totalActual: null, filteredActual: 10), isNull);
    });

    test('null when totalActual is zero — division by zero avoided, not a 0 or Infinity result', () {
      expect(deriveProportionalTarget(companyTarget: 1000, totalActual: 0, filteredActual: 10), isNull);
    });

    test('null when filteredActual is null — this combination had no actual sales data for the period', () {
      expect(deriveProportionalTarget(companyTarget: 1000, totalActual: 500, filteredActual: null), isNull);
    });

    test('a filtered combination matching the full company total derives to the full company target', () {
      final result = deriveProportionalTarget(companyTarget: 1000, totalActual: 500, filteredActual: 500);
      expect(result, 1000);
    });

    test('zero filtered actual derives to a zero target, not null — a real, computed 0% share', () {
      final result = deriveProportionalTarget(companyTarget: 1000, totalActual: 500, filteredActual: 0);
      expect(result, 0);
    });
  });

  group('resolveTarget', () {
    test('a real, non-zero budget wins outright — forecast is never even consulted', () {
      expect(resolveTarget(budgetValue: 50000, forecastValue: 99999), 50000);
    });

    test('falls back to forecast when budget is null — never entered', () {
      expect(resolveTarget(budgetValue: null, forecastValue: 42000), 42000);
    });

    test('falls back to forecast when budget is exactly 0 — schema/021\'s own definition of '
        '"not populated", since budget_value is NOT NULL DEFAULT 0', () {
      expect(resolveTarget(budgetValue: 0, forecastValue: 42000), 42000);
    });

    test('null when neither a budget nor a forecast exists for this month at all — the whole '
        'point this exists: Craig\'s "customer with zero September sales" case, where the target '
        'must NOT depend on whether v_dimension_performance happened to have an actual-sales row '
        'to attach it to', () {
      expect(resolveTarget(budgetValue: null, forecastValue: null), isNull);
      expect(resolveTarget(budgetValue: 0, forecastValue: null), isNull);
    });
  });
}
