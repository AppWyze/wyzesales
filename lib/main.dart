import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'core/router/app_router.dart';
import 'core/supabase/supabase_config.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Real path-based URLs (/reset-password), not Flutter web's default
  // /#/reset-password — 2026-08-31, fixing the password-reset link, which
  // was crashing go_router outright ("Assertion failed ... uri.path.
  // startsWith(newMatchedLocation) is not true"). Root cause: under the
  // default hash strategy, go_router reads its own route location from the
  // URL's #fragment — but that's exactly where Supabase's recovery link
  // puts its token (#access_token=...&type=recovery). The router was trying
  // to parse that token string itself as a route path and choking on it.
  // Path-based URLs read the route from the URL's actual path instead,
  // leaving the #fragment free for Supabase's own use — see app_router.dart
  // and the auth screens' own notes for the rest of this fix. A harmless,
  // arguably nicer side effect for every other screen too: clean URLs like
  // /sales-analysis instead of /#/sales-analysis.
  usePathUrlStrategy();
  await SupabaseConfig.initialize();
  runApp(const ProviderScope(child: WyzeSalesApp()));
}

class WyzeSalesApp extends ConsumerWidget {
  const WyzeSalesApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'WyzeSales',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: appRouter,
    );
  }
}
