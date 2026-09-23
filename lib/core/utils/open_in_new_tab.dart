import 'dart:html' as html;

/// Opens [path] in a new browser tab.
///
/// Plain `dart:html`, not a `url_launcher` package — same reasoning as
/// `image_picker_web.dart` alongside this file: WyzeSales is a Netlify
/// web-only deploy with no other platform to also support, so there's no
/// reason to pull in a plugin (with its own version to track and its own
/// web implementation to trust sight-unseen) just to do what the browser's
/// own `window.open` already does directly.
///
/// [path] should start with `/` (e.g. `/legal/privacy-policy.pdf`) so it
/// always resolves from the site root, regardless of which route the app
/// is currently on — this app uses path-based routing (see main.dart's
/// `usePathUrlStrategy()`), so a path without a leading `/` would resolve
/// relative to the CURRENT route instead (e.g. `/reset-password/legal/...`),
/// which is never what a caller here wants.
///
/// `noopener` is passed as a window feature — the standard security
/// precaution for any link that opens in a new tab, stopping that new tab
/// from getting a JavaScript handle back to this one.
void openInNewTab(String path) {
  html.window.open(path, '_blank', 'noopener');
}
