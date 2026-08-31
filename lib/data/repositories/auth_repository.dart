import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/supabase/supabase_config.dart';
import '../models/profile.dart';

/// Thin wrapper over Supabase Auth + the current user's own profiles row.
/// Every RLS policy in schema/001 keys off `profiles.id = auth.uid()`, so
/// once a user is signed in, Postgres itself enforces which client_id's data
/// they can see — screens/repositories below never need to pass client_id
/// explicitly on reads, only on writes (see BudgetRepository).
class AuthRepository {
  Session? get currentSession => supabase.auth.currentSession;

  Stream<AuthState> get onAuthStateChange => supabase.auth.onAuthStateChange;

  Future<void> signInWithPassword({required String email, required String password}) async {
    await supabase.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() async {
    await supabase.auth.signOut();
  }

  /// Used both by LoginScreen's self-service "Forgot password?" and by an
  /// admin's per-user "Send password reset" button in Settings > Users
  /// (2026-08-31 — the second half of the password-reset gap flagged
  /// alongside the export buttons: "admin can't reset a user's password
  /// either"). Deliberately NOT built as "admin sets a new password
  /// directly" — that needs Supabase's Admin API (a service-role key),
  /// which must never ship inside a Flutter web client; sending the same
  /// reset email Supabase already supports needs no elevated privileges at
  /// all; whoever is signed in when this is called is irrelevant, since the
  /// account that actually gets reset is only ever the one named by `email`.
  ///
  /// `redirectTo` points the email's link at a real landing screen
  /// (ResetPasswordScreen/`/reset-password`) instead of Supabase's default
  /// Site URL — before this, the link silently logged whoever clicked it
  /// into the Dashboard with a short-lived recovery session and never asked
  /// for a new password at all (the other half of the same gap). `Uri.base`
  /// is safe to use here because WyzeSales only ever runs as a web app
  /// (confirmed 2026-08-31, Craig — see data_export_buttons.dart's own
  /// note) — it reads the browser's current origin, not a file:// path.
  Future<void> sendPasswordResetEmail(String email) async {
    await supabase.auth.resetPasswordForEmail(
      email,
      redirectTo: '${Uri.base.origin}/reset-password',
    );
  }

  /// Sets a new password for whichever session is currently active —
  /// ResetPasswordScreen's own use is the short-lived recovery session
  /// Supabase establishes after a user follows their reset-password email
  /// link, but Supabase Auth treats that no differently from an ordinary
  /// signed-in session, so this same call would work equally well from a
  /// future "change my password" option somewhere inside the app itself.
  Future<void> updatePassword(String newPassword) async {
    await supabase.auth.updateUser(UserAttributes(password: newPassword));
  }

  /// Loads the signed-in user's own profile row. Returns null if the auth
  /// user exists but has no matching profiles row yet (e.g. a SuperUser
  /// created the login but hasn't finished onboarding them) — screens should
  /// treat that as "not fully set up" rather than a hard error.
  Future<Profile?> loadCurrentProfile() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return null;
    final row = await supabase.from('profiles').select().eq('id', userId).maybeSingle();
    if (row == null) return null;
    return Profile.fromMap(row);
  }
}
