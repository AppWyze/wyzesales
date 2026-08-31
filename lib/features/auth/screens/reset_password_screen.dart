import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/app_providers.dart';
import '../../../core/supabase/supabase_config.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/app_logo.dart';

/// Where a WyzeSales password-reset email actually lands (2026-08-31 —
/// closing the gap flagged alongside the export buttons: "password-reset
/// flow is half-built — sends email, no landing page to complete reset").
/// Before this screen existed, AuthRepository.sendPasswordResetEmail had no
/// `redirectTo`, so Supabase sent the link to its default Site URL; the
/// Flutter web client's `detectSessionInUri` (on by default) still quietly
/// turned that into a valid signed-in session, but nothing ever asked the
/// user to actually pick a new password — the link just logged them straight
/// into the Dashboard as if they'd typed a correct password, which was the
/// whole problem.
///
/// `Supabase.initialize()` in main.dart is awaited before `runApp`, and its
/// web implementation resolves the recovery token from the URL (and fires
/// `AuthChangeEvent.passwordRecovery` on the auth stream) as part of that
/// same await — so by the time this screen builds, `supabase.auth.
/// currentSession` is normally already set. This still both checks the
/// session once at `initState` AND subscribes to the auth stream for a
/// session arriving slightly later, purely as a safety net against a timing
/// gap neither this codebase nor this sandbox can fully rule out ahead of a
/// real toolchain run (see data_export_buttons.dart's own several rounds of
/// "looked right until it ran for real"). A used-up or expired reset link,
/// or the token having already been stripped from the URL by the time this
/// widget mounts with nothing left to show for it, both end up in the same
/// place after a short timeout: a plain "couldn't verify this link" message
/// rather than a spinner that never resolves.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  late final StreamSubscription<AuthState> _authSub;

  bool _obscure = true;
  bool _submitting = false;
  bool _done = false;
  bool _hasSession = false;
  bool _linkInvalid = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // Supabase's failure mode for a used-up/expired link is to redirect back
    // here with `error`/`error_code` instead of a working token — as a query
    // param under the PKCE flow, or packed into the URL fragment under the
    // older implicit flow (`#error=access_denied&error_code=otp_expired...`).
    // Checking both up front catches it immediately, before ever falling
    // through to the "still verifying" spinner below.
    final fragmentParams = Uri.splitQueryString(Uri.base.fragment);
    if (Uri.base.queryParameters['error'] != null || fragmentParams['error'] != null) {
      _linkInvalid = true;
    }
    _hasSession = supabase.auth.currentSession != null;
    _authSub = supabase.auth.onAuthStateChange.listen((state) {
      if (mounted && state.session != null) setState(() => _hasSession = true);
    });
    // Belt-and-suspenders for the case neither of the two checks above can
    // see: the web client already stripped the token (or the error) out of
    // the URL before this screen ever built — its normal behaviour, so the
    // raw token doesn't linger in the address bar/browser history — leaving
    // nothing here to detect a bad link from, and no session or
    // passwordRecovery event ever arrives either. Rather than spinning on
    // "Verifying your reset link…" forever in that case, give up after a few
    // seconds and show the same "couldn't verify" message the explicit-error
    // case shows above.
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted && !_hasSession && !_linkInvalid) {
        setState(() => _linkInvalid = true);
      }
    });
  }

  @override
  void dispose() {
    _authSub.cancel();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await ref.read(authRepositoryProvider).updatePassword(_passwordController.text);
      if (mounted) setState(() => _done = true);
    } on AuthException catch (error) {
      setState(() => _errorMessage = error.message);
    } catch (_) {
      setState(() => _errorMessage = 'Something went wrong. Please try the reset link again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                child: _buildBody(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_linkInvalid) {
      return _MessagePane(
        icon: Icons.error_outline,
        iconColor: Theme.of(context).colorScheme.error,
        title: "This link couldn't be verified",
        body: 'Reset links only work once and expire after a while. Go back and request a new one from the sign-in screen.',
        actionLabel: 'Back to sign in',
        onAction: () async {
          await supabase.auth.signOut();
          if (mounted) context.go('/login');
        },
      );
    }
    if (_done) {
      return _MessagePane(
        icon: Icons.check_circle_outline,
        iconColor: AppColors.positive,
        title: 'Password updated',
        body: 'Your password has been changed. You can carry on using WyzeSales now.',
        actionLabel: 'Continue',
        onAction: () => context.go('/'),
      );
    }
    if (!_hasSession) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Verifying your reset link…', textAlign: TextAlign.center),
          ],
        ),
      );
    }
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: AppLogo(iconSize: 44, fontSize: 26)),
          const SizedBox(height: 10),
          Text('Set a new password', style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 28),
          Text('New password', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscure,
            decoration: InputDecoration(
              hintText: '••••••••',
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show password' : 'Hide password',
                icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) return 'Enter a new password';
              if (value.length < 8) return 'Use at least 8 characters';
              return null;
            },
          ),
          const SizedBox(height: 16),
          Text('Confirm new password', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          TextFormField(
            controller: _confirmController,
            obscureText: _obscure,
            decoration: const InputDecoration(hintText: '••••••••'),
            validator: (value) => value != _passwordController.text ? "Passwords don't match" : null,
            onFieldSubmitted: (_) => _submit(),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Update password'),
          ),
        ],
      ),
    );
  }
}

/// Shared shape for this screen's two terminal states (expired link,
/// successful reset) — same icon/title/body/single-action layout either
/// way, just different content.
class _MessagePane extends StatelessWidget {
  const _MessagePane({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 48, color: iconColor),
        const SizedBox(height: 16),
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(body, textAlign: TextAlign.center),
        const SizedBox(height: 20),
        ElevatedButton(onPressed: onAction, child: Text(actionLabel)),
      ],
    );
  }
}
