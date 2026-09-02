import 'package:supabase_flutter/supabase_flutter.dart';

/// Craig, 2026-09-02: hit a raw `FunctionsHttpException(status: 403,
/// details: {...}, reasonPhrase: )` dump in the UI while testing create-user
/// and rightly said "Users won't understand this." The 4 Edge Functions this
/// app calls (create-user, delete-user, create-client, send-upgrade-request)
/// already write a JSON body like `{"error": "plain-language message"}` for
/// every failure specifically so it can be shown as-is (see e.g.
/// create-user/index.ts's friendlyProfileInsertError for the rep-code/
/// branch-code case, and its own comment on the seat-limit trigger's
/// message) — but that message was never actually reaching the screen.
///
/// The repositories' own `if (response.status != 200) throw Exception(...)`
/// checks were dead code the whole time: supabase_flutter's FunctionsClient
/// doesn't return a normal FunctionResponse for a non-2xx status the way
/// that check implies — it throws FunctionsHttpException itself, with the
/// parsed JSON body sitting in `.details`. Every call site needs to catch
/// that specific exception and pull `.details['error']` back out, or the
/// screen's `e.toString()` shows Dart's default dump of the whole exception
/// instead.
///
/// Returns EdgeFunctionError rather than a plain Exception because
/// Exception's own toString() prepends "Exception: " — these messages are
/// already written to be shown to the user verbatim, so that prefix would
/// just be more of the "function error stuff" Craig asked to drop.
class EdgeFunctionError implements Exception {
  final String message;
  const EdgeFunctionError(this.message);

  @override
  String toString() => message;
}

/// Unwraps a caught FunctionsHttpException's `{"error": "..."}` body into a
/// plain, screen-ready EdgeFunctionError; anything else (a network failure,
/// an unexpected shape) falls back to [fallback] rather than surfacing raw
/// exception internals.
EdgeFunctionError friendlyEdgeFunctionError(Object error, {required String fallback}) {
  if (error is FunctionsHttpException) {
    final details = error.details;
    if (details is Map && details['error'] is String) {
      return EdgeFunctionError(details['error'] as String);
    }
  }
  return EdgeFunctionError(fallback);
}
