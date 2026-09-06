import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/filters/global_filters.dart';
import '../../core/supabase/supabase_config.dart';
import '../models/filter_preset.dart';

/// Saved filter presets (schema/035, 2026-09-04; generalized by schema/045,
/// 2026-09-06). Every row is scoped to the signed-in user by RLS (`user_id =
/// auth.uid()`, defaulted server-side) — this repository never passes a user
/// id itself, and `list()` can never return anyone else's presets.
class FilterPresetRepository {
  Future<List<FilterPreset>> list() async {
    final rows = await supabase.from('filter_presets').select().order('name');
    return rows.map<FilterPreset>((r) => FilterPreset.fromMap(r)).toList();
  }

  /// Persists whatever's currently in `filters.dimensions` — every ACTIVE
  /// dimension filter, whichever dimensions this client actually has (see
  /// FilterPreset's own doc comment for why this used to be 5 hardcoded
  /// columns and no longer is). Year/Month/Document are separate
  /// `GlobalFilters` fields, never part of `.dimensions`, so they're
  /// excluded here the same structural way they always have been.
  ///
  /// Throws a plain `Exception` with a friendly message if `name` is already
  /// used by one of this user's own presets (schema/035's `unique(user_id,
  /// name)` constraint, surfaced by Postgres as error code 23505) — callers
  /// should show that message directly rather than a raw DB error.
  Future<void> save(String name, GlobalFilters filters) async {
    try {
      await supabase.from('filter_presets').insert({
        'name': name,
        'dimensions': {
          for (final entry in filters.dimensions.entries) entry.key: {'code': entry.value.code, 'label': entry.value.label},
        },
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
