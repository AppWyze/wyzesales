import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase project URL/anon key are passed in at build/run time via
/// --dart-define, never hardcoded or committed — see README.md "Configuring
/// which Supabase project this points at". Defaults are empty so a build
/// that forgets to pass them fails loudly in initialize() rather than
/// silently pointing at nothing.
class SupabaseConfig {
  static const String url = String.fromEnvironment('SUPABASE_URL');
  static const String anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static Future<void> initialize() async {
    if (url.isEmpty || anonKey.isEmpty) {
      throw StateError(
        'SUPABASE_URL / SUPABASE_ANON_KEY were not provided. Run with '
        '--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=... '
        '(see README.md).',
      );
    }
    // anonKey the parameter name still exists as of supabase_flutter 2.17
    // but is deprecated in favour of publishableKey — same value (the
    // project's anon/public key from Supabase's API settings), new name.
    await Supabase.initialize(url: url, publishableKey: anonKey);
  }
}

/// Shorthand used throughout the data layer.
SupabaseClient get supabase => Supabase.instance.client;
