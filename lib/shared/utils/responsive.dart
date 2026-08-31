import 'package:flutter/material.dart';

/// Returns a safe maximum height for a dialog's ConstrainedBox, given the
/// dialog's preferred (desktop-sized) height.
///
/// Several of this app's dialogs (Add client, Edit license, Edit plan, etc.
/// — see platform_admin_screen.dart) hardcode a maxHeight tuned for desktop
/// screens. On a shorter phone viewport that fixed height can exceed what's
/// actually visible — the on-screen keyboard (viewInsets.bottom) and system
/// status/nav bars (viewPadding) both eat into the real available space —
/// so content anchored to the bottom of the dialog (typically the Save
/// button) gets clipped rather than shown or scrolled to.
///
/// Pair this with `insetPadding: dialogInsetPadding` on the same Dialog so
/// the margin this function reserves actually matches what's applied —
/// otherwise Dialog's own default insetPadding (24 top + 24 bottom) eats
/// into the same space a second time. The extra 24px beyond that covers
/// mobile-browser viewport-reporting slop (e.g. address bar show/hide),
/// which otherwise leaves a razor-thin, easy-to-clip margin.
///
/// Ported from SeaWyze's identical helper (Craig's parity request,
/// 2026-08-25 — see Wyzesales_Rebuild_Decisions.md) so the Platform Admin
/// dialogs built on the same `_dialogHeader`/`_tf`/`_dialogFooter` pattern
/// behave the same way on mobile as they do on SeaWyze.
///
/// Use as: `maxHeight: dialogMaxHeight(context, 700)`.
double dialogMaxHeight(BuildContext context, double preferred) {
  final media = MediaQuery.of(context);
  final available = media.size.height -
      media.viewInsets.bottom -
      media.viewPadding.vertical -
      dialogInsetPadding.vertical -
      24;
  return available.clamp(300, preferred);
}

/// Reduced Dialog insetPadding for mobile — pair with [dialogMaxHeight].
const dialogInsetPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 16);
