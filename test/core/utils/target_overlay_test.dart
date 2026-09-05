import 'package:flutter_test/flutter_test.dart';
import 'package:wyzesales/core/constants/fiscal.dart';
import 'package:wyzesales/core/filters/global_filters.dart';
import 'package:wyzesales/core/utils/target_overlay.dart';
import 'package:wyzesales/data/models/profile.dart';

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
      expect(activeDimensionFilterCount(GlobalFilters.only('sales_person', salesPerson)), 1);

      final twoActive = GlobalFilters.only('sales_person', salesPerson).withDimension(
        'item',
        const FilterSelection('I001', 'Flange Coupling 100mm'),
      );
      expect(activeDimensionFilterCount(twoActive), 2);

      const allFive = GlobalFilters(dimensions: {
        'sales_person': salesPerson,
        'category': FilterSelection('CAT1', 'Pumps'),
        'customer': FilterSelection('C001', 'Acme Corp'),
        'item': FilterSelection('I001', 'Widget'),
        'branch': FilterSelection('CPT', 'Cape Town'),
      });
      expect(activeDimensionFilterCount(allFive), 5);
    });
  });

  group('singleActiveDimensionFilter', () {
    test('null when zero dimensions are active', () {
      expect(singleActiveDimensionFilter(const GlobalFilters()), isNull);
    });

    test('null when 2 or more dimensions are active at once', () {
      const filters = GlobalFilters(dimensions: {
        'customer': FilterSelection('C001', 'Johannesburg City Utilities'),
        'item': FilterSelection('I001', 'Flange Coupling 100mm'),
      });
      expect(singleActiveDimensionFilter(filters), isNull);
    });

    test('returns the one active dimension + its selection, for each of the 5', () {
      const salesPerson = FilterSelection('R01', 'Johan Botha');
      final result = singleActiveDimensionFilter(GlobalFilters.only('sales_person', salesPerson));
      expect(result, isNotNull);
      expect(result!.dimension, SalesDimension.salesPerson);
      expect(result.selection, salesPerson);

      const branch = FilterSelection('CPT', 'Cape Town');
      final branchResult = singleActiveDimensionFilter(GlobalFilters.only('branch', branch));
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

    test('null when totalActual is negative — a negative denominator would flip the derived sign in a way '
        'nobody reading the chart would expect (2026-09-04)', () {
      expect(deriveProportionalTarget(companyTarget: 1000, totalActual: -200, filteredActual: 10), isNull);
    });

    test('a negative filteredActual (heavier credit notes than invoices that period) floors the derived '
        'target at 0 rather than going negative (2026-09-04)', () {
      final result = deriveProportionalTarget(companyTarget: 1000, totalActual: 500, filteredActual: -50);
      expect(result, 0);
    });
  });

  group('sumTrailingWindow', () {
    test('sums exactly the trailing N months ending at (and including) endMonth', () {
      final series = [
        (month: DateTime(2027, 7), value: 100),
        (month: DateTime(2027, 8), value: 200),
        (month: DateTime(2027, 9), value: 300),
      ];
      expect(sumTrailingWindow(series: series, endMonth: DateTime(2027, 9), windowMonths: 3), 600);
    });

    test('windowMonths: 1 is just the exact month, ignoring everything else in the series', () {
      final series = [
        (month: DateTime(2027, 8), value: 200),
        (month: DateTime(2027, 9), value: 300),
      ];
      expect(sumTrailingWindow(series: series, endMonth: DateTime(2027, 9), windowMonths: 1), 300);
    });

    test('crosses a fiscal year boundary correctly — pure calendar-month arithmetic, not fiscal-aware', () {
      final series = [
        (month: DateTime(2026, 11), value: 10),
        (month: DateTime(2026, 12), value: 20),
        (month: DateTime(2027, 1), value: 30),
      ];
      expect(sumTrailingWindow(series: series, endMonth: DateTime(2027, 1), windowMonths: 3), 60);
    });

    test('a month with no matching entry contributes 0, not an error or a skipped window', () {
      final series = [
        (month: DateTime(2027, 7), value: 100),
        // August missing entirely — e.g. genuinely zero activity that month.
        (month: DateTime(2027, 9), value: 300),
      ];
      expect(sumTrailingWindow(series: series, endMonth: DateTime(2027, 9), windowMonths: 3), 400);
    });

    test('entries outside the window are ignored even though they\'re in the same series', () {
      final series = [
        (month: DateTime(2027, 6), value: 999), // one month before the window starts
        (month: DateTime(2027, 7), value: 10),
        (month: DateTime(2027, 8), value: 20),
        (month: DateTime(2027, 9), value: 30),
      ];
      expect(sumTrailingWindow(series: series, endMonth: DateTime(2027, 9), windowMonths: 3), 60);
    });

    test('defaults to kTargetTrailingWindowMonths (3) when windowMonths is omitted', () {
      final series = [
        (month: DateTime(2027, 7), value: 10),
        (month: DateTime(2027, 8), value: 20),
        (month: DateTime(2027, 9), value: 30),
      ];
      expect(sumTrailingWindow(series: series, endMonth: DateTime(2027, 9)), 60);
      expect(kTargetTrailingWindowMonths, 3);
    });
  });

  group('deriveHierarchicalTarget', () {
    test('uses the first candidate that has both a real target and a positive own-actual', () {
      final result = deriveHierarchicalTarget(
        candidates: const [
          TargetBasisCandidate(label: 'Item: Multistage Vertical Pump', target: 400000, ownActual: 100000),
          TargetBasisCandidate(label: 'Company', target: 1600646, ownActual: 556250),
        ],
        filteredActual: 30000,
      );
      expect(result, isNotNull);
      expect(result!.basisLabel, 'Item: Multistage Vertical Pump');
      expect(result.share, closeTo(0.3, 0.0001));
      expect(result.value, closeTo(400000 * 0.3, 0.01));
    });

    test('skips a candidate with no real entered target and falls through to the next one', () {
      final result = deriveHierarchicalTarget(
        candidates: const [
          TargetBasisCandidate(label: 'Item: Multistage Vertical Pump', target: null, ownActual: 100000),
          TargetBasisCandidate(label: 'Company', target: 1600646, ownActual: 556250),
        ],
        filteredActual: 234912,
      );
      expect(result, isNotNull);
      expect(result!.basisLabel, 'Company');
    });

    test('skips a candidate with a zero own-actual (nothing to take a share of) and falls through', () {
      final result = deriveHierarchicalTarget(
        candidates: const [
          TargetBasisCandidate(label: 'Customer: Nelson Mandela Bay Utilities', target: 50000, ownActual: 0),
          TargetBasisCandidate(label: 'Company', target: 1600646, ownActual: 556250),
        ],
        filteredActual: 234912,
      );
      expect(result, isNotNull);
      expect(result!.basisLabel, 'Company');
    });

    test('null when every candidate fails to qualify, Company included', () {
      final result = deriveHierarchicalTarget(
        candidates: const [
          TargetBasisCandidate(label: 'Item: Multistage Vertical Pump', target: null, ownActual: 100000),
          TargetBasisCandidate(label: 'Company', target: null, ownActual: 556250),
        ],
        filteredActual: 234912,
      );
      expect(result, isNull);
    });

    test('null when filteredActual itself is null, regardless of how many candidates would otherwise qualify', () {
      final result = deriveHierarchicalTarget(
        candidates: const [TargetBasisCandidate(label: 'Company', target: 1600646, ownActual: 556250)],
        filteredActual: null,
      );
      expect(result, isNull);
    });

    test('an empty candidate list always derives null', () {
      expect(deriveHierarchicalTarget(candidates: const [], filteredActual: 1000), isNull);
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

  group('defaultTargetScope', () {
    Profile profileWith({required UserLevel level, String? repCode, String? branchCode}) => Profile(
          id: 'p1',
          clientId: 'c1',
          name: 'Test',
          email: 'test@example.com',
          level: level,
          repCode: repCode,
          branchCode: branchCode,
        );

    test('adminuser always gets the whole company, regardless of their own rep/branch code', () {
      final scope = defaultTargetScope(profileWith(level: UserLevel.adminuser, repCode: 'R01', branchCode: 'JHB'));
      expect(scope.dimension, SalesDimension.company);
      expect(scope.entityCode, 'ALL');
    });

    test('reguser gets their own branch — Craig, 2026-09-03: "RegUsers sees their branch"', () {
      final scope = defaultTargetScope(profileWith(level: UserLevel.reguser, branchCode: 'CPT'));
      expect(scope.dimension, SalesDimension.branch);
      expect(scope.entityCode, 'CPT');
    });

    test('user gets their own rep code — Craig: "User sees only their info"', () {
      final scope = defaultTargetScope(profileWith(level: UserLevel.user, repCode: 'R03'));
      expect(scope.dimension, SalesDimension.salesPerson);
      expect(scope.entityCode, 'R03');
    });

    test('a null profile (e.g. mid-load) falls back to whole-company, same as every login saw '
        'before this existed', () {
      final scope = defaultTargetScope(null);
      expect(scope.dimension, SalesDimension.company);
      expect(scope.entityCode, 'ALL');
    });

    test('reguser/user with no branch_code/rep_code of their own fall back to \'ALL\' rather than '
        'a null entity_code — schema/001 doesn\'t make either mandatory for every level', () {
      expect(defaultTargetScope(profileWith(level: UserLevel.reguser)).entityCode, 'ALL');
      expect(defaultTargetScope(profileWith(level: UserLevel.user)).entityCode, 'ALL');
    });
  });
}
