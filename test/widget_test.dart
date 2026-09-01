// 2026-09-01, Craig: `flutter analyze` flagged
// `test/widget_test.dart:16:35 • creation_with_non_type — The name 'MyApp'
// isn't a class`. This file was the untouched default `flutter create`
// counter-app scaffold test (unchanged since the very first commit,
// 21c7027) — it was never adapted when the app's real root widget was
// named `WyzeSalesApp`, and it pumps/taps a counter UI ('0', '1', a '+'
// icon) that has never existed in this app. It was not testing WyzeSales
// at all; it was dead boilerplate that only started erroring once
// `MyApp` no longer existed anywhere for `flutter analyze` to resolve.
//
// Replaced with a real, minimal smoke test: constructing `WyzeSalesApp`
// and confirming it's a valid `Widget`. Deliberately NOT pumping it
// through `WidgetTester` — `WyzeSalesApp` renders `appRouter`
// (app_router.dart), whose redirect logic reads the current Supabase
// auth session, which throws if `Supabase.initialize()` hasn't run
// first (it normally runs in `main()`, which a widget test never calls).
// A real render/navigation smoke test would need a Supabase test double
// or a fake auth session set up first — worth doing as follow-up work,
// but out of scope for just clearing this stale analyze error.
import 'package:flutter_test/flutter_test.dart';

import 'package:wyzesales/main.dart';

void main() {
  test('WyzeSalesApp can be constructed', () {
    const app = WyzeSalesApp();
    expect(app, isA<WyzeSalesApp>());
  });
}
