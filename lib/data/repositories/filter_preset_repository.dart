import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants/fiscal.dart';
import '../../core/filters/global_filters.dart';
import '../../core/supabase/supabase_config.dart';
import '../models/filter_preset.dart';

/// Saved filter presets (schema/035, 2026-09-04) — Craig's own choice
/// ("Saved filter presets") for the polish item after the 2026-09-04
/// Dashboard filter-scoping fix. Every row is scoped to the signed-in user
/// by RLS (`user_id = auth.uid()`, defaulted server-side) — this repository
/// never passes a user id itself, and `list()` can never return anyone
/// else's presets.
class FilterPresetRepository {
  Future<List<FilterPreset>> list() async {
    final rows = await supabase.from('filter_presets').select().order('name');
    return rows.map<FilterPreset>((r) => FilterPreset.fromMap(r)).toList();
  }

  /// Only the 5 dimension filters are persisted — see FilterPreset's own doc
  /// comment for why Year/Month/Document are deliberately left out.
  ///
  /// Throws a plain `Exception` with a friendly message if `name` is already
  /// used by one of this user's own presets (schema/035's `unique(user_id,
  /// name)` constraint, surfaced by Postgres as error code 23505) — callers
  /// should show that message directly rather than a raw DB error.
  Future<void> save(String name, GlobalFilters filters) async {
    try {
      await supabase.from('filter_presets').insert({
        'name': name,
        'sales_person_code': filters.forDimension(SalesDimension.salesPerson)?.code,
        'sales_person_label': filters.forDimension(SalesDimension.salesPerson)?.label,
        'category_code': filters.forDimension(SalesDimension.category)?.code,
        'category_label': filters.forDimension(SalesDimension.category)?.label,
        'customer_code': filters.forDimension(SalesDimension.customer)?.code,
        'customer_label': filters.forDimension(SalesDimension.customer)?.label,
        'item_code': filters.forDimension(SalesDimension.item)?.code,
        'item_label': filters.forDimension(SalesDimension.item)?.label,
        'branch_code': filters.forDimension(SalesDimension.branch)?.code,
        'branch_label': filters.forDimension(SalesDimension.branch)?.label,
      });
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        throw Exception('You already have a preset named "$name". Pick a different name.');
      }
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    await supabase.from('filter_presets').delete().eq('id', id);
  }
}
