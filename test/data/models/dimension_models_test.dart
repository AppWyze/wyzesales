import 'package:flutter_test/flutter_test.dart';
import 'package:wyzesales/data/models/dimension_monthly_sales.dart';
import 'package:wyzesales/data/models/dimension_performance.dart';

/// Regression tests for the `entityCode` fallback both `fromMap` factories
/// gained 2026-09-02, answering Craig's question about whether Revenue
/// reconciles across every dimension. `sales_document_facts.invoice_rep_code`
/// / `.warehouse_code` are both nullable, and an item can lack a
/// `department_code` mapping — so a line with none of those resolved used
/// to come back from Supabase with a null `entity_code` for the Sales
/// Person/Branch/Category dimensions specifically, and the old bare
/// `map['entity_code'] as String` cast would throw on it, failing the
/// ENTIRE fetch for that dimension/screen rather than just miscounting one
/// row. schema/024 now coalesces this to 'UNASSIGNED' at the source
/// (`v_sales_documents`), so these should never actually see a null in
/// practice any more — kept as defense in depth regardless (Craig: "Yes
/// please" to hardening this rather than leaving it to chance).
void main() {
  group('DimensionMonthlySales.fromMap', () {
    Map<String, dynamic> row({Object? entityCode = 'R01'}) => {
          'dimension': 'sales_person',
          'entity_code': entityCode,
          'month': '2027-08-01',
          'fiscal_year': 2027,
          'fiscal_month': 'Aug',
          'quantity': 10,
          'value': 50000,
          'profit': 15000,
        };

    test('a normal, present entity_code parses through unchanged', () {
      final parsed = DimensionMonthlySales.fromMap(row(entityCode: 'R01'));
      expect(parsed.entityCode, 'R01');
    });

    test('a null entity_code (an unattributed line, pre-schema/024 or a future '
        'regression) falls back to \'UNASSIGNED\' instead of throwing', () {
      final parsed = DimensionMonthlySales.fromMap(row(entityCode: null));
      expect(parsed.entityCode, 'UNASSIGNED');
    });
  });

  group('DimensionPerformance.fromMap', () {
    Map<String, dynamic> row({Object? entityCode = 'R01'}) => {
          'dimension': 'sales_person',
          'entity_code': entityCode,
          'fiscal_year': 2027,
          'fiscal_month': 'Aug',
          'actual_value': 50000,
          'actual_quantity': 10,
          'actual_profit': 15000,
          'gp_percent': 30,
          'target_value': 60000,
          'target_percent': 83.3,
          'contribution_percent': 12.5,
        };

    test('a normal, present entity_code parses through unchanged', () {
      final parsed = DimensionPerformance.fromMap(row(entityCode: 'R01'));
      expect(parsed.entityCode, 'R01');
    });

    test('a null entity_code falls back to \'UNASSIGNED\' instead of throwing, '
        'matching schema/024\'s own sentinel', () {
      final parsed = DimensionPerformance.fromMap(row(entityCode: null));
      expect(parsed.entityCode, 'UNASSIGNED');
    });
  });
}
