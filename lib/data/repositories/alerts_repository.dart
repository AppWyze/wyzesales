import '../../core/supabase/supabase_config.dart';
import '../models/active_alert.dart';

/// v_active_alerts (schema/034_wyzesales_proactive_alerts.sql, 2026-09-04,
/// Item 3) — the top-bar notification bell's data source. A single plain
/// view query, same "RLS already scopes this to the caller's own client,
/// no client_id parameter needed" convention as SalesRepository/
/// BudgetRepository/SettingsRepository — see this view's own header comment
/// for exactly how each dimension's row is scoped (and the item/category
/// bypass function it deliberately routes through for those two dimensions
/// only).
class AlertsRepository {
  Future<List<ActiveAlert>> getActiveAlerts() async {
    final rows = await supabase.from('v_active_alerts').select();
    return rows.map<ActiveAlert>((r) => ActiveAlert.fromMap(r)).toList();
  }
}
