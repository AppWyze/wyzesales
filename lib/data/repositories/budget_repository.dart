import '../../core/supabase/supabase_config.dart';
import '../models/budget_figure.dart';

/// Reads and writes budget_figures — the one table in this whole app that's
/// genuinely user-owned data, per schema/001 Section 4. Writing requires
/// schema/004 (the UPDATE policy) and schema/005 (the profiles RLS
/// recursion fix) to be applied — without either, an edit to an
/// already-set month fails; see those migrations' comments for why.
class BudgetRepository {
  Future<List<BudgetFigure>> fetchBudget({required String dimension, String? entityCode}) async {
    var query = supabase.from('budget_figures').select().eq('dimension', dimension);
    if (entityCode != null) query = query.eq('entity_code', entityCode);
    final rows = await query.order('fiscal_month');
    return rows.map<BudgetFigure>((r) => BudgetFigure.fromMap(r)).toList();
  }

  /// Upsert one fiscal month's target for one entity. client_id is required
  /// here (unlike the read-only repositories) because RLS's WITH CHECK
  /// clause validates the row being written, not just who's writing it —
  /// the caller must supply their own profile's client_id.
  Future<void> setBudgetValue({
    required String clientId,
    required String dimension,
    required String entityCode,
    required String fiscalMonth,
    required num budgetValue,
  }) async {
    await supabase.from('budget_figures').upsert({
      'client_id': clientId,
      'dimension': dimension,
      'entity_code': entityCode,
      'fiscal_month': fiscalMonth,
      'budget_value': budgetValue,
      'updated_at': DateTime.now().toIso8601String(),
    }, onConflict: 'client_id,dimension,entity_code,fiscal_month');
  }
}
