import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wyzesales/core/utils/edge_function_errors.dart';

void main() {
  group('EdgeFunctionError', () {
    test('toString returns the plain message, not "Exception: ..."', () {
      const err = EdgeFunctionError('That rep code does not exist for this client.');
      expect(err.toString(), 'That rep code does not exist for this client.');
    });
  });

  group('friendlyEdgeFunctionError', () {
    test('unwraps the {"error": "..."} body out of a FunctionsHttpException', () {
      final e = FunctionsHttpException(403, {'error': 'That rep code does not exist for this client.'});
      final result = friendlyEdgeFunctionError(e, fallback: 'Failed to create user');
      expect(result.toString(), 'That rep code does not exist for this client.');
    });

    test('falls back when details has no error string (unexpected shape)', () {
      final e = FunctionsHttpException(500, {'somethingElse': true});
      final result = friendlyEdgeFunctionError(e, fallback: 'Failed to create user');
      expect(result.toString(), 'Failed to create user');
    });

    test('falls back for a non-FunctionsHttpException error', () {
      final result = friendlyEdgeFunctionError(Exception('network blip'), fallback: 'Failed to create user');
      expect(result.toString(), 'Failed to create user');
    });
  });
}
