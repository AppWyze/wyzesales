import 'package:flutter/material.dart';
import 'app_logo.dart';

/// Renders a client's uploaded logo the same way everywhere it appears — the
/// sidebar's top brand slot (`_BrandMark`, app_shell.dart) and Settings >
/// Company > Branding's own live preview (settings_screen.dart) — so what an
/// admin sees while configuring it is exactly what their users see.
///
/// 2026-09-04 follow-up to Section 83 (schema/037): Craig, right after
/// seeing the feature live, caught the gap a single always-transparent
/// rendering has — "what if the colour of their logo is dark? Cannot be
/// seen" against the sidebar's fixed navy. `onDarkBackground` (from
/// `clients.logo_background`) answers that:
///   false ('light', the default) — wrap the logo in a small white backing
///     chip, so a dark or richly-coloured logo (the common case for a logo
///     exported assuming a plain white background) stays visible against
///     the navy.
///   true ('dark') — no chip, render directly on the navy — for a client
///     whose logo is itself light/white and was designed to sit on a dark
///     ground; adding a white chip in that case would just recreate the
///     same invisibility problem in the other direction.
/// Settings > Company's Branding card lets an admin pick whichever matches
/// their own logo.
class ClientLogoMark extends StatelessWidget {
  const ClientLogoMark({
    super.key,
    required this.logoUrl,
    required this.onDarkBackground,
    this.height = 32,
    this.maxWidth = 160,
  });

  final String logoUrl;
  final bool onDarkBackground;
  final double height;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final image = Image.network(
      logoUrl,
      fit: BoxFit.contain,
      alignment: Alignment.centerLeft,
      // Same "never show a broken image, fall back to the stock mark"
      // reasoning as `_BrandMark` always used — a stale cached object, or a
      // transient network blip loading it, shouldn't leave a broken-image
      // icon sitting in the sidebar.
      errorBuilder: (_, __, ___) => AppLogo(iconSize: height, fontSize: height * 0.6, onDark: true),
    );
    if (onDarkBackground) {
      return ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: height), child: image);
    }
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth + 20, maxHeight: height + 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
      child: image,
    );
  }
}
