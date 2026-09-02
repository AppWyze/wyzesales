import 'package:flutter_test/flutter_test.dart';
import 'package:wyzesales/core/constants/fiscal.dart';

/// Regression tests for the pure fiscal-date helpers in `fiscal.dart` — task
/// #92, "targeted regression tests around the fiscal-year/rollup logic"
/// (Wyzesales_Rebuild_Decisions.md Section 46). Every function here is
/// already a plain, public, top-level function with no Supabase/Riverpod
/// dependency, so these run instantly with no mocking.
void main() {
  group('fiscalMonthOrderFor', () {
    test('default startMonth (3, March) rotates the calendar year to start at March', () {
      expect(
        fiscalMonthOrderFor(startMonth: 3),
        ['Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', 'Jan', 'Feb'],
      );
    });

    test('startMonth 1 (January) is the plain calendar year, unrotated', () {
      expect(
        fiscalMonthOrderFor(startMonth: 1),
        ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
      );
    });

    test('startMonth 12 (December) wraps around immediately after the first entry', () {
      expect(
        fiscalMonthOrderFor(startMonth: 12),
        ['Dec', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov'],
      );
    });

    test('always returns exactly 12 distinct month labels, for every possible startMonth', () {
      for (var m = 1; m <= 12; m++) {
        final order = fiscalMonthOrderFor(startMonth: m);
        expect(order, hasLength(12));
        expect(order.toSet(), hasLength(12), reason: 'no repeated or dropped month for startMonth=$m');
      }
    });
  });

  group('fiscalYearFor — client-side mirror of the fiscal_year() SQL function (schema/001 Section 8)', () {
    test('March start (the long-standing default): a date on/after March belongs to next '
        'calendar year\'s fiscal label; a date before March belongs to the current one', () {
      expect(fiscalYearFor(DateTime(2025, 3, 1), startMonth: 3), 2026);
      expect(fiscalYearFor(DateTime(2025, 12, 31), startMonth: 3), 2026);
      expect(fiscalYearFor(DateTime(2026, 1, 1), startMonth: 3), 2026);
      expect(fiscalYearFor(DateTime(2026, 2, 28), startMonth: 3), 2026);
      // The whole point of a Mar-Feb fiscal year: every date across the
      // Mar-2025..Feb-2026 span resolves to the SAME label, 2026.
    });

    test('an arbitrary mid-year start month (e.g. July) follows the same '
        '"labelled by the calendar year the fiscal year ENDS in" rule', () {
      expect(fiscalYearFor(DateTime(2025, 7, 1), startMonth: 7), 2026); // FY2026 runs Jul25->Jun26
      expect(fiscalYearFor(DateTime(2026, 6, 30), startMonth: 7), 2026);
      expect(fiscalYearFor(DateTime(2026, 7, 1), startMonth: 7), 2027); // rolls into FY2027
    });

    test('KNOWN ISSUE, not yet fixed — flagged 2026-09-02 while writing task #92\'s '
        'regression tests, reported to Craig for a decision rather than fixed unilaterally: '
        'a January start month (start_month=1) mislabels every date by one year. '
        'A Jan-Dec fiscal year should be labelled by ITS OWN calendar year (Jan 2026 -> Dec '
        '2026 is naturally "FY2026"), but `date.month >= startMonth` is true for every month '
        'when startMonth is 1, so this always takes the +1 branch and returns date.year + 1 '
        'unconditionally. This pins TODAY\'S actual (buggy) behaviour deliberately, rather than '
        'silently asserting the correct one, precisely so this test starts failing — as a '
        'prompt to update it — the moment this gets fixed. The identical formula also exists '
        'server-side (docs/schema/001_wyzesales_foundation.sql\'s fiscal_year() SQL function), '
        'so a real fix needs both sides changed together, not just this Dart mirror.', () {
      expect(fiscalYearFor(DateTime(2026, 1, 1), startMonth: 1), 2027); // should arguably be 2026
      expect(fiscalYearFor(DateTime(2026, 12, 31), startMonth: 1), 2027); // should arguably be 2026
      // No WyzeSales client is currently configured with start_month=1 (every
      // real client on record started life hardcoded to March, per Section
      // 48's own history) — so this has not yet mislabelled anyone's real
      // data. It would the moment a client picked a January fiscal year from
      // Settings > Company.
    });
  });

  group('fiscalYearWindow', () {
    test('3-year history window, oldest year first', () {
      expect(fiscalYearWindow(2027, 3), [2025, 2026, 2027]);
    });

    test('5-year history window, oldest year first', () {
      expect(fiscalYearWindow(2027, 5), [2023, 2024, 2025, 2026, 2027]);
    });

    test('the window always ends at currentFy itself, regardless of length', () {
      expect(fiscalYearWindow(2030, 3).last, 2030);
      expect(fiscalYearWindow(2030, 5).last, 2030);
    });

    test('window length always matches historyYears exactly', () {
      expect(fiscalYearWindow(2027, 3), hasLength(3));
      expect(fiscalYearWindow(2027, 5), hasLength(5));
    });
  });

  group('calendarMonthStartFor / fiscalMonthOrderFor round-trip', () {
    test('every fiscal month label for a given start month maps to a distinct calendar month, '
        'and back to the same label via fiscalMonthLabelFor', () {
      const startMonth = 3;
      const fiscalYear = 2026;
      for (final label in fiscalMonthOrderFor(startMonth: startMonth)) {
        final calendarDate = calendarMonthStartFor(fiscalYear, label, startMonth: startMonth);
        expect(fiscalMonthLabelFor(calendarDate), label, reason: 'round-trip failed for $label');
      }
    });

    test('a non-default start month (July) round-trips the same way', () {
      const startMonth = 7;
      const fiscalYear = 2026;
      for (final label in fiscalMonthOrderFor(startMonth: startMonth)) {
        final calendarDate = calendarMonthStartFor(fiscalYear, label, startMonth: startMonth);
        expect(fiscalMonthLabelFor(calendarDate), label, reason: 'round-trip failed for $label');
      }
    });

    test('an unknown month label throws rather than silently returning a wrong date', () {
      expect(() => calendarMonthStartFor(2026, 'Zzz', startMonth: 3), throwsArgumentError);
    });
  });

  group('fiscalStartMonthName', () {
    test('maps every 1-12 value to its full month name', () {
      expect(fiscalStartMonthName(1), 'January');
      expect(fiscalStartMonthName(3), 'March');
      expect(fiscalStartMonthName(12), 'December');
    });
  });
}
