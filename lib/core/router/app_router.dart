import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/reset_password_screen.dart';
import '../../features/dashboard/screens/dashboard_screen.dart';
import '../../features/sales_analysis/screens/sales_analysis_screen.dart';
import '../../features/ytd_comparative/screens/ytd_comparative_screen.dart';
import '../../features/dimension_templates/screens/budgets_screen.dart';
import '../../features/dimension_templates/screens/performance_screen.dart';
import '../../features/dimension_templates/screens/sales_by_screen.dart';
import '../../features/admin/screens/platform_admin_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../supabase/supabase_config.dart';

/// Same auth-redirect pattern as SeaWyze's router: a ChangeNotifier wrapping
/// Supabase's auth stream so go_router re-evaluates `redirect` whenever the
/// session changes, plus a route-level guard.
class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

/// Route paths for the dimension-parameterized templates take the dimension
/// as a path segment (e.g. /sales-by/category) rather than five separate
/// routes each — matches the "3 templates x 5 dimensions" collapse in
/// Wyzesales_Screens_and_Recommendations.md Section 3.
final GoRouter appRouter = GoRouter(
  initialLocation: '/login',
  refreshListenable: GoRouterRefreshStream(supabase.auth.onAuthStateChange),
  redirect: (context, state) {
    final isLoggedIn = supabase.auth.currentSession != null;
    final isOnLogin = state.matchedLocation == '/login';
    // /reset-password is reachable regardless of session state (2026-08-31,
    // the password-reset landing page — see ResetPasswordScreen's own doc
    // comment). It can't be gated the same way `/login` is: a Supabase
    // recovery link lands here as the very first navigation, and whether
    // `currentSession` is already populated at that instant depends on
    // exactly how far `Supabase.initialize()`'s own URL-token exchange has
    // gotten — timing this codebase has no way to verify from this sandbox
    // (see data_export_buttons.dart's own several rounds of real-toolchain
    // surprises). Treating `/reset-password` as always-public sidesteps that
    // race entirely, rather than betting the user doesn't get bounced to
    // `/login` before their recovery session has had a chance to resolve.
    final isOnResetPassword = state.matchedLocation == '/reset-password';
    if (!isLoggedIn && !isOnLogin && !isOnResetPassword) return '/login';
    if (isLoggedIn && isOnLogin) return '/';
    return null;
  },
  routes: [
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(path: '/reset-password', builder: (context, state) => const ResetPasswordScreen()),
    GoRoute(path: '/', builder: (context, state) => const DashboardScreen()),
    // Document results from the top-bar search / GlobalFilterBar's "Add
    // filter" no longer pass a `?document=` query param — 2026-08-27, Craig:
    // "We need to add Document to the Filters dropdown." Document is now a
    // first-class field on GlobalFilters (global_filters.dart), so simply
    // navigating here is enough; DocumentAnalysisView reads the filter
    // itself, same as every other screen reads its own global filters.
    GoRoute(path: '/sales-analysis', builder: (context, state) => const SalesAnalysisScreen()),
    GoRoute(path: '/ytd-comparative', builder: (context, state) => const YtdComparativeScreen()),
    // Quote Analysis and Sales Order Analysis (routes '/quote-analysis',
    // '/sales-order-analysis') were removed 2026-09-02 — task #93. Not
    // renamed/redirected: WCSA's daily-use IQRetail application has only
    // ever pulled quotes/sales orders from company code 002, which never
    // actually holds any (they live in the per-branch CPT/DBN/JHB
    // databases instead, never wired into any extract) — meaning these
    // screens showed close to nothing in practice, and Craig's own
    // experience is that a lot of companies' real quoting happens outside
    // any system (Excel/Word) regardless, so there's no confidence a fixed
    // extraction would even be reliable. See
    // Wyzesales_Rebuild_Decisions.md Section 55 for the full reasoning and
    // what replaced this (R Gap / % Coverage Needed on Performance
    // Analysis, built on actual-sales-vs-target data instead).
    GoRoute(
      path: '/sales-by/:dimension',
      // ?highlight=<entity code> — set by the Dashboard's pie-chart
      // drill-down and the top-bar search (2026-08-26): pins that entity's
      // row to the top of the table instead of hard-filtering everything
      // else out, so the rest of the dimension stays visible for context.
      // ?rank=/&period=/&measure= — only set by the pie-chart drill-down
      // (2026-08-26): carries the Top 5/Bottom 5/Diminishing 5/Growth 5
      // mode, MTD/YTD, and R Value/Gross Profit through so the table opens
      // sorted to match what was actually clicked, instead of always
      // defaulting to "current FY, highest first."
      builder: (context, state) => SalesByScreen(
        dimension: _dimensionFromPath(state.pathParameters['dimension']),
        highlightCode: state.uri.queryParameters['highlight'],
        initialRank: state.uri.queryParameters['rank'],
        initialPeriod: state.uri.queryParameters['period'],
        initialMeasure: state.uri.queryParameters['measure'],
      ),
    ),
    GoRoute(
      path: '/budgets/:dimension',
      builder: (context, state) => BudgetsScreen(dimension: _dimensionFromPath(state.pathParameters['dimension'])),
    ),
    GoRoute(
      path: '/performance/:dimension',
      builder: (context, state) => PerformanceScreen(dimension: _dimensionFromPath(state.pathParameters['dimension'])),
    ),
    // Multi-tenancy — schema/008_wyzesales_multitenancy.sql. '/settings' is
    // gated per-client (canManageUsers — Company/Users/License tabs);
    // '/admin' is the cross-tenant screen gated by is_platform_admin
    // (Clients/Licenses/Pricing). Both screens do their own access check and
    // render an "access denied" body rather than redirecting, same pattern
    // BudgetsScreen already established — see those screens' own comments.
    GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
    GoRoute(path: '/admin', builder: (context, state) => const PlatformAdminScreen()),
  ],
);

/// 2026-09-06 (Step 4): returns the raw dimension_key straight off the URL
/// path segment now, rather than parsing it into the fixed `SalesDimension`
/// enum (which had no way to represent a brand-new client's own dim_1..
/// dim_12 dimension — a route like /sales-by/dim_7 used to silently fall
/// back to Sales Person). SalesByScreen/BudgetsScreen/PerformanceScreen
/// resolve the actual display label/config themselves, against whichever
/// dimensions THIS client has (clientDimensionsProvider), once they're
/// mounted — see those screens' own doc comments. 'sales_person' is kept as
/// the fallback for a missing/empty path segment only (should never actually
/// happen — every route below requires this segment) — the same default
/// this used to fall back to.
String _dimensionFromPath(String? value) => (value == null || value.isEmpty) ? 'sales_person' : value;
