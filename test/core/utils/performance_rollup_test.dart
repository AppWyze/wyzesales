import 'package:flutter_test/flutter_test.dart';
import 'package:wyzesales/core/utils/performance_rollup.dart';
import 'package:wyzesales/data/models/dimension_performance.dart';

/// Regression tests for `mergeAcrossYears` — task #92, "targeted regression
/// tests around the fiscal-year/rollup logic" (Wyzesales_Rebuild_Decisions.md
/// Section 46/52-53). This formula went through three attempts this
/// engagement (two of them wrong, one of those two wrong in a way that
/// silently reproduced the FIRST bug under a different disguise — see the
/// doc comment on `mergeAcrossYears` itself for the full history) before
/// Craig confirmed the final design. These tests exist so a future change to
/// this function can't reintroduce any of those three failure modes without
/// something failing loudly.
DimensionPerformance _row({
  required String entityCode,
  required int fiscalYear,
  required num actualValue,
  num actualQuantity = 0,
  num actualProfit = 0,
  num? targetValue,
  String dimension = 'sales_person',
  String fiscalMonth = 'Aug',
}) {
  return DimensionPerformance(
    dimension: dimension,
    entityCode: entityCode,
    fiscalYear: fiscalYear,
    fiscalMonth: fiscalMonth,
    actualValue: actualValue,
    actualQuantity: actualQuantity,
    actualProfit: actualProfit,
    gpPercent: 0, // irrelevant input — recomputed by mergeAcrossYears, not read from here
    targetValue: targetValue,
  );
}

void main() {
  group('mergeAcrossYears — R Target formula (Section 52 agreed design)', () {
    test('the exact worked example Craig confirmed before this was built: '
        '3 years actual (100k/120k/90k), 1 target on file (150k) -> R Target '
        '= past actuals (220k) + target (150k) = 370k, NOT scaled by year count', () {
      // budget_figures has no fiscal_year column (schema/001) — the same
      // resolved target value is joined onto every contributing year's row,
      // exactly as v_dimension_performance/fn_dimension_performance_filtered
      // actually produce it. Modelled faithfully here rather than only
      // attaching a target to one row.
      final rows = [
        _row(entityCode: 'R01', fiscalYear: 2025, actualValue: 100000, targetValue: 150000),
        _row(entityCode: 'R01', fiscalYear: 2026, actualValue: 120000, targetValue: 150000),
        _row(entityCode: 'R01', fiscalYear: 2027, actualValue: 90000, targetValue: 150000),
      ];

      final merged = mergeAcrossYears(rows, 2027);

      expect(merged, hasLength(1));
      final r = merged.single;
      expect(r.actualValue, 310000, reason: 'R Value is the plain sum across every merged year');
      expect(r.targetValue, 370000, reason: 'past actuals (2025+2026=220k) + the one target on file (150k)');
      expect(r.targetPercent, closeTo(310000 / 370000 * 100, 0.0001));
    });

    test('regression guard for bug #1: an identical repeated budget figure must NOT '
        'be summed once per matched year (that would silently multiply a real '
        'target by the number of years, e.g. 3x here)', () {
      final rows = [
        _row(entityCode: 'R01', fiscalYear: 2025, actualValue: 50000, targetValue: 60000),
        _row(entityCode: 'R01', fiscalYear: 2026, actualValue: 55000, targetValue: 60000),
        _row(entityCode: 'R01', fiscalYear: 2027, actualValue: 58000, targetValue: 60000),
      ];

      final merged = mergeAcrossYears(rows, 2027);

      final wrongSummedTarget = 60000 * 3; // bug #1's actual output
      final wrongScaledTarget = 60000 * 3; // bug #2 landed on the identical number as bug #1
      expect(merged.single.targetValue, isNot(wrongSummedTarget));
      expect(merged.single.targetValue, isNot(wrongScaledTarget));
      expect(merged.single.targetValue, 50000 + 55000 + 60000); // past actuals (105k) + target (60k)
    });

    test('current fiscal year has no data yet (extract for this period has not run/loaded): '
        'every contributing row counts as past, so R Target = full actual sum + target, '
        'deliberately exceeding R Value — Craig confirmed this is expected, not a bug', () {
      final rows = [
        _row(entityCode: 'R01', fiscalYear: 2025, actualValue: 100000, targetValue: 150000),
        _row(entityCode: 'R01', fiscalYear: 2026, actualValue: 120000, targetValue: 150000),
      ];

      // currentFy (2027) matches NEITHER row — this year's period genuinely
      // hasn't happened/loaded yet.
      final merged = mergeAcrossYears(rows, 2027);

      final r = merged.single;
      expect(r.actualValue, 220000);
      expect(r.targetValue, 220000 + 150000); // every row is "past" -> full sum + target
      expect(r.targetPercent!, lessThan(100), reason: '%Target understates until the current period actually occurs');
    });

    test('only one contributing year, and it IS the current fiscal year: '
        'past actual is zero, so R Target reduces to just the target on file', () {
      final rows = [
        _row(entityCode: 'R01', fiscalYear: 2027, actualValue: 90000, targetValue: 150000),
      ];

      final merged = mergeAcrossYears(rows, 2027);

      expect(merged.single.actualValue, 90000);
      expect(merged.single.targetValue, 150000); // pastActual=0, so target = 0 + 150000
    });

    test('no target on file at all (targetValue null on every row) -> merged targetValue '
        'and targetPercent are both null, never a crash from a null+num or divide-by-zero', () {
      final rows = [
        _row(entityCode: 'R01', fiscalYear: 2025, actualValue: 100000),
        _row(entityCode: 'R01', fiscalYear: 2026, actualValue: 120000),
      ];

      final merged = mergeAcrossYears(rows, 2027);

      expect(merged.single.targetValue, isNull);
      expect(merged.single.targetPercent, isNull);
    });

    test('target resolves to exactly zero -> targetPercent is null, not Infinity/NaN '
        '(matches the existing target==0 guard)', () {
      final rows = [
        _row(entityCode: 'R01', fiscalYear: 2027, actualValue: 50000, targetValue: 0),
      ];

      final merged = mergeAcrossYears(rows, 2027);

      expect(merged.single.targetValue, 0);
      expect(merged.single.targetPercent, isNull);
    });

    test('gpPercent is recomputed from the SUMMED Rand figures, not averaged across years '
        '(a ratio of ratios is the wrong ratio)', () {
      final rows = [
        // Year 1: 40% margin (40k profit on 100k). Year 2: 10% margin (5k on 50k).
        // A naive average of the two percentages would give 25% — wrong.
        _row(entityCode: 'R01', fiscalYear: 2025, actualValue: 100000, actualProfit: 40000),
        _row(entityCode: 'R01', fiscalYear: 2026, actualValue: 50000, actualProfit: 5000),
      ];

      final merged = mergeAcrossYears(rows, 2027);

      final expectedGpPercent = (40000 + 5000) / (100000 + 50000) * 100; // = 30%, not 25%
      expect(merged.single.gpPercent, closeTo(expectedGpPercent, 0.0001));
    });

    test('actualValue of zero across every merged row -> gpPercent is 0, not a divide-by-zero crash', () {
      final rows = [
        _row(entityCode: 'R01', fiscalYear: 2025, actualValue: 0, actualProfit: 0),
      ];

      final merged = mergeAcrossYears(rows, 2027);

      expect(merged.single.gpPercent, 0);
    });

    test('multiple entities merge independently — one entity\'s years never leak into another\'s sum', () {
      final rows = [
        _row(entityCode: 'R01', fiscalYear: 2025, actualValue: 100000, targetValue: 150000),
        _row(entityCode: 'R01', fiscalYear: 2026, actualValue: 120000, targetValue: 150000),
        _row(entityCode: 'R02', fiscalYear: 2025, actualValue: 10000, targetValue: 20000),
        _row(entityCode: 'R02', fiscalYear: 2026, actualValue: 15000, targetValue: 20000),
      ];

      final merged = mergeAcrossYears(rows, 2027);
      final byCode = {for (final r in merged) r.entityCode: r};

      expect(merged, hasLength(2));
      expect(byCode['R01']!.actualValue, 220000);
      expect(byCode['R02']!.actualValue, 25000);
    });

    test('contributionPercent is recomputed as this entity\'s merged actual over the '
        'GRAND TOTAL merged actual across every entity, not any single year\'s total', () {
      final rows = [
        _row(entityCode: 'R01', fiscalYear: 2025, actualValue: 60000),
        _row(entityCode: 'R01', fiscalYear: 2026, actualValue: 60000), // R01 merged total: 120000
        _row(entityCode: 'R02', fiscalYear: 2025, actualValue: 30000),
        _row(entityCode: 'R02', fiscalYear: 2026, actualValue: 30000), // R02 merged total: 60000
      ];

      final merged = mergeAcrossYears(rows, 2027);
      final byCode = {for (final r in merged) r.entityCode: r};

      // Grand total across everyone, every year: 120000 + 60000 = 180000.
      expect(byCode['R01']!.contributionPercent, closeTo(120000 / 180000 * 100, 0.0001));
      expect(byCode['R02']!.contributionPercent, closeTo(60000 / 180000 * 100, 0.0001));
    });

    test('a single fiscal year selected upstream never reaches this function with more than '
        'one row per entity — merging a list that already has exactly one row per entity is a '
        'no-op on every field except the recomputed ratios', () {
      final rows = [_row(entityCode: 'R01', fiscalYear: 2027, actualValue: 90000, targetValue: 100000)];

      final merged = mergeAcrossYears(rows, 2027);

      expect(merged.single.actualValue, rows.single.actualValue);
      expect(merged.single.targetValue, rows.single.targetValue);
    });
  });
}
