import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/app_providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_logo.dart';

/// Turns a Supabase `AuthException` into wording a non-technical user can
/// act on, instead of the raw `AuthApiException(message: ..., statusCode:
/// ..., code: ...)` object `Object.toString()` would otherwise produce.
/// 2026-08-28, Craig, pointing at exactly that raw text on a real sign-in
/// attempt: "Can you also trap this error with the correct wording please."
///
/// Only `error.code` is switched on, not `error.message` — `code` is the
/// stable machine-readable identifier Supabase's own docs say to match on
/// (https://supabase.com/docs/guides/auth/debugging/error-codes); `message`
/// is free-text intended for logs/developers and isn't guaranteed to stay
/// worded the same way between Supabase releases. `invalid_credentials` is
/// the one this was actually caught with (wrong email or wrong password —
/// deliberately not distinguished, so a sign-in attempt can't be used to
/// probe which emails have accounts); the rest are the other codes
/// Supabase's own docs list as reachable from a password sign-in attempt.
/// Anything not listed here (a code Supabase adds later, or none at all)
/// falls through to a generic-but-still-readable message rather than ever
/// showing the exception object itself again.
String _friendlySignInError(Object error) {
  if (error is AuthException) {
    switch (error.code) {
      case 'invalid_credentials':
        return 'Incorrect email or password. Please try again.';
      case 'email_not_confirmed':
        return 'Please confirm your email address before signing in — check your inbox for the confirmation link.';
      case 'user_banned':
        return 'This account has been disabled. Please contact your administrator.';
      case 'user_not_found':
        return 'Incorrect email or password. Please try again.';
      case 'over_request_rate_limit':
        return 'Too many sign-in attempts. Please wait a few minutes and try again.';
      default:
        return 'Sign-in failed. Please check your details and try again.';
    }
  }
  return 'Unable to reach the server. Please check your connection and try again.';
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  bool _obscurePassword = true;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await ref.read(authRepositoryProvider).signInWithPassword(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
      // Successful sign-in triggers appRouter's redirect via the auth stream —
      // no manual navigation needed here.
    } catch (error) {
      setState(() => _errorMessage = _friendlySignInError(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Light gray-blue background matching the rest of the app (Craig's
    // SeaWyze reference screenshots use the same light background behind
    // the login card, not the app's navy — the earlier version of this
    // screen used navy here, restyled 2026-08-21 to match).
    return Scaffold(
      backgroundColor: AppColors.lightBackground,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 40, 32, 28),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: AppLogo(iconSize: 44, fontSize: 26)),
                      const SizedBox(height: 10),
                      Text(
                        'Sales & Budget Analysis',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 28),
                      Text('Email address', style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _emailController,
                        decoration: const InputDecoration(hintText: 'you@company.com'),
                        keyboardType: TextInputType.emailAddress,
                        validator: (value) => (value == null || value.isEmpty) ? 'Enter your email' : null,
                      ),
                      const SizedBox(height: 16),
                      Text('Password', style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _passwordController,
                        decoration: InputDecoration(
                          hintText: '••••••••',
                          suffixIcon: IconButton(
                            tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                            icon: Icon(_obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        obscureText: _obscurePassword,
                        validator: (value) => (value == null || value.isEmpty) ? 'Enter your password' : null,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () async {
                            if (_emailController.text.trim().isEmpty) {
                              setState(() => _errorMessage = 'Enter your email above first, then tap this again.');
                              return;
                            }
                            await ref.read(authRepositoryProvider).sendPasswordResetEmail(_emailController.text.trim());
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Password reset email sent, if that address has an account.')),
                              );
                            }
                          },
                          child: const Text('Forgot password?'),
                        ),
                      ),
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 4),
                        Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        const SizedBox(height: 12),
                      ],
                      const SizedBox(height: 8),
                      ElevatedButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('Sign in'),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'WyzeSales v0.1 · © 2026 WyzeSales',
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
