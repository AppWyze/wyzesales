import 'package:flutter_test/flutter_test.dart';
import 'package:wyzesales/core/utils/sales_coverage.dart';

void main() {
  group('EntitySalesHistory', () {
    test('avgRevenuePerPeriod divides total by active months', () {
      const history = EntitySalesHistory(entityCode: 'REP1', activeMonths: 36, totalValue: 2160000);
      expect(history.avgRevenuePerPeriod, 60000);
    });

    test('avgRevenuePerPeriod is zero (not a divide-by-zero) with no active months', () {
      const history = EntitySalesHistory(entityCode: 'REP1', activeMonths: 0, totalValue: 0);
      expect(history.avgRevenuePerPeriod, 0);
    });

    test('fromMap parses fn_dimension_sales_history\'s row shape (schema/023)', () {
      final history = EntitySalesHistory.fromMap({'entity_code': 'ALL', 'active_months': 36, 'total_value': 9000000});
      expect(history.entityCode, 'ALL');
      expect(history.activeMonths, 36);
      expect(history.totalValue, 9000000);
    });
  });

  group('computeCoverage', () {
    // Craig's own worked example, 2026-09-02: "I like 2. the fall back
    // option and my guess is less than 3 months of history activates the
    // fall back" — a brand-new rep with 1 active month falls back to the
    // company-wide average.
    test('brand-new rep (1 active month) falls back to the company average, flagged', () {
      const own = EntitySalesHistory(entityCode: 'REP_NEW', activeMonths: 1, totalValue: 40000);
      const company = EntitySalesHistory(entityCode: 'ALL', activeMonths: 36, totalValue: 9000000); // R250,000/month
      final result = computeCoverage(targetValue: 310000, actualValue: 250000, own: own, company: company);
      expect(result.rGap, 60000);
      expect(result.usedFallback, true);
      expect(result.onTarget, false);
      expect(result.insufficientData, false);
      expect(result.coveragePercent, closeTo(24, 0.001)); // 60,000 / 250,000 * 100
    });

    // Craig's second worked example: an established rep with plenty of own
    // history uses their OWN average, not the company's, and isn't flagged.
    test('established rep (36 active months) uses their own average, not flagged', () {
      const own = EntitySalesHistory(entityCode: 'REP_EST', activeMonths: 36, totalValue: 2160000); // R60,000/month
      const company = EntitySalesHistory(entityCode: 'ALL', activeMonths: 36, totalValue: 9000000);
      final result = computeCoverage(targetValue: 90000, actualValue: 60000, own: own, company: company);
      expect(result.rGap, 30000);
      expect(result.usedFallback, false);
      expect(result.coveragePercent, closeTo(50, 0.001)); // 30,000 / 60,000 * 100
    });

    test('exactly at the 3-active-month threshold uses its own average (fallback only fires BELOW 3)', () {
      const own = EntitySalesHistory(entityCode: 'REP_3MO', activeMonths: 3, totalValue: 150000); // R50,000/month
      const company = EntitySalesHistory(entityCode: 'ALL', activeMonths: 36, totalValue: 9000000);
      final result = computeCoverage(targetValue: 100000, actualValue: 50000, own: own, company: company);
      expect(result.usedFallback, false);
      expect(result.coveragePercent, closeTo(100, 0.001)); // 50,000 gap / 50,000 avg * 100
    });

    test('a null own history (no rows at all yet) falls back to the company average', () {
      const company = EntitySalesHistory(entityCode: 'ALL', activeMonths: 36, totalValue: 9000000);
      final result = computeCoverage(targetValue: 310000, actualValue: 250000, own: null, company: company);
      expect(result.usedFallback, true);
      expect(result.coveragePercent, closeTo(24, 0.001));
    });

    test('R Gap <= 0 (already at or above target) reports onTarget, no percentage', () {
      const own = EntitySalesHistory(entityCode: 'REP_EST', activeMonths: 36, totalValue: 2160000);
      final atTarget = computeCoverage(targetValue: 60000, actualValue: 60000, own: own, company: own);
      expect(atTarget.onTarget, true);
      expect(atTarget.rGap, 0);
      expect(atTarget.coveragePercent, isNull);

      final aboveTarget = computeCoverage(targetValue: 60000, actualValue: 75000, own: own, company: own);
      expect(aboveTarget.onTarget, true);
      expect(aboveTarget.rGap, -15000);
      expect(aboveTarget.coveragePercent, isNull);
    });

    test('no target set at all reports insufficientData (nothing to compute a gap against)', () {
      const own = EntitySalesHistory(entityCode: 'REP_EST', activeMonths: 36, totalValue: 2160000);
      final result = computeCoverage(targetValue: null, actualValue: 50000, own: own, company: own);
      expect(result.insufficientData, true);
      expect(result.onTarget, false);
      expect(result.coveragePercent, isNull);
      expect(result.rGap, isNull);
    });

    test('zero company-wide history (a brand-new client with no sales on record at all) reports insufficientData', () {
      final result = computeCoverage(targetValue: 100000, actualValue: 0, own: null, company: null);
      expect(result.insufficientData, true);
      expect(result.rGap, 100000); // the gap itself is still known — only the % is unavailable
      expect(result.coveragePercent, isNull);
    });

    test('a company history row with zero active months also reports insufficientData, not a divide-by-zero', () {
      const company = EntitySalesHistory(entityCode: 'ALL', activeMonths: 0, totalValue: 0);
      final result = computeCoverage(targetValue: 100000, actualValue: 0, own: null, company: company);
      expect(result.insufficientData, true);
      expect(result.coveragePercent, isNull);
    });

    // `periods` — added 2026-09-02 for the Year-only-filter fix
    // (performance_screen.dart's `_load()`): a Gap spanning several fiscal
    // months (a whole year, or a partial YTD year) needs to be measured
    // against that many months of average revenue, not one.
    group('periods', () {
      test('defaults to 1 — unchanged behaviour for every pre-existing (single-month) call site', () {
        const own = EntitySalesHistory(entityCode: 'REP_EST', activeMonths: 36, totalValue: 2160000); // R60,000/month
        final result = computeCoverage(targetValue: 90000, actualValue: 60000, own: own, company: own);
        expect(result.coveragePercent, closeTo(50, 0.001)); // 30,000 gap / (60,000 * 1) * 100
      });

      test('scales the average by the given number of periods (a full year, 12 periods)', () {
        // Own average R60,000/month; a whole year's Gap of R360,000 measured
        // against 12 months of average (R720,000) is exactly 50% — the same
        // shape as the Dashboard's own YTD tile ("avg x elapsed months").
        const own = EntitySalesHistory(entityCode: 'REP_EST', activeMonths: 36, totalValue: 2160000);
        final result = computeCoverage(targetValue: 1080000, actualValue: 720000, own: own, company: own, periods: 12);
        expect(result.rGap, 360000);
        expect(result.coveragePercent, closeTo(50, 0.001));
      });

      test('scales the average for a partial (elapsed-months-so-far) year the same way', () {
        // 6 elapsed fiscal months, R60,000/month own average -> R360,000
        // denominator; a R180,000 Gap is 50%.
        const own = EntitySalesHistory(entityCode: 'REP_EST', activeMonths: 36, totalValue: 2160000);
        final result = computeCoverage(targetValue: 540000, actualValue: 360000, own: own, company: own, periods: 6);
        expect(result.rGap, 180000);
        expect(result.coveragePercent, closeTo(50, 0.001));
      });

      test('a fallback average is scaled by periods the same way an own average is', () {
        const own = EntitySalesHistory(entityCode: 'REP_NEW', activeMonths: 1, totalValue: 40000);
        const company = EntitySalesHistory(entityCode: 'ALL', activeMonths: 36, totalValue: 9000000); // R250,000/month
        final result = computeCoverage(targetValue: 3720000, actualValue: 3000000, own: own, company: company, periods: 12);
        expect(result.usedFallback, true);
        expect(result.rGap, 720000);
        expect(result.coveragePercent, closeTo(24, 0.001)); // 720,000 / (250,000 * 12) * 100
      });

      test('onTarget/insufficientData results are unaffected by periods (no average involved)', () {
        const own = EntitySalesHistory(entityCode: 'REP_EST', activeMonths: 36, totalValue: 2160000);
        final atTarget = computeCoverage(targetValue: 60000, actualValue: 75000, own: own, company: own, periods: 12);
        expect(atTarget.onTarget, true);

        final noTarget = computeCoverage(targetValue: null, actualValue: 50000, own: own, company: own, periods: 12);
        expect(noTarget.insufficientData, true);
      });
    });
  });
}
