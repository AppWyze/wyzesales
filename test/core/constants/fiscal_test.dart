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

    test('regression guard: a January start month (start_month=1) must label every date '
        'by ITS OWN calendar year, not one year ahead. Found 2026-09-02 while writing these '
        'tests, confirmed with Craig, fixed the same day in both this function and its SQL '
        'twin (schema/022) — a Jan-Dec fiscal year ends in the same year it starts, unlike '
        'every startMonth from 2-12, where `date.month >= startMonth` being true for every '
        'month (since every month is >= 1) used to always take the +1 branch unconditionally', () {
      expect(fiscalYearFor(DateTime(2026, 1, 1), startMonth: 1), 2026);
      expect(fiscalYearFor(DateTime(2026, 12, 31), startMonth: 1), 2026);
      expect(fiscalYearFor(DateTime(2027, 1, 1), startMonth: 1), 2027);
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

  // 2026-09-02, Craig: "We can see all Dimensions except a Company wide
  // Dimension???" — `company` added as a 6th SalesDimension
  // (Wyzesales_Rebuild_Decisions.md Section 57). These guard the two
  // properties every other file in the app relies on without re-checking:
  // `company` must stay LAST (app_shell.dart's nav routes use `values.first`
  // to mean "the default real breakdown dimension," which must stay
  // `salesPerson`), and `filterable` must exclude it (GlobalFilterBar, the
  // top-bar search, and the Dashboard's ranking picker all rely on this to
  // never offer "Company" as something to filter by or rank within).
  group('SalesDimension — company (task, 2026-09-02, Section 57)', () {
    test('company is a real, selectable dimension with the schema\'s exact db value', () {
      expect(SalesDimension.company.dbValue, 'company');
      expect(SalesDimension.company.label, 'Company');
    });

    test('company is the LAST value — values.first must stay salesPerson '
        '(app_shell.dart\'s nav "quick" routes depend on this)', () {
      expect(SalesDimension.values.first, SalesDimension.salesPerson);
      expect(SalesDimension.values.last, SalesDimension.company);
    });

    test('filterable holds exactly the original 5 dimensions, excluding company', () {
      expect(SalesDimension.filterable, hasLength(5));
      expect(SalesDimension.filterable, isNot(contains(SalesDimension.company)));
      expect(
        SalesDimension.filterable,
        containsAll([
          SalesDimension.salesPerson,
          SalesDimension.category,
          SalesDimension.customer,
          SalesDimension.item,
          SalesDimension.branch,
        ]),
      );
    });

    test('values (used by the Sales by / Budgets / Performance dimension switchers) '
        'includes all 6, company included', () {
      expect(SalesDimension.values, hasLength(6));
      expect(SalesDimension.values, contains(SalesDimension.company));
    });
  });
}
